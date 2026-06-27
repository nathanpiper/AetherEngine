import Foundation
import Libavcodec

/// Parses the bare CEA-608/708 `cc_data` triplet stream that FFmpeg's MOV demuxer emits for a
/// QuickTime/MP4 closed-caption track (`c608`). The caption bytes are a real, demuxable subtitle stream:
/// the demuxer strips the `cdat`/`cdt2` atom wrapper and hands downstream a sequence of
/// `(cc_valid|cc_type, cc_data_1, cc_data_2)` triplets, which this turns into `CCTriplet`s. Pure byte
/// parsing — no bitstream decode. (#77)
enum CCDataParser {

    /// One `(cc_valid|cc_type, cc_data_1, cc_data_2)` triplet from a `cc_data` block.
    struct CCTriplet: Equatable {
        /// cc_type: 0/1 = CEA-608 field 1/2; 2/3 = CEA-708 DTVCC packet data.
        let type: UInt8
        let data0: UInt8
        let data1: UInt8
    }

    /// All valid `cc_data` triplets in `packet`, in stream order. The packet is a bare triplet sequence;
    /// each triplet is 3 bytes and only those with the cc_valid bit (`0x04`) set are returned.
    static func parseCCDataTriplets(packet: UnsafePointer<AVPacket>) -> [CCTriplet] {
        guard let data = packet.pointee.data, packet.pointee.size >= 3 else { return [] }
        let n = Int(packet.pointee.size)
        var triplets: [CCTriplet] = []
        var i = 0
        while i + 3 <= n {
            let a = data[i]
            if (a & 0x04) != 0 {   // cc_valid
                triplets.append(CCTriplet(type: a & 0x03, data0: data[i + 1], data1: data[i + 2]))
            }
            i += 3
        }
        return triplets
    }
}
