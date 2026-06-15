import Testing
import Libavcodec
@testable import AetherEngine

/// Routing decision for EAC3 sources, including EAC3+JOC (Atmos). EAC3
/// always stream-copies into the fMP4 segments regardless of the audio
/// output route: a JOC track is signaled in the playlist as `ec-3`, the
/// exact same CODECS string as a non-JOC EAC3 5.1 track, so AVPlayer's
/// variant selection cannot tell them apart and accepts both on every
/// route. Downstream the renderer decides — HDMI passes DD+/JOC through,
/// AirPods render Atmos spatially, plain Bluetooth A2DP / LE downmixes
/// the bed channels to stereo natively. The FLAC bridge is never the
/// right answer for a route reason (AetherEngine#34).
///
/// The only EAC3 case that bridges is a source whose codecpar lacks the
/// `dec3` extradata the mp4 muxer needs to write the sample entry; that
/// is caught route-independently by `probeWriteHeader` in
/// `buildProducerWithAudioCascade`, not by the codec-compat table.
///
/// libavcodec marks JOC with EAC3 profile == 30 (FF_PROFILE_EAC3_DDP_ATMOS).
@Suite("EAC3 / JOC route bridge routing")
struct JOCRouteBridgeTests {

    @Test("EAC3 is a stream-copy codec, never a route-driven bridge (issue #34)")
    func eac3StreamCopies() {
        let compat = HLSVideoEngine.AudioCodecCompat.from(AV_CODEC_ID_EAC3)
        #expect(compat == .eac3)
        #expect(compat.requiresBridge == false)
        #expect(compat.hlsCodecsString == "ec-3")
    }

    @Test("JOC and non-JOC EAC3 share the same CODECS string and routing")
    func jocSignalsLikePlainEAC3() {
        // JOC-ness lives in the EAC3 profile (30), not in a separate
        // codec id, so the routing table keys off the same `.eac3`
        // compat for both. The playlist CODECS string is therefore
        // identical, which is exactly why AVPlayer cannot reject the JOC
        // variant on a route it accepts plain EAC3 5.1 on.
        let compat = HLSVideoEngine.AudioCodecCompat.from(AV_CODEC_ID_EAC3)
        #expect(compat.hlsCodecsString == "ec-3")
        #expect(compat.requiresBridge == false)
    }
}
