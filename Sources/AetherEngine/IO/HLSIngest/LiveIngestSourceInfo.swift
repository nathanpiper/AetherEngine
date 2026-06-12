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
}
