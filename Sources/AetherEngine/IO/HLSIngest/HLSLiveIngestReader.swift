import Foundation
import CommonCrypto

/// Live HLS ingest as a public `IOReader`: resolves the upstream playlist
/// (master -> highest-BANDWIDTH variant), polls the media playlist, fetches
/// the MPEG-TS segments sequentially, and exposes the result as a single
/// forward-only TS byte stream the engine demuxes through
/// `AetherEngine.load(source: .custom(reader, formatHint: "mpegts"),
/// options: <isLive>)`.
///
/// Phase-1 contract (see the 2026-06-11 design spec): unencrypted TS
/// segments only on the MAIN variant. Encrypted playlists (EXT-X-KEY),
/// fMP4 playlists (EXT-X-MAP), unaccepted first-segment formats (see
/// `Role` / `LiveSegmentFormat`), unreachable/invalid playlists, and
/// stalled providers all terminate the stream with a logged
/// `HLSIngestError`; the read side then errors and the host falls back.
///
/// Demuxed-audio masters (video-only variants plus a separate
/// #EXT-X-MEDIA:TYPE=AUDIO,URI=... rendition playlist, ARD-style) are
/// supported since the companion-reader commit: the resolver picks the
/// variant's audio rendition (DEFAULT=YES preferred), spins up a SECOND
/// `HLSLiveIngestReader` on its playlist, and exposes it as
/// `companionAudioReader` for the engine's side demuxer. The companion
/// accepts both MPEG-TS audio renditions and Apple PACKED AUDIO (raw
/// ADTS AAC segments, each prefixed with an ID3v2 tag whose PRIV frame
/// carries the 90 kHz program-clock timestamp; ARD's masteraudio1
/// rendition is this shape). The companion classifies its first
/// segment (`resolveSegmentFormatHint`) so the engine opens the side
/// demuxer with the matching FFmpeg demuxer, and surfaces the PRIV
/// timestamp (`packedAudioTimestampOffset90k`) so the producer can
/// synthesize program-clock side-audio timestamps. Residual failures
/// keep `HLSIngestError.demuxedAudioNotSupported` (unresolvable
/// rendition URI, packed audio without a parsable PRIV timestamp) so
/// the host falls back to the server-muxed route.
///
/// Forward-only: `seek` always returns -1 (including AVSEEK_SIZE; length is
/// unknown). Requires the engine's live custom-source gates (same commit
/// series) so it still dispatches to the native loopback path.
///
/// Memory: the FIFO caps at 16 MB plus at most one segment of overshoot;
/// extreme-bitrate sources transiently hold one fetched segment on top.
/// Switching to streamed segment reads is a P2 option if that ever bites.
public final class HLSLiveIngestReader: IOReader, LiveIngestSourceInfo, @unchecked Sendable {

    /// What this reader ingests; decides which first-segment formats
    /// are acceptable. The MAIN variant keeps the strict TS contract
    /// (engine video pipeline + side-machinery all assume TS); a
    /// companion AUDIO rendition additionally accepts Apple packed
    /// audio (see `LiveSegmentFormat`).
    enum Role {
        case mainVideo
        case companionAudio
    }

    private let playlistURL: URL
    private let role: Role
    private let fifo = ByteFIFO(capacity: 16 * 1024 * 1024)
    private let session: URLSession
    private var ingestTask: Task<Void, Never>?
    private let startLock = NSLock()
    private var started = false
    private var closed = false
    /// Terminal ingest error, readable by the host for fallback logging.
    /// Protected by startLock: written from the detached ingest task under
    /// startLock, read by the host after the FIFO signals failure.
    private var _terminalError: HLSIngestError?

    /// Upstream media playlist's EXT-X-TARGETDURATION (seconds), set by
    /// the ingest loop the moment the first media playlist is parsed.
    /// Protected by startLock; first write wins (the upstream cadence is
    /// effectively constant for a session).
    private var _upstreamTargetDuration: Double?

    /// Companion reader for a demuxed audio rendition (see
    /// `LiveIngestSourceInfo.companionAudioReader`). Protected by
    /// startLock; installed by the resolver BEFORE any segment byte can
    /// reach the FIFO so the consumer-side ordering guarantee holds.
    private var _companionAudioReader: HLSLiveIngestReader?

    /// FFmpeg demuxer name for this reader's stream ("mpegts" / "aac"),
    /// classified from the FIRST segment's leading bytes. Protected by
    /// startLock; written before that segment's first byte is published
    /// to the FIFO (same ordering contract as `upstreamTargetDuration`).
    private var _segmentFormatHint: String?

    /// Apple packed-audio program-clock anchor (see
    /// `LiveIngestSourceInfo.packedAudioTimestampOffset90k`). Protected
    /// by startLock; same publish-before-first-byte ordering as the
    /// format hint, parsed from the same first segment.
    private var _packedAudioTimestampOffset90k: Int64?

    /// Wakes `resolveSegmentFormatHint` waiters. `formatResolved` flips
    /// once the classification is published OR the ingest exits without
    /// one (terminal error, cancellation, close-before-start), so the
    /// resolve can never outwait a dead ingest.
    private let formatCondition = NSCondition()
    private var formatResolved = false

    /// AES-128 clear-key cache, keyed by the EXT-X-KEY URI string. FAST
    /// providers reuse one key across a whole clip (dozens of segments),
    /// so this turns one key fetch per clip instead of one per segment.
    /// Guarded by `keyCacheLock`; the lock is never held across the
    /// network fetch (a duplicate concurrent miss just refetches the same
    /// 16 bytes, harmless).
    private let keyCacheLock = NSLock()
    private var keyCache: [String: Data] = [:]

    /// Terminal ingest error, readable by the host for fallback logging.
    public var terminalError: HLSIngestError? {
        startLock.withLock { _terminalError }
    }

    /// `LiveIngestSourceInfo`: the upstream playlist's EXT-X-TARGETDURATION
    /// in seconds, nil until the ingest loop has parsed a media playlist.
    /// Ordering guarantee for consumers: the ingest loop writes this BEFORE
    /// it fetches (let alone FIFO-publishes) any segment bytes, and the
    /// loop only starts via `startIfNeeded()` on the first `read()`. So any
    /// consumer that has already received stream bytes (e.g. the engine
    /// after its blocking load probe) is guaranteed to observe a non-nil
    /// value here.
    public var upstreamTargetDuration: Double? {
        startLock.withLock { _upstreamTargetDuration }
    }

    /// `LiveIngestSourceInfo`: the companion reader carrying a demuxed
    /// audio rendition, nil for muxed-audio sources. Same ordering
    /// guarantee as `upstreamTargetDuration`: installed by the resolver
    /// before any main-stream segment byte is published, so any
    /// consumer that has received main bytes observes the final value.
    public var companionAudioReader: IOReader? {
        startLock.withLock { _companionAudioReader }
    }

    /// `LiveIngestSourceInfo`: Apple packed-audio program-clock anchor
    /// of THIS reader's stream, nil for TS streams (and packed streams
    /// whose first segment hasn't been classified yet; consumers that
    /// resolved the format hint as "aac" are guaranteed non-nil, see
    /// `resolveSegmentFormatHint`).
    public var packedAudioTimestampOffset90k: Int64? {
        startLock.withLock { _packedAudioTimestampOffset90k }
    }

    /// `LiveIngestSourceInfo`: blocking format resolve for the side
    /// demuxer. Starts the ingest (idempotent) and waits, bounded, for
    /// the first segment's classification. Classification happens
    /// BEFORE any byte is published to the FIFO, so resolving here
    /// consumes no stream data; the demuxer that opens right after
    /// reads the stream from its first byte. Returns nil when the
    /// ingest went terminal first (or never produced a first segment
    /// inside the bound), which callers treat as a failed bring-up.
    public func resolveSegmentFormatHint() -> String? {
        startIfNeeded()
        let deadline = Date().addingTimeInterval(Self.formatResolveTimeout)
        formatCondition.lock()
        while !formatResolved, Date() < deadline {
            if !formatCondition.wait(until: deadline) { break }
        }
        formatCondition.unlock()
        return startLock.withLock { _segmentFormatHint }
    }

    /// Wall-clock bound for `resolveSegmentFormatHint`. The ingest's
    /// own fetch timeouts (10 s request / 30 s resource, 3 segment
    /// attempts) keep a healthy-but-slow join inside this; a join that
    /// can't deliver one audio segment in 30 s is dead and the load
    /// should fail over to the server-muxed route instead of hanging.
    private static let formatResolveTimeout: TimeInterval = 30

    /// Install the companion under startLock. A close() that raced the
    /// resolver wins: the freshly built companion is closed instead of
    /// stored, so no ingest loop or URLSession can outlive the parent.
    private func installCompanion(_ companion: HLSLiveIngestReader) {
        startLock.lock()
        let raceClosed = closed
        if !raceClosed { _companionAudioReader = companion }
        startLock.unlock()
        if raceClosed { companion.close() }
    }

    public convenience init(playlistURL: URL) {
        self.init(playlistURL: playlistURL, role: .mainVideo)
    }

    init(playlistURL: URL, role: Role) {
        self.playlistURL = playlistURL
        self.role = role
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        // 30s resource ceiling per one-shot fetch: a trickling CDN must fail
        // the segment (and ultimately the ingest) instead of stalling
        // playback forever with no host fallback. The c7592ed no-ceiling
        // lesson applies to LONG-LIVED stream connections, not to bounded
        // one-shot playlist/segment fetches.
        self.session = URLSession(configuration: config)
    }

    // MARK: - IOReader

    public func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return -1 }
        startIfNeeded()
        let n = fifo.read(into: buffer, maxLength: Int(size))
        return Int32(n)
    }

    public func seek(offset: Int64, whence: Int32) -> Int64 {
        // Forward-only live stream of unknown length: reject everything,
        // including AVSEEK_SIZE (65536).
        -1
    }

    public func close() {
        startLock.lock()
        closed = true
        let wasStarted = started
        let task = ingestTask
        ingestTask = nil
        task?.cancel()
        let companion = _companionAudioReader
        _companionAudioReader = nil
        startLock.unlock()

        // The companion's lifetime is bound to the main reader's: the
        // engine only ever closes the reader it was handed, so a
        // dangling companion would keep its ingest loop + URLSession
        // alive past teardown. close() is idempotent on the companion.
        companion?.close()
        fifo.cancel()
        // A resolveSegmentFormatHint() racing this close must not sleep
        // out its full bound: if the ingest never started it would
        // otherwise have no waker (runIngest's defer covers the started
        // case). Idempotent.
        wakeFormatResolveWaiters()
        if !wasStarted {
            // Ingest never launched: we are the sole owner of the session.
            session.invalidateAndCancel()
        }
        // If wasStarted, the defer inside runIngest() owns session teardown.
    }

    public func cancel() {
        // Unblock a pending read. CAVEAT vs the IOReader contract
        // ("unblock, don't invalidate"): the FIFO's cancel latch is
        // permanent, so every subsequent read returns -1. Safe today
        // because forward-only sources can never re-enter a read after
        // cancel (the engine's reload paths no-op for them and
        // makeIndependentReader() returns nil); if forward-only readers
        // ever become reload-capable, this poisoning fires immediately.
        fifo.cancel()
    }

    // MARK: - Ingest loop

    private func startIfNeeded() {
        startLock.lock()
        defer { startLock.unlock() }
        guard !started, !closed else { return }
        started = true
        // Strong capture on purpose: the ingest loop must keep the reader
        // (and its FIFO) alive until close() cancels it; close() is
        // guaranteed by the IOReader contract.
        ingestTask = Task.detached(priority: .userInitiated) { [self] in
            await runIngest()
        }
    }

    private func runIngest() async {
        defer {
            session.invalidateAndCancel()
            // Whatever path the ingest exits on (clean EOF, terminal
            // error, cancellation), a pending format resolve must wake;
            // the hint is whatever was (or wasn't) published by then.
            wakeFormatResolveWaiters()
        }
        do {
            let (mediaURL, seedPlaylist) = try await resolveMediaPlaylistURL()
            var tracker = HLSPlaylistTracker()
            var sniffedFirstSegment = false
            var loggedEncryptedDirectPlay = false
            var refreshInterval: Double = 2
            var pendingPlaylist: HLSMediaPlaylist? = seedPlaylist

            while !Task.isCancelled {
                let media: HLSMediaPlaylist
                if let seeded = pendingPlaylist {
                    // First iteration: reuse the already-parsed media playlist
                    // from resolveMediaPlaylistURL so we don't refetch it.
                    media = seeded
                    pendingPlaylist = nil
                } else {
                    let (playlist, _) = try await fetchPlaylistWithRetry(mediaURL)
                    guard case .media(let fetched) = playlist else {
                        throw HLSIngestError.playlistInvalid(reason: "expected media playlist on refresh")
                    }
                    media = fetched
                }
                // Publish the upstream cadence before ANY segment byte can
                // reach the FIFO (see `upstreamTargetDuration` ordering
                // guarantee). Covers both the seed path (playlist parsed in
                // resolveMediaPlaylistURL) and every refresh; first write
                // wins.
                startLock.withLock {
                    if _upstreamTargetDuration == nil {
                        _upstreamTargetDuration = media.targetDuration
                    }
                }
                if media.hasUnsupportedEncryption { throw HLSIngestError.encryptedNotSupported }
                if media.isEncrypted, !loggedEncryptedDirectPlay {
                    loggedEncryptedDirectPlay = true
                    EngineLog.emit(
                        "[HLSIngest] AES-128 clear-key stream: decrypting segments inline (direct play)",
                        category: .engine
                    )
                }
                if media.hasMap { throw HLSIngestError.unsupportedSegmentFormat }
                refreshInterval = min(6, max(1, media.targetDuration / 2))

                let isJoin = !sniffedFirstSegment
                let fresh = tracker.newSegments(in: media)
                if tracker.stallCount > 6 { throw HLSIngestError.ingestStalled }
                if isJoin, !fresh.isEmpty {
                    let backlog = fresh.reduce(0.0) { $0 + $1.duration }
                    EngineLog.emit(
                        "[HLSIngest] joined \(fresh.count) segment(s), ~\(Int(backlog))s behind the live edge",
                        category: .engine
                    )
                }

                for segment in fresh {
                    guard !Task.isCancelled else { return }
                    if segment.discontinuityBefore {
                        // Phase 1 decision (design spec): the seam is logged, the actual
                        // timestamp handling rides on the producer's PTS-leap rebase
                        // heuristic downstream; a deterministic force-cut hint is a P2 item.
                        EngineLog.emit("[HLSIngest] discontinuity seam before segment \(segment.uri)", category: .engine)
                    }
                    guard let segmentURL = HLSPlaylistParser.resolve(uri: segment.uri, against: mediaURL) else {
                        throw HLSIngestError.playlistInvalid(reason: "unresolvable segment URI")
                    }
                    let fetched = try await fetchSegment(segmentURL)
                    if fetched.isEmpty { continue } // 404: slid out of the window
                    // Decrypt AES-128 clear-key segments inline before
                    // classification (the TS sync byte is only visible in
                    // the plaintext) and before the FIFO sees them.
                    let bytes: Data
                    if let crypt = segment.crypt {
                        bytes = try await decryptSegment(fetched, crypt: crypt, against: mediaURL)
                    } else {
                        bytes = fetched
                    }
                    if !sniffedFirstSegment {
                        sniffedFirstSegment = true
                        try classifyFirstSegment(bytes)
                    }
                    guard fifo.write(bytes) else { return } // closed underneath us
                }

                if media.hasEndList {
                    fifo.finish() // a "live" playlist that ended: clean EOF
                    return
                }
                if fresh.isEmpty {
                    try await Task.sleep(nanoseconds: UInt64(refreshInterval * 1_000_000_000))
                }
            }
        } catch is CancellationError {
            // teardown
        } catch let error as HLSIngestError {
            startLock.withLock { _terminalError = error }
            EngineLog.emit("[HLSIngest] terminal: \(error)", category: .engine)
            fifo.cancel()
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                return // teardown rides through as cancellation, not a terminal error
            }
            startLock.withLock { _terminalError = .playlistUnreachable(status: -1) }
            EngineLog.emit("[HLSIngest] terminal (transport): \(error.localizedDescription)", category: .engine)
            fifo.cancel()
        }
    }

    /// First-segment format gate, role-aware. Runs BEFORE the segment's
    /// first byte is written to the FIFO, which is what gives the
    /// format hint and the PRIV timestamp their publish-before-data
    /// ordering contract.
    ///
    /// Main variant: strict MPEG-TS, exactly the previous behaviour.
    ///
    /// Companion audio rendition: TS passes through unchanged ("mpegts"
    /// hint, no offset, timestamps already on the program clock). Apple
    /// packed audio (ID3v2-prefixed raw ADTS AAC) resolves to FFmpeg's
    /// "aac" demuxer and MUST carry the Apple PRIV program-clock
    /// timestamp; without it the side audio cannot be aligned to the
    /// video and guessing risks silent A/V desync, so the ingest goes
    /// terminal with `demuxedAudioNotSupported` (host falls back to the
    /// server-muxed route). A bare-ADTS first segment (no ID3 tag) is
    /// the same situation: the spec requires the tag on every segment,
    /// and without it there is no timestamp to anchor on.
    private func classifyFirstSegment(_ bytes: Data) throws {
        let format = LiveSegmentFormat.classify(bytes)
        switch role {
        case .mainVideo:
            guard format == .mpegts else {
                throw HLSIngestError.unsupportedSegmentFormat
            }
            publishSegmentFormat(hint: "mpegts", packedOffset90k: nil)
        case .companionAudio:
            switch format {
            case .mpegts:
                publishSegmentFormat(hint: "mpegts", packedOffset90k: nil)
            case .id3PackedAudio:
                guard let offset = PackedAudioID3.transportStreamTimestamp90k(in: bytes) else {
                    EngineLog.emit(
                        "[HLSIngest] packed-audio companion: first segment has no parsable "
                        + "\"\(PackedAudioID3.appleTimestampOwner)\" PRIV timestamp; cannot "
                        + "align to the program clock, failing fast for host fallback",
                        category: .engine
                    )
                    throw HLSIngestError.demuxedAudioNotSupported
                }
                EngineLog.emit(
                    "[HLSIngest] packed-audio companion: ADTS AAC with ID3 PRIV timestamp "
                    + "\(offset) (90 kHz, \(String(format: "%.3f", Double(offset) / 90000.0))s)",
                    category: .engine
                )
                publishSegmentFormat(hint: "aac", packedOffset90k: offset)
            case .adtsAAC:
                EngineLog.emit(
                    "[HLSIngest] packed-audio companion: raw ADTS first segment without the "
                    + "spec-required leading ID3 tag, no program-clock timestamp to align on; "
                    + "failing fast for host fallback",
                    category: .engine
                )
                throw HLSIngestError.demuxedAudioNotSupported
            case nil:
                throw HLSIngestError.unsupportedSegmentFormat
            }
        }
    }

    /// Publish the classification under startLock (ordering contract),
    /// then wake a pending `resolveSegmentFormatHint`.
    private func publishSegmentFormat(hint: String, packedOffset90k: Int64?) {
        startLock.withLock {
            _segmentFormatHint = hint
            _packedAudioTimestampOffset90k = packedOffset90k
        }
        wakeFormatResolveWaiters()
    }

    private func wakeFormatResolveWaiters() {
        formatCondition.lock()
        formatResolved = true
        formatCondition.broadcast()
        formatCondition.unlock()
    }

    /// Resolves the media playlist URL and returns the already-parsed
    /// `HLSMediaPlaylist` when the input URL is a direct media playlist
    /// (so the caller can reuse it without a second fetch). Returns `nil`
    /// for the seed in the master-playlist case.
    private func resolveMediaPlaylistURL() async throws -> (URL, HLSMediaPlaylist?) {
        let (playlist, finalURL) = try await fetchPlaylist(playlistURL)
        switch playlist {
        case .media(let media):
            // Direct media playlist: hand the parsed result back so the
            // ingest loop's first iteration does not refetch it.
            return (finalURL, media)
        case .master(let master):
            guard let best = master.variants.max(by: { $0.bandwidth < $1.bandwidth }),
                  let url = HLSPlaylistParser.resolve(uri: best.uri, against: finalURL) else {
                throw HLSIngestError.playlistInvalid(reason: "no usable variant")
            }
            // A variant whose audio lives in a separate rendition playlist
            // ingests as video-only TS. Bring up a companion reader on the
            // rendition's own playlist so the engine can demux it through a
            // side demuxer and merge the packets back in (demuxed-audio
            // direct play, ARD-style channels). Installed BEFORE this
            // function returns, i.e. before the ingest loop can publish any
            // segment byte: that is the `companionAudioReader` ordering
            // guarantee consumers rely on. Only an unresolvable rendition
            // URI still fails fast; the host then takes the
            // Jellyfin-mediated route, which muxes the audio back in.
            if let group = best.audioGroupID, master.demuxedAudioGroupIDs.contains(group) {
                let groupRenditions = master.audioRenditions.filter { $0.groupID == group }
                // DEFAULT=YES is the provider's pick; fall back to the
                // first listed rendition of the group (groups built from
                // URI-carrying entries are non-empty by construction).
                guard let rendition = groupRenditions.first(where: { $0.isDefault })
                        ?? groupRenditions.first,
                      let audioURL = HLSPlaylistParser.resolve(uri: rendition.uri, against: finalURL) else {
                    EngineLog.emit(
                        "[HLSIngest] variant audio is a separate rendition (group \"\(group)\") "
                        + "but its URI is unresolvable; failing fast for host fallback",
                        category: .engine
                    )
                    throw HLSIngestError.demuxedAudioNotSupported
                }
                EngineLog.emit(
                    "[HLSIngest] demuxed audio rendition (group \"\(group)\", default=\(rendition.isDefault)): "
                    + "starting companion reader on \(audioURL.lastPathComponent)",
                    category: .engine
                )
                // Audio rendition playlists are direct media playlists;
                // the companion's own resolveMediaPlaylistURL handles that
                // case. Lazy: ingest starts on the companion's first read()
                // (or on the engine's resolveSegmentFormatHint, whichever
                // comes first). The companion role relaxes the first-
                // segment sniff to also accept Apple packed audio.
                installCompanion(HLSLiveIngestReader(playlistURL: audioURL, role: .companionAudio))
            }
            EngineLog.emit("[HLSIngest] master playlist: picked variant bandwidth=\(best.bandwidth)", category: .engine)
            return (url, nil)
        }
    }

    /// Wall-clock budget for mid-session playlist-refresh retries. The
    /// FIFO plus the producer's already-cut segments give the player
    /// roughly 10-20 s of slack, so a refresh hiccup bridged inside this
    /// window stays invisible; past it, going terminal (and letting the
    /// host retune) beats stretching a stall the buffer can no longer
    /// hide.
    private static let refreshRetryBudget: TimeInterval = 12

    /// Mid-session playlist refresh with bounded retry + backoff.
    ///
    /// One transient failure on a chunks.m3u8 poll used to go terminal
    /// immediately and force a visible ~10 s host retune (device repro:
    /// a single -1001 timeout from the provider's CDN while segments
    /// were still buffered). Transport errors and retryable statuses
    /// (5xx / 429) now back off 1 s, 2 s, 4 s, ... inside
    /// `refreshRetryBudget`; parse failures and other 4xx are real
    /// verdicts and still throw straight through. The INITIAL join
    /// deliberately stays single-shot (`fetchPlaylist` in
    /// `resolveMediaPlaylistURL`): there the user is staring at a
    /// spinner and a fast host fallback beats a slow retry.
    private func fetchPlaylistWithRetry(_ url: URL) async throws -> (HLSPlaylist, URL) {
        let deadline = Date().addingTimeInterval(Self.refreshRetryBudget)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await fetchPlaylist(url)
            } catch let error as HLSIngestError {
                guard case .playlistUnreachable(let status) = error,
                      status >= 500 || status == 429 else {
                    throw error
                }
                try await backoffOrRethrow(error, attempt: &attempt, deadline: deadline)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if (error as? URLError)?.code == .cancelled { throw error }
                try await backoffOrRethrow(error, attempt: &attempt, deadline: deadline)
            }
        }
    }

    /// Sleep out the next backoff step, or rethrow `error` when the next
    /// attempt could not finish inside the deadline anyway.
    private func backoffOrRethrow(_ error: Error, attempt: inout Int, deadline: Date) async throws {
        attempt += 1
        let delay = min(4.0, pow(2.0, Double(attempt - 1)))
        guard Date().addingTimeInterval(delay) < deadline else { throw error }
        EngineLog.emit(
            "[HLSIngest] playlist refresh failed (attempt \(attempt): \(error.localizedDescription)); retrying in \(Int(delay))s",
            category: .engine
        )
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    /// Fetch + parse a playlist. Returns the parsed playlist and the FINAL
    /// URL after redirects, which relative segment URIs resolve against.
    private func fetchPlaylist(_ url: URL) async throws -> (HLSPlaylist, URL) {
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw HLSIngestError.playlistUnreachable(status: status)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw HLSIngestError.playlistInvalid(reason: "non-UTF8 playlist")
        }
        return (try HLSPlaylistParser.parse(text), response.url ?? url)
    }

    private func fetchSegment(_ url: URL) async throws -> Data {
        // Bounded retry per segment; a 404 means the segment slid out of
        // the provider window, skip it (the tracker advances regardless).
        var lastStatus = -1
        for attempt in 0..<3 {
            if Task.isCancelled { throw CancellationError() }
            do {
                let (data, response) = try await session.data(from: url)
                lastStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
                if (200..<300).contains(lastStatus) { return data }
                if lastStatus == 404 { return Data() } // slid out of window
                if (400..<500).contains(lastStatus) && lastStatus != 429 {
                    throw HLSIngestError.playlistUnreachable(status: lastStatus)
                }
            } catch let error as HLSIngestError { throw error }
            catch { /* transport blip: retry */ }
            if attempt < 2 {
                try await Task.sleep(nanoseconds: UInt64(0.5 * Double(attempt + 1) * 1_000_000_000))
            }
        }
        throw HLSIngestError.playlistUnreachable(status: lastStatus)
    }

    /// Decrypt one AES-128 clear-key segment: resolve + fetch (cached)
    /// the 16-byte key, then AES-CBC/PKCS7 the ciphertext. Any failure is
    /// terminal (`segmentDecryptFailed`) so the host falls back rather
    /// than feeding the demuxer ciphertext.
    private func decryptSegment(_ ciphertext: Data, crypt: HLSSegmentCrypt, against base: URL) async throws -> Data {
        guard let keyURL = HLSPlaylistParser.resolve(uri: crypt.keyURI, against: base) else {
            throw HLSIngestError.segmentDecryptFailed(reason: "unresolvable key URI")
        }
        let key = try await fetchKey(keyURL)
        guard let plaintext = HLSSegmentDecryptor.decryptAES128CBC(ciphertext, key: key, iv: crypt.iv) else {
            throw HLSIngestError.segmentDecryptFailed(
                reason: "AES-128-CBC failed (key=\(key.count)B iv=\(crypt.iv.count)B ct=\(ciphertext.count)B)"
            )
        }
        return plaintext
    }

    /// Fetch a 16-byte AES-128 key, memoised by URI. The lock is dropped
    /// across the network call; a racing miss just refetches the same key.
    private func fetchKey(_ url: URL) async throws -> Data {
        let cacheKey = url.absoluteString
        if let cached = keyCacheLock.withLock({ keyCache[cacheKey] }) { return cached }

        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw HLSIngestError.segmentDecryptFailed(reason: "key fetch HTTP \(status)")
        }
        guard data.count == kCCKeySizeAES128 else {
            throw HLSIngestError.segmentDecryptFailed(reason: "key length \(data.count) != 16")
        }
        keyCacheLock.withLock { keyCache[cacheKey] = data }
        return data
    }
}
