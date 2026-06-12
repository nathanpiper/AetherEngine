import Foundation

/// First-segment format of a live HLS rendition, classified from the
/// segment's leading bytes. The MAIN variant reader only accepts
/// `.mpegts`; a companion AUDIO rendition additionally accepts Apple's
/// packed-audio shape (raw ADTS AAC, per the HLS spec each segment
/// prefixed with an ID3v2 tag carrying the program-clock PRIV frame).
enum LiveSegmentFormat: Equatable {
    /// MPEG-TS: sync byte 0x47.
    case mpegts
    /// Raw ADTS AAC with no leading ID3 tag: syncword 0xFFF, layer 0
    /// (first byte 0xFF, second byte & 0xF6 == 0xF0).
    case adtsAAC
    /// ID3v2-prefixed packed audio ("ID3" magic). Apple's packed-audio
    /// segments all start like this; the ADTS frames follow the tag.
    case id3PackedAudio

    /// Classify a segment's leading bytes; nil for anything else
    /// (fMP4 `ftyp`, WebVTT, garbage).
    static func classify(_ bytes: Data) -> LiveSegmentFormat? {
        let head = [UInt8](bytes.prefix(3))
        guard !head.isEmpty else { return nil }
        if head[0] == 0x47 { return .mpegts }
        if head.count >= 2, head[0] == 0xFF, head[1] & 0xF6 == 0xF0 { return .adtsAAC }
        if head.count >= 3, head[0] == 0x49, head[1] == 0x44, head[2] == 0x33 { return .id3PackedAudio }
        return nil
    }
}

/// Parser for the ID3v2 tag Apple's HLS packed-audio spec puts at the
/// start of every packed segment. The only frame we care about is the
/// PRIV frame with owner "com.apple.streaming.transportStreamTimestamp",
/// whose 8-byte big-endian payload is the segment's first sample's
/// presentation time on the variant's shared 90 kHz program clock
/// (masked to 33 bits like an MPEG-TS PCR/PTS).
///
/// FFmpeg's raw "aac" demuxer skips these tags without surfacing the
/// timestamp, so the ingest parses it here and the producer anchors a
/// synthesized side-audio clock on it (see
/// `HLSSegmentProducer.PackedAudioSynthClock`).
enum PackedAudioID3 {

    /// Owner string of Apple's program-clock PRIV frame.
    static let appleTimestampOwner = "com.apple.streaming.transportStreamTimestamp"

    /// Extract the Apple transport-stream timestamp from an
    /// ID3v2-prefixed segment, in 90 kHz ticks masked to 33 bits.
    /// Handles ID3v2.4 (syncsafe frame sizes) and ID3v2.3 (plain
    /// big-endian frame sizes). Returns nil when the tag is absent,
    /// malformed, unsynchronised (Apple never sets that flag), or
    /// carries no PRIV frame with the Apple owner.
    static func transportStreamTimestamp90k(in segment: Data) -> Int64? {
        // The tag sits at the very head of the segment and is tiny in
        // practice (Apple writes ~73 bytes); 4 KB is a generous bound
        // that still avoids copying a whole segment.
        let b = [UInt8](segment.prefix(4096))
        guard b.count >= 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return nil }
        let major = b[3]
        // v2.2 uses 3-byte frame IDs/sizes and never appears in HLS
        // packed audio; only handle the v2.3 / v2.4 layouts.
        guard major == 3 || major == 4 else { return nil }
        let flags = b[5]
        // Unsynchronisation would require de-escaping 0xFF 0x00 pairs;
        // no packed-audio producer sets it. Bail rather than mis-parse.
        guard flags & 0x80 == 0 else { return nil }
        guard let tagSize = syncsafe32(b, at: 6) else { return nil }
        var pos = 10
        let end = min(b.count, 10 + tagSize)

        // Skip the extended header if present. v2.4's size field is
        // syncsafe and INCLUDES itself; v2.3's is plain big-endian and
        // EXCLUDES its own 4 bytes.
        if flags & 0x40 != 0 {
            if major == 4 {
                guard let extSize = syncsafe32(b, at: pos) else { return nil }
                pos += max(extSize, 6)
            } else {
                guard pos + 4 <= end else { return nil }
                pos += 4 + plain32(b, at: pos)
            }
        }

        while pos + 10 <= end {
            if b[pos] == 0 { break } // padding reached
            let isPriv = b[pos] == 0x50 && b[pos + 1] == 0x52
                && b[pos + 2] == 0x49 && b[pos + 3] == 0x56 // "PRIV"
            let frameSize: Int
            if major == 4 {
                guard let s = syncsafe32(b, at: pos + 4) else { return nil }
                frameSize = s
            } else {
                frameSize = plain32(b, at: pos + 4)
            }
            let bodyStart = pos + 10
            guard frameSize > 0, bodyStart + frameSize <= end else { return nil }
            if isPriv,
               let ts = appleTimestamp(privBody: b[bodyStart..<(bodyStart + frameSize)]) {
                return ts
            }
            pos = bodyStart + frameSize
        }
        return nil
    }

    /// PRIV body = owner string, NUL terminator, private payload. For
    /// the Apple owner the payload is an 8-byte big-endian timestamp.
    private static func appleTimestamp(privBody: ArraySlice<UInt8>) -> Int64? {
        guard let nul = privBody.firstIndex(of: 0) else { return nil }
        let owner = String(decoding: privBody[privBody.startIndex..<nul], as: UTF8.self)
        guard owner == appleTimestampOwner else { return nil }
        let payload = privBody[(nul + 1)...]
        guard payload.count >= 8 else { return nil }
        var value: UInt64 = 0
        for byte in payload.prefix(8) {
            value = (value << 8) | UInt64(byte)
        }
        // Effective clock is 90 kHz over 33 bits, like a TS PTS.
        return Int64(value & 0x1_FFFF_FFFF)
    }

    /// 4-byte syncsafe integer (7 bits per byte, high bit must be 0).
    private static func syncsafe32(_ b: [UInt8], at index: Int) -> Int? {
        guard index + 4 <= b.count else { return nil }
        let bytes = b[index..<(index + 4)]
        guard bytes.allSatisfy({ $0 & 0x80 == 0 }) else { return nil }
        return bytes.reduce(0) { ($0 << 7) | Int($1) }
    }

    /// 4-byte plain big-endian integer (ID3v2.3 frame sizes).
    private static func plain32(_ b: [UInt8], at index: Int) -> Int {
        guard index + 4 <= b.count else { return 0 }
        return (Int(b[index]) << 24) | (Int(b[index + 1]) << 16)
            | (Int(b[index + 2]) << 8) | Int(b[index + 3])
    }
}
