import Foundation

/// Implemented by custom live readers that know their upstream's
/// segment cadence; the engine uses it to shape the local playlist
/// (TARGETDURATION floor, blocking-reload eligibility) so AVPlayer's
/// timing model matches the real arrival pattern.
protocol LiveIngestSourceInfo: AnyObject {
    /// The upstream media playlist's EXT-X-TARGETDURATION in seconds,
    /// once known (after the resolver fetched the playlist). nil before.
    var upstreamTargetDuration: Double? { get }

    /// Second forward-only reader carrying the variant's DEMUXED audio
    /// rendition (master playlists where #EXT-X-MEDIA:TYPE=AUDIO has a
    /// URI: ARD-style channels publish video-only variants plus a
    /// separate audio playlist). nil when the variant's audio is muxed
    /// into the main stream. The engine demuxes this through a SIDE
    /// demuxer and merges its packets with the main stream's by DTS.
    ///
    /// Ordering contract mirrors `upstreamTargetDuration`: the value is
    /// nil-stable by the time any stream byte has flowed from the main
    /// reader (the resolver installs it BEFORE the first video segment
    /// byte is published), so a consumer that has already received main
    /// bytes can trust nil to mean "muxed audio". The companion is lazy
    /// (starts ingesting on ITS first read()) and is closed by the main
    /// reader's close().
    var companionAudioReader: IOReader? { get }

    /// FFmpeg demuxer name for THIS reader's stream ("mpegts" or
    /// "aac"), blocking until the reader has fetched and classified its
    /// FIRST segment (bounded; nil when the ingest went terminal or the
    /// classification didn't land inside the bound). Classification
    /// happens before any byte is published, so resolving consumes no
    /// stream data. The engine calls this on a COMPANION audio reader
    /// to pick the side demuxer's format: Apple packed-audio renditions
    /// (raw ADTS AAC) need FFmpeg's "aac" demuxer, TS renditions keep
    /// "mpegts".
    func resolveSegmentFormatHint() -> String?

    /// Apple packed-audio program-clock anchor: the ID3v2 PRIV frame
    /// "com.apple.streaming.transportStreamTimestamp" of THIS reader's
    /// first segment, a 33-bit 90 kHz timestamp on the variant group's
    /// shared program clock. nil for TS streams (their packets carry
    /// program-clock timestamps natively). Ordering contract mirrors
    /// `upstreamTargetDuration`: written under the reader's lock before
    /// the first segment byte is published, so a consumer that has
    /// received stream bytes (e.g. the engine after the side demuxer
    /// open) observes the final value; a consumer that resolved the
    /// format hint as "aac" is guaranteed non-nil (a packed first
    /// segment without a parsable PRIV timestamp goes terminal with
    /// `demuxedAudioNotSupported` instead).
    var packedAudioTimestampOffset90k: Int64? { get }
}
