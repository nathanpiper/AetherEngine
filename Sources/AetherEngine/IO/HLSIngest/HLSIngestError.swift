import Foundation

/// Failure surface of the live HLS ingest. Every case is terminal for the
/// direct-play attempt; the host (Sodalite) maps any of these into its
/// fallback onto the Jellyfin-mediated path. Phase-1 limits (encryption,
/// fMP4 segments) are deliberate: they fall back rather than half-work.
public enum HLSIngestError: Error, Equatable, CustomStringConvertible {
    /// The playlist URL did not answer, or answered with a non-2xx status.
    case playlistUnreachable(status: Int)
    /// The response is not an HLS playlist (missing #EXTM3U) or is
    /// structurally unusable (no segments, no target duration).
    case playlistInvalid(reason: String)
    /// EXT-X-KEY with METHOD != NONE. AES-128 is a later, evidence-gated phase.
    case encryptedNotSupported
    /// EXT-X-MAP present, or the first fetched segment does not start with
    /// the MPEG-TS sync byte 0x47. fMP4-segment HLS is a later phase.
    case unsupportedSegmentFormat
    /// The playlist refreshed but produced no new segment for the stall
    /// budget (provider died or froze).
    case ingestStalled
    /// The selected variant references an alternate-audio group whose
    /// renditions live in a separate playlist (EXT-X-MEDIA:TYPE=AUDIO
    /// with URI) in a shape the ingest still cannot handle. The common
    /// shape (ARD-style demuxed audio, device repro: Das Erste HD via
    /// ARD's CDN) IS supported via a companion reader + side demuxer;
    /// this error remains for the residual cases (unresolvable
    /// rendition URI, and the engine-side guard for demuxed audio on
    /// the software video path). Failing fast at join time beats
    /// silently playing video without sound.
    case demuxedAudioNotSupported

    public var description: String {
        switch self {
        case .playlistUnreachable(let status): "playlistUnreachable(\(status))"
        case .playlistInvalid(let reason): "playlistInvalid(\(reason))"
        case .encryptedNotSupported: "encryptedNotSupported"
        case .unsupportedSegmentFormat: "unsupportedSegmentFormat"
        case .ingestStalled: "ingestStalled"
        case .demuxedAudioNotSupported: "demuxedAudioNotSupported"
        }
    }
}
