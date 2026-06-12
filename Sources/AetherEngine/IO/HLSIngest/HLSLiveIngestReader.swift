import Foundation

/// Live HLS ingest as a public `IOReader`: resolves the upstream playlist
/// (master -> highest-BANDWIDTH variant), polls the media playlist, fetches
/// the MPEG-TS segments sequentially, and exposes the result as a single
/// forward-only TS byte stream the engine demuxes through
/// `AetherEngine.load(source: .custom(reader, formatHint: "mpegts"),
/// options: <isLive>)`.
///
/// Phase-1 contract (see the 2026-06-11 design spec): unencrypted TS
/// segments only. Encrypted playlists (EXT-X-KEY), fMP4 playlists
/// (EXT-X-MAP), non-TS first segments, unreachable/invalid playlists, and
/// stalled providers all terminate the stream with a logged
/// `HLSIngestError`; the read side then errors and the host falls back.
///
/// Demuxed-audio masters (video-only variants plus a separate
/// #EXT-X-MEDIA:TYPE=AUDIO,URI=... rendition playlist, ARD-style) are
/// supported since the companion-reader commit: the resolver picks the
/// variant's audio rendition (DEFAULT=YES preferred), spins up a SECOND
/// `HLSLiveIngestReader` on its playlist, and exposes it as
/// `companionAudioReader` for the engine's side demuxer. Only an
/// unresolvable rendition URI still fails with
/// `HLSIngestError.demuxedAudioNotSupported` (host falls back to the
/// server-muxed route).
///
/// Forward-only: `seek` always returns -1 (including AVSEEK_SIZE; length is
/// unknown). Requires the engine's live custom-source gates (same commit
/// series) so it still dispatches to the native loopback path.
///
/// Memory: the FIFO caps at 16 MB plus at most one segment of overshoot;
/// extreme-bitrate sources transiently hold one fetched segment on top.
/// Switching to streamed segment reads is a P2 option if that ever bites.
public final class HLSLiveIngestReader: IOReader, LiveIngestSourceInfo, @unchecked Sendable {
    private let playlistURL: URL
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

    public init(playlistURL: URL) {
        self.playlistURL = playlistURL
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
        defer { session.invalidateAndCancel() }
        do {
            let (mediaURL, seedPlaylist) = try await resolveMediaPlaylistURL()
            var tracker = HLSPlaylistTracker()
            var sniffedFirstSegment = false
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
                if media.isEncrypted { throw HLSIngestError.encryptedNotSupported }
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
                    let bytes = try await fetchSegment(segmentURL)
                    if bytes.isEmpty { continue } // 404: slid out of the window
                    if !sniffedFirstSegment {
                        sniffedFirstSegment = true
                        guard bytes.first == 0x47 else {
                            throw HLSIngestError.unsupportedSegmentFormat
                        }
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
                // case. Lazy: ingest starts on the companion's first read().
                installCompanion(HLSLiveIngestReader(playlistURL: audioURL))
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
}
