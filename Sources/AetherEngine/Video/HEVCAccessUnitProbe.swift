import Foundation

/// Read-only probe over an HEVC access unit in AVCC layout (length-prefixed NAL units).
/// Used by the #92 open-GOP diagnostics: classify a segment's leading keyframe as IDR vs CRA vs
/// BLA and recognize RASL/RADL leading-picture slice types. NAL-header inspection only, no slice
/// parse, no allocation. AVCC layout matches DoviRpuConverter (4-byte big-endian length prefix).
enum HEVCAccessUnitProbe {

    // HEVC NAL unit types (H.265 Table 7-1), the subset we classify.
    static let nalRaslN: UInt8 = 8     // RASL_N: leading, dropped when NoRaslOutputFlag is set
    static let nalRaslR: UInt8 = 9     // RASL_R
    static let nalRadlN: UInt8 = 6
    static let nalRadlR: UInt8 = 7
    static let nalBlaWLp: UInt8 = 16
    static let nalIdrWRadl: UInt8 = 19
    static let nalIdrNLp: UInt8 = 20
    static let nalCra: UInt8 = 21

    /// VCL NAL types are 0...31; non-VCL (VPS/SPS/PPS/SEI/AUD) are 32...63.
    static func isVCL(_ t: UInt8) -> Bool { t <= 31 }
    /// IRAP (random-access point) slice types: BLA 16...18, IDR 19...20, CRA 21 (16...23 inclusive).
    static func isIRAP(_ t: UInt8) -> Bool { t >= 16 && t <= 23 }
    static func isIDR(_ t: UInt8) -> Bool { t == 19 || t == 20 }
    static func isCRA(_ t: UInt8) -> Bool { t == 21 }
    static func isRASL(_ t: UInt8) -> Bool { t == 8 || t == 9 }

    /// First VCL slice NAL type in the access unit, skipping non-VCL NALs (VPS/SPS/PPS/SEI/AUD).
    /// Returns nil when there is no VCL NAL or the buffer is malformed/truncated.
    static func firstSliceNALType(
        _ data: UnsafePointer<UInt8>, size: Int, lengthPrefixSize: Int = 4
    ) -> UInt8? {
        var off = 0
        while off + lengthPrefixSize <= size {
            var len = 0
            for i in 0..<lengthPrefixSize { len = (len << 8) | Int(data[off + i]) }
            let nalStart = off + lengthPrefixSize
            if len <= 0 || nalStart + len > size { break }
            // HEVC NAL header byte0: forbidden_zero(1) | nal_unit_type(6) | nuh_layer_id MSB(1).
            let t = (data[nalStart] >> 1) & 0x3F
            if isVCL(t) { return t }
            off = nalStart + len
        }
        return nil
    }

    static func firstSliceNALType(_ bytes: [UInt8], lengthPrefixSize: Int = 4) -> UInt8? {
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return nil }
            return firstSliceNALType(base, size: buf.count, lengthPrefixSize: lengthPrefixSize)
        }
    }

    /// Short label for diagnostics.
    static func label(forSliceType t: UInt8) -> String {
        switch t {
        case 19, 20: return "IDR"
        case 21: return "CRA"
        case 16, 17, 18: return "BLA"
        case 8, 9: return "RASL"
        case 6, 7: return "RADL"
        default: return isVCL(t) ? "TRAIL(\(t))" : "nonVCL(\(t))"
        }
    }
}
