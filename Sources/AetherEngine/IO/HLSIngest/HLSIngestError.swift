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
    /// EXT-X-KEY with an unsupported METHOD (SAMPLE-AES, SAMPLE-AES-CTR,
    /// or an AES-128 tag with no URI). Plain METHOD=AES-128 is supported
    /// inline (clear-key AES-CBC, see `HLSSegmentDecryptor`); only the
    /// methods that need real DRM or sample-level handling fall back.
    case encryptedNotSupported
    /// An AES-128 segment could not be decrypted: the key fetch failed or
    /// CommonCrypto rejected the key/IV/ciphertext. Terminal so the host
    /// falls back to the server-muxed route rather than feeding the
    /// demuxer ciphertext.
    case segmentDecryptFailed(reason: String)
    /// EXT-X-MAP present, or the first fetched segment is not in a
    /// format the reader's role accepts: the MAIN variant must start
    /// with the MPEG-TS sync byte 0x47, a companion AUDIO rendition may
    /// additionally be Apple packed audio (ID3v2-prefixed raw ADTS AAC,
    /// see `LiveSegmentFormat`). fMP4-segment HLS is a later phase.
    case unsupportedSegmentFormat
    /// The playlist refreshed but produced no new segment for the stall
    /// budget (provider died or froze).
    case ingestStalled
    /// The selected variant references an alternate-audio group whose
    /// renditions live in a separate playlist (EXT-X-MEDIA:TYPE=AUDIO
    /// with URI) in a shape the ingest still cannot handle. The common
    /// shapes ARE supported via a companion reader + side demuxer:
    /// MPEG-TS audio renditions, and Apple packed audio (raw ADTS AAC
    /// with the ID3 PRIV program-clock timestamp; ARD-style channels,
    /// device repro: Das Erste HD via ARD's CDN). This error remains
    /// for the residual cases: unresolvable rendition URI, packed audio
    /// whose first segment carries NO parsable PRIV timestamp (no way
    /// to align the side audio to the video's program clock without
    /// guessing, which risks silent A/V desync), and the engine-side
    /// guard for demuxed audio on the software video path. Failing fast
    /// at join time beats silently playing video without sound.
    case demuxedAudioNotSupported

    public var description: String {
        switch self {
        case .playlistUnreachable(let status): "playlistUnreachable(\(status))"
        case .playlistInvalid(let reason): "playlistInvalid(\(reason))"
        case .encryptedNotSupported: "encryptedNotSupported"
        case .segmentDecryptFailed(let reason): "segmentDecryptFailed(\(reason))"
        case .unsupportedSegmentFormat: "unsupportedSegmentFormat"
        case .ingestStalled: "ingestStalled"
        case .demuxedAudioNotSupported: "demuxedAudioNotSupported"
        }
    }
}
