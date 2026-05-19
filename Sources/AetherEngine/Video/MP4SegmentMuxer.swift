import Darwin
import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Per-segment fragmented MP4 muxer. Replaces the long-lived libavformat
/// `hls` muxer that accumulated state across the full session and
/// caused the long-form 4K HDR HEVC memory leak (libavformat hlsenc +
/// mp4 sub-muxer holding ~6 MB/sec of internal sample-table + sidx +
/// delay_moov state per the producer-restart diagnostic that freed
/// 840 MB in one teardown).
///
/// Architecture: one `AVFormatContext` per segment, configured as a
/// plain `mp4` muxer (not `hls` wrapper) with movflags that match
/// Apple's HLS-fMP4 spec but DON'T accumulate state across fragments:
///
///   +empty_moov         — moov written eagerly at write_header, no
///                          samples carried in moov, all sample data
///                          lives in per-fragment moofs
///   +default_base_moof  — relative offsets in tfhd (cleaner fmp4)
///   +frag_keyframe      — auto-cut fragment at every keyframe; our
///                          segments are keyframe-aligned by design
///                          so each muxer produces exactly one moof+mdat
///   (omitted: +delay_moov, +dash, +frag_custom — these were the
///   leak source)
///
/// Output flow per segment:
///
///   1. allocate fresh AVFormatContext (mp4 muxer)
///   2. add video stream (codecpar copied from source, codec_tag set)
///   3. optionally add audio stream
///   4. avformat_write_header → emits ftyp + moov via io trampoline
///   5. caller pumps packets via writePacket()
///   6. av_write_trailer → flushes final moof + mdat, may emit mfra
///   7. avformat_free_context → ALL internal state released
///
/// The `FragmentSplitter` parses the io output stream and routes the
/// ftyp + moov portion to the init-handler callback (consumer dedupes
/// against the pre-built init.mp4) and the moof + mdat portion straight
/// to a POSIX-staging file. `mfra` and any trailing boxes are discarded.
///
/// AVPlayer compatibility: per the Apple HLS Authoring Spec, fMP4
/// segments need `moof + mdat` with `tfdt` carrying decode time, and
/// movie-fragment-relative addressing. No `styp` / `sidx` required.
/// Tested as-emitted by the mp4 muxer with these flags against
/// AVPlayer on tvOS 26.
final class MP4SegmentMuxer {

    // MARK: - Types

    struct VideoConfig {
        let codecpar: UnsafePointer<AVCodecParameters>
        let timeBase: AVRational
        /// Optional fourcc to set on the output stream's codec_tag.
        /// Used to force `hvc1` on HEVC (default is `hev1` which
        /// AVPlayer doesn't accept).
        let codecTagOverride: String?
    }

    struct AudioConfig {
        let codecpar: UnsafePointer<AVCodecParameters>
        let timeBase: AVRational
    }

    enum MuxerError: Error, CustomStringConvertible {
        case allocFailed(code: Int32)
        case streamCreationFailed
        case copyParametersFailed(code: Int32)
        case avioAllocFailed
        case writeHeaderFailed(code: Int32)
        case openStagingFileFailed(errno: Int32)

        var description: String {
            switch self {
            case .allocFailed(let c): return "MP4SegmentMuxer: avformat_alloc_output_context2 failed (\(c))"
            case .streamCreationFailed: return "MP4SegmentMuxer: avformat_new_stream failed"
            case .copyParametersFailed(let c): return "MP4SegmentMuxer: avcodec_parameters_copy failed (\(c))"
            case .avioAllocFailed: return "MP4SegmentMuxer: avio_alloc_context failed"
            case .writeHeaderFailed(let c): return "MP4SegmentMuxer: avformat_write_header failed (\(c))"
            case .openStagingFileFailed(let e): return "MP4SegmentMuxer: open() staging file failed errno=\(e)"
            }
        }
    }

    // MARK: - State

    /// Segment index this muxer is writing. Used in the staging
    /// filename and dispatched alongside the bytesWritten count when
    /// the segment finalizes so the caller's cache can adopt it under
    /// the right key.
    let segmentIndex: Int

    /// Disk path the FragmentSplitter writes fragment bytes into.
    /// Lives under the cache's session directory so the cache's
    /// final adopt is a same-volume rename (metadata-only, no copy).
    private let stagingPath: URL

    /// Open POSIX file descriptor for the staging file. Closed in
    /// finalize() before the cache adopts the file.
    private var fd: Int32 = -1

    /// AVFormatContext for the mp4 muxer. Always paired with a sink
    /// holding the avio buffer / FragmentSplitter via the format
    /// context's opaque + io_open trampolines.
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?

    /// Bytes appended to the staging file. Reported to the caller
    /// at finalize() time for cache accounting + memprobe stats.
    private(set) var bytesWritten: Int = 0

    /// Sticky once any write fails. finalize() discards the staging
    /// file if set, instead of adopting half-written content.
    private var writeFailed: Bool = false

    /// Latched once avformat_write_header succeeds and av_write_trailer
    /// becomes safe to call. Guards against double-trailer if the
    /// caller invokes finalize() after a header-write failure.
    private var headerWritten: Bool = false

    /// Muxer's chosen time_base for the video output stream, latched
    /// after avformat_write_header. The mp4 muxer rewrites the stream's
    /// time_base to its own auto-pick (usually 1/<sample rate>-ish or
    /// 1/12800 for video at common frame rates); subsequent
    /// av_packet_rescale_ts calls target this time_base.
    private(set) var muxerVideoTimeBase: AVRational = AVRational(num: 1, den: 1)
    private(set) var muxerAudioTimeBase: AVRational = AVRational(num: 1, den: 1)
    private let haveAudio: Bool

    /// Stream indices in the output (video always 0; audio 1 when present).
    let videoOutputStreamIndex: Int32 = 0
    let audioOutputStreamIndex: Int32 = 1

    /// The FragmentSplitter that parses the avio output stream and
    /// routes header vs fragment bytes. Owned strongly here so its
    /// closures stay alive for the muxer's lifetime; the C trampoline
    /// recovers it via the avio context's opaque pointer.
    private let splitter: FragmentSplitter

    // MARK: - Init

    /// Build a muxer for one segment. `onInitCaptured` fires when this
    /// muxer's ftyp + moov bytes are complete; the caller typically
    /// uses it to populate the session's init.mp4 on the first muxer
    /// and ignores the call (or verifies byte-stability) for subsequent
    /// muxers.
    ///
    /// Throws on any libavformat init failure or staging-file open
    /// failure. The instance is unusable after a throw; callers must
    /// not call writePacket / finalize on it.
    init(
        segmentIndex: Int,
        sessionDir: URL,
        video: VideoConfig,
        audio: AudioConfig?,
        targetSegmentDurationSeconds: Double,
        onInitCaptured: @escaping (Data) -> Void
    ) throws {
        self.segmentIndex = segmentIndex
        self.haveAudio = audio != nil

        // Staging file: same naming as the old SegmentSink path so
        // SegmentCache.adopt can rename it into place without changing
        // the cache API.
        self.stagingPath = sessionDir.appendingPathComponent(
            "staging-seg-\(segmentIndex)-\(UUID().uuidString.prefix(8)).tmp"
        )
        let cPath = stagingPath.withUnsafeFileSystemRepresentation { ptr -> [CChar] in
            guard let p = ptr else { return [] }
            var arr = [CChar]()
            var i = 0
            while p[i] != 0 { arr.append(p[i]); i += 1 }
            arr.append(0)
            return arr
        }
        guard !cPath.isEmpty else {
            throw MuxerError.openStagingFileFailed(errno: EINVAL)
        }
        let fd = cPath.withUnsafeBufferPointer { buf -> Int32 in
            // creat == open(O_WRONLY | O_CREAT | O_TRUNC, mode). Swift
            // on Darwin marks variadic open() unavailable; creat is the
            // non-variadic equivalent for this exact pattern.
            return creat(buf.baseAddress, 0o644)
        }
        guard fd >= 0 else {
            throw MuxerError.openStagingFileFailed(errno: errno)
        }
        self.fd = fd

        // Captured-byte counters surfaced into closures via a tiny
        // ref-typed counter box. Splitter callbacks update the box;
        // finalize() reads it. We can't capture `self` directly in
        // the closures because `self` is being initialized.
        let counter = ByteCounter()
        self.splitter = FragmentSplitter(
            onHeaderComplete: { initBytes in
                onInitCaptured(initBytes)
            },
            onFragmentBytes: { ptr, count in
                if counter.writeFailed { return }
                var written = 0
                while written < count {
                    let n = write(fd, ptr.advanced(by: written), count - written)
                    if n < 0 {
                        let err = errno
                        if err == EINTR { continue }
                        counter.writeFailed = true
                        return
                    }
                    if n == 0 {
                        counter.writeFailed = true
                        return
                    }
                    written += n
                }
                counter.bytesWritten += count
            }
        )
        self.byteCounter = counter

        // Allocate the mp4 muxer. URL string is a placeholder; the
        // muxer never opens a real file because we hand it our own
        // AVIO context via io_open.
        var ctxOut: UnsafeMutablePointer<AVFormatContext>?
        let allocRet = avformat_alloc_output_context2(&ctxOut, nil, "mp4", "segment.m4s")
        guard allocRet == 0, let ctx = ctxOut else {
            close(fd)
            try? FileManager.default.removeItem(at: stagingPath)
            throw MuxerError.allocFailed(code: allocRet)
        }
        self.formatContext = ctx

        // strict=-2 lets the mp4 muxer write Dolby Vision atoms (dvcC,
        // dvvC) and other non-strict-ISOBMFF extensions when the source
        // codecpar carries DV side data. Matches the prior hls-path
        // setting; mp4 muxer respects the same compliance level.
        ctx.pointee.strict_std_compliance = -2

        // Wire io trampolines so write_header / packet writes / trailer
        // all route through the FragmentSplitter into our staging fd
        // instead of opening a real file.
        ctx.pointee.opaque = Unmanaged.passUnretained(self).toOpaque()
        ctx.pointee.io_open = mp4SegmentMuxerIOOpen
        ctx.pointee.io_close2 = mp4SegmentMuxerIOClose

        // Video stream.
        guard let videoStream = avformat_new_stream(ctx, nil) else {
            cleanup()
            throw MuxerError.streamCreationFailed
        }
        let vCopy = avcodec_parameters_copy(videoStream.pointee.codecpar, video.codecpar)
        guard vCopy >= 0 else {
            cleanup()
            throw MuxerError.copyParametersFailed(code: vCopy)
        }
        videoStream.pointee.time_base = video.timeBase
        if let override = video.codecTagOverride,
           let tag = Self.mkTag(fromFourCC: override) {
            videoStream.pointee.codecpar.pointee.codec_tag = tag
        }

        // Audio stream (optional).
        if let audio = audio {
            guard let audioStream = avformat_new_stream(ctx, nil) else {
                cleanup()
                throw MuxerError.streamCreationFailed
            }
            let aCopy = avcodec_parameters_copy(audioStream.pointee.codecpar, audio.codecpar)
            guard aCopy >= 0 else {
                cleanup()
                throw MuxerError.copyParametersFailed(code: aCopy)
            }
            audioStream.pointee.time_base = audio.timeBase
        }

        // Movflags: the leak-free three. See class docstring.
        var opts: OpaquePointer? = nil
        defer { av_dict_free(&opts) }
        av_dict_set(&opts, "movflags", "+empty_moov+default_base_moof+frag_keyframe", 0)
        // hls_time-equivalent. With +frag_keyframe the muxer
        // auto-cuts at every keyframe; our segments are keyframe-
        // aligned so this is one fragment per muxer. Setting
        // frag_duration as a defensive backstop doesn't hurt.
        let fragMs = Int(targetSegmentDurationSeconds * 1_000_000)
        av_dict_set(&opts, "frag_duration", String(fragMs), 0)

        let ret = avformat_write_header(ctx, &opts)
        guard ret >= 0 else {
            cleanup()
            throw MuxerError.writeHeaderFailed(code: ret)
        }
        self.headerWritten = true

        muxerVideoTimeBase = ctx.pointee.streams.advanced(by: 0).pointee!.pointee.time_base
        if haveAudio {
            muxerAudioTimeBase = ctx.pointee.streams.advanced(by: 1).pointee!.pointee.time_base
        }
    }

    /// Strong ref to the byte-counter shared with the splitter
    /// closures. Owned here so the closures' captured reference stays
    /// alive for the muxer's lifetime.
    private let byteCounter: ByteCounter

    // MARK: - Pump-side API

    /// Write one packet via av_interleaved_write_frame. Caller has
    /// already rescaled the packet's pts/dts to the muxer's time_base
    /// (use `muxerVideoTimeBase` / `muxerAudioTimeBase` as targets)
    /// and set the correct output `stream_index`.
    ///
    /// Returns the libavformat return code, but in practice the only
    /// reasonable response to a non-zero return is to log and continue;
    /// the muxer state may be inconsistent but we'd tear it down soon
    /// anyway at the next segment boundary.
    @discardableResult
    func writePacket(_ packet: UnsafeMutablePointer<AVPacket>) -> Int32 {
        guard let ctx = formatContext else { return -1 }
        return av_interleaved_write_frame(ctx, packet)
    }

    /// Finalize the segment: write trailer, close staging file, free
    /// the format context, and return a (path, bytesWritten) tuple
    /// the caller can hand to the cache for adoption. Returns nil if
    /// any write failed during the segment's lifetime.
    func finalize() -> (path: URL, bytesWritten: Int)? {
        defer { cleanup() }

        // av_write_trailer may emit additional bytes (mfra etc.).
        // Those flow through the splitter which discards anything
        // not moof/mdat. Safe to call even if some packet writes
        // failed mid-segment; the muxer will at least close its
        // internal state cleanly.
        if let ctx = formatContext, headerWritten {
            _ = av_write_trailer(ctx)
        }

        if fd >= 0 {
            close(fd)
            fd = -1
        }

        // Pull the final write status off the shared counter. If
        // any write returned an error during the segment, discard
        // the staging file rather than handing a partial segment to
        // the cache.
        let succeeded = !byteCounter.writeFailed && byteCounter.bytesWritten > 0
        self.bytesWritten = byteCounter.bytesWritten
        self.writeFailed = byteCounter.writeFailed

        if succeeded {
            return (path: stagingPath, bytesWritten: byteCounter.bytesWritten)
        }
        try? FileManager.default.removeItem(at: stagingPath)
        return nil
    }

    // MARK: - Internal cleanup

    /// Free the format context + any buffer libavformat allocated for
    /// its io callbacks. Safe to call multiple times.
    private func cleanup() {
        if let ctx = formatContext {
            // Clear opaque first so any late io_open from the muxer's
            // own teardown path doesn't dereference a self we're about
            // to deinit. avformat_free_context shouldn't trigger
            // io_open at this point but defensive.
            ctx.pointee.opaque = nil
            avformat_free_context(ctx)
            formatContext = nil
        }
    }

    deinit {
        if fd >= 0 {
            close(fd)
        }
    }

    // MARK: - AVIO trampoline plumbing

    /// Called by the io_open trampoline to allocate a per-context AVIO
    /// buffer that routes writes back into the FragmentSplitter.
    /// Returns nil on alloc failure.
    fileprivate func makeAVIOContext() -> UnsafeMutablePointer<AVIOContext>? {
        let bufSize: Int32 = 65536
        guard let raw = av_malloc(Int(bufSize)) else { return nil }
        let buf = raw.assumingMemoryBound(to: UInt8.self)
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let pb = avio_alloc_context(
            buf,
            bufSize,
            /* write_flag */ 1,
            opaque,
            nil,
            mp4SegmentMuxerSinkWrite,
            nil
        ) else {
            av_free(raw)
            return nil
        }
        pb.pointee.seekable = 0
        return pb
    }

    /// Called by the io_close2 trampoline to flush + free a per-context
    /// AVIO buffer. Walks the FragmentSplitter to push any buffered
    /// bytes, then releases the avformat-side state.
    fileprivate func releaseAVIOContext(_ pb: UnsafeMutablePointer<AVIOContext>) {
        avio_flush(pb)
        if pb.pointee.buffer != nil {
            withUnsafeMutablePointer(to: &pb.pointee.buffer) { bufRef in
                bufRef.withMemoryRebound(to: Optional<UnsafeMutableRawPointer>.self, capacity: 1) { raw in
                    av_freep(UnsafeMutableRawPointer(raw))
                }
            }
        }
        var pbVar: UnsafeMutablePointer<AVIOContext>? = pb
        avio_context_free(&pbVar)
    }

    /// Receive a chunk of muxer output. Routes through the
    /// FragmentSplitter so init bytes land in `onInitCaptured` and
    /// fragment bytes land in the staging POSIX file.
    fileprivate func receive(_ buf: UnsafePointer<UInt8>, count: Int) {
        splitter.feed(buf, count: count)
    }

    // MARK: - Helpers

    /// Encode a four-character code as a little-endian UInt32.
    private static func mkTag(fromFourCC fourCC: String) -> UInt32? {
        let chars = Array(fourCC)
        guard chars.count == 4 else { return nil }
        var tag: UInt32 = 0
        for (i, ch) in chars.enumerated() {
            guard let ascii = ch.asciiValue else { return nil }
            tag |= UInt32(ascii) << (i * 8)
        }
        return tag
    }
}

/// Shared mutable state between the FragmentSplitter's
/// non-self-capturing closures and the muxer that owns them. Ref-typed
/// so the closures can mutate it without capturing `self` (which
/// doesn't exist yet during init).
private final class ByteCounter {
    var bytesWritten: Int = 0
    var writeFailed: Bool = false
}

// MARK: - C callback bridges

/// `s->io_open` trampoline. Recovers the MP4SegmentMuxer via the
/// format context's opaque and asks it for a fresh AVIO context.
private func mp4SegmentMuxerIOOpen(
    s: UnsafeMutablePointer<AVFormatContext>?,
    pb: UnsafeMutablePointer<UnsafeMutablePointer<AVIOContext>?>?,
    url: UnsafePointer<CChar>?,
    flags: Int32,
    options: UnsafeMutablePointer<OpaquePointer?>?
) -> Int32 {
    guard let s = s, let pb = pb, let opaque = s.pointee.opaque else {
        return -1
    }
    let muxer = Unmanaged<MP4SegmentMuxer>.fromOpaque(opaque).takeUnretainedValue()
    guard let ctx = muxer.makeAVIOContext() else { return -1 }
    pb.pointee = ctx
    return 0
}

/// `s->io_close2` trampoline. Frees the AVIO context allocated in
/// io_open. The MP4SegmentMuxer holds the strong reference to the
/// splitter so the splitter's accumulated state isn't lost.
private func mp4SegmentMuxerIOClose(
    s: UnsafeMutablePointer<AVFormatContext>?,
    pb: UnsafeMutablePointer<AVIOContext>?
) -> Int32 {
    guard let s = s, let pb = pb, let opaque = s.pointee.opaque else { return 0 }
    let muxer = Unmanaged<MP4SegmentMuxer>.fromOpaque(opaque).takeUnretainedValue()
    muxer.releaseAVIOContext(pb)
    return 0
}

/// `avio_alloc_context` write callback. Recovers the muxer via the
/// avio opaque (set to the MP4SegmentMuxer instance) and forwards the
/// bytes to its FragmentSplitter.
private func mp4SegmentMuxerSinkWrite(
    opaque: UnsafeMutableRawPointer?,
    buf: UnsafePointer<UInt8>?,
    size: Int32
) -> Int32 {
    guard let opaque = opaque, let buf = buf, size > 0 else { return -1 }
    let muxer = Unmanaged<MP4SegmentMuxer>.fromOpaque(opaque).takeUnretainedValue()
    muxer.receive(buf, count: Int(size))
    return size
}
