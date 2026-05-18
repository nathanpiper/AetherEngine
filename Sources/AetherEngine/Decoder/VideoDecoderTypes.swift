import Foundation
import CoreMedia
import CoreVideo
import Libavformat
import Libavcodec

/// Callback type for decoded video frames.
///
/// `hdr10PlusT35` carries the source-frame's HDR10+ dynamic metadata,
/// already serialised to the ITU-T T.35 byte format Apple's
/// `kCMSampleAttachmentKey_HDR10PlusPerFrameData` expects. Nil for
/// non-HDR10+ streams.
typealias DecodedFrameHandler = (CVPixelBuffer, CMTime, Data?) -> Void

/// Common surface for the non-AVPlayer playback host's video decoder.
/// Both `SoftwareVideoDecoder` (libavcodec, used for AV1 / VP9) and
/// `HardwareVideoDecoder` (VTDecompressionSession, used for HEVC)
/// conform; the host swaps the implementation per codec at load time
/// without changing the demux-loop wiring.
protocol VideoDecodingPipeline: AnyObject {
    var onFrame: DecodedFrameHandler? { get set }
    var onFirstHDR10PlusDetected: (() -> Void)? { get set }
    var skipUntilPTS: CMTime? { get set }

    func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws
    func decode(packet: UnsafeMutablePointer<AVPacket>)
    func flush()
    func close()
}

enum VideoDecoderError: Error, LocalizedError {
    case noCodecParameters
    case unsupportedCodec(id: UInt32)
    case noExtradata
    case formatDescriptionFailed(status: OSStatus)
    case sessionCreationFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .noCodecParameters: "No codec parameters"
        case .unsupportedCodec(let id): "Unsupported video codec (id: \(id))"
        case .noExtradata: "Missing codec extradata"
        case .formatDescriptionFailed(let s): "Format description failed (\(s))"
        case .sessionCreationFailed(let s): "Decoder session failed (\(s))"
        }
    }
}
