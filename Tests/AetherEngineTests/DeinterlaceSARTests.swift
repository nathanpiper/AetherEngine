import Testing
import Libavutil
import Libavfilter
@testable import AetherEngine

/// Regression for anamorphic SD content (DVD rips: NTSC 720x480 stored at
/// 4:3, PAL 720x576, widescreen DVDs) rendering "flattened" (horizontally
/// squished).
///
/// Interlaced DVD MPEG-2 decodes through the software path and is
/// deinterlaced (bwdif/yadif). The picture only displays at the correct
/// aspect if the source sample aspect ratio (SAR) survives the filter and
/// gets attached to the output pixel buffer. `DeinterlaceFilter` declares
/// the SAR on its buffer source (`pixel_aspect`), and bwdif/yadif must
/// carry it through to the pulled frame's `sample_aspect_ratio` — that's
/// the value `SoftwareVideoDecoder.attachPixelAspectRatio` reads to set
/// `kCVImageBufferPixelAspectRatioKey`.
struct DeinterlaceSARTests {

    /// Allocate a small interlaced YUV420P frame carrying a SAR.
    private func makeFrame(pts: Int64, sar: AVRational) -> UnsafeMutablePointer<AVFrame> {
        let f = av_frame_alloc()!
        f.pointee.width = 64
        f.pointee.height = 64
        f.pointee.format = AV_PIX_FMT_YUV420P.rawValue
        f.pointee.pts = pts
        f.pointee.sample_aspect_ratio = sar
        f.pointee.flags |= (1 << 3)  // AV_FRAME_FLAG_INTERLACED
        _ = av_frame_get_buffer(f, 0)
        return f
    }

    @Test("Deinterlacer preserves the source SAR on its output frames")
    func deinterlacePreservesSAR() {
        // NTSC 4:3 DVD SAR: 720x480 displayed at 4:3 is 8:9 pixels.
        let sourceSAR = AVRational(num: 8, den: 9)
        let streamTB = AVRational(num: 1, den: 30)

        let filter = DeinterlaceFilter()
        defer { filter.teardown() }

        let out = av_frame_alloc()!
        defer { var o: UnsafeMutablePointer<AVFrame>? = out; av_frame_free(&o) }

        var sawOutput = false
        for pts in Int64(0)..<8 {
            let f = makeFrame(pts: pts, sar: sourceSAR)
            let built = filter.ensureGraph(frame: f, timeBase: streamTB)
            #expect(built, "bwdif/yadif must be available in the linked FFmpeg build")
            guard built else { var ff: UnsafeMutablePointer<AVFrame>? = f; av_frame_free(&ff); return }

            #expect(filter.push(f) >= 0)
            var ff: UnsafeMutablePointer<AVFrame>? = f
            av_frame_free(&ff)

            while filter.pull(into: out) >= 0 {
                sawOutput = true
                let outSAR = out.pointee.sample_aspect_ratio
                // The deinterlacer must not flatten the SAR to 0:0 or 1:1;
                // it has to match the source the buffer source was told
                // about. Pre-fix the SW decoder never read this anyway, so
                // even a preserved SAR rendered square.
                #expect(outSAR.num == sourceSAR.num && outSAR.den == sourceSAR.den,
                        "deinterlaced SAR \(outSAR.num):\(outSAR.den) lost the source \(sourceSAR.num):\(sourceSAR.den)")
                av_frame_unref(out)
            }
        }

        #expect(sawOutput, "filter produced no frames")
    }
}
