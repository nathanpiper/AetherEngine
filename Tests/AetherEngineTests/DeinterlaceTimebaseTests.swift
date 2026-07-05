import Testing
import Libavutil
import Libavfilter
@testable import AetherEngine

/// Regression: bwdif/yadif halve the filter output time_base and double PTS; DeinterlaceFilter.pull
/// must rescale back into stream time_base or playback runs at half speed and resume freezes.
struct DeinterlaceTimebaseTests {

    private func makeFrame(pts: Int64) -> UnsafeMutablePointer<AVFrame> {
        let f = av_frame_alloc()!
        f.pointee.width = 64
        f.pointee.height = 64
        f.pointee.format = AV_PIX_FMT_YUV420P.rawValue
        f.pointee.pts = pts
        f.pointee.flags |= (1 << 3)  // AV_FRAME_FLAG_INTERLACED
        _ = av_frame_get_buffer(f, 0)
        return f
    }

    @Test("Deinterlaced frame PTS stays on the stream time_base (no 2x drift)")
    func deinterlacedPTSMatchesStreamTimebase() {
        // 1 tick == 1/30 s; source PTS N must emerge as N (not 2N) on the stream time_base.
        let streamTB = AVRational(num: 1, den: 30)
        let tbSeconds = Double(streamTB.num) / Double(streamTB.den)

        let filter = DeinterlaceFilter()
        defer { filter.teardown() }

        let inputPTS: [Int64] = [0, 1, 2, 3, 4, 5, 6, 7]
        var outSeconds: [Double] = []

        let out = av_frame_alloc()!
        defer { var o: UnsafeMutablePointer<AVFrame>? = out; av_frame_free(&o) }

        for pts in inputPTS {
            let f = makeFrame(pts: pts)
            let built = filter.ensureGraph(frame: f, timeBase: streamTB)
            #expect(built, "bwdif/yadif must be available in the linked FFmpeg build")
            guard built else { var ff: UnsafeMutablePointer<AVFrame>? = f; av_frame_free(&ff); return }

            #expect(filter.push(f) >= 0)
            var ff: UnsafeMutablePointer<AVFrame>? = f
            av_frame_free(&ff)

            while filter.pull(into: out) >= 0 {
                if out.pointee.pts != Int64.min {
                    outSeconds.append(Double(out.pointee.pts) * tbSeconds)
                }
                av_frame_unref(out)
            }
        }

        #expect(!outSeconds.isEmpty, "filter produced no frames")

        // Pre-fix outputs ran to ~14/30 s (2x). Deinterlacer holds one frame of lookahead.
        let maxInput = Double(inputPTS.max()!) * tbSeconds
        for s in outSeconds {
            #expect(s <= maxInput + tbSeconds * 0.5,
                    "output PTS \(s)s exceeds source range (max \(maxInput)s), time_base doubled")
        }

        let sorted = outSeconds.sorted()
        if sorted.count >= 2 {
            for i in 1..<sorted.count {
                let delta = sorted[i] - sorted[i - 1]
                #expect(abs(delta - tbSeconds) < tbSeconds * 0.25,
                        "frame spacing \(delta)s is not ~\(tbSeconds)s (time_base doubled)")
            }
        }
    }
}
