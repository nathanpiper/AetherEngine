import Foundation

/// One variant entry of a master playlist (#EXT-X-STREAM-INF).
struct HLSVariant: Equatable {
    let bandwidth: Int
    let uri: String
    /// GROUP-ID from the STREAM-INF's AUDIO attribute, nil when the
    /// variant declares no alternate-audio group.
    let audioGroupID: String?
}

/// One out-of-band audio rendition of a master playlist
/// (#EXT-X-MEDIA:TYPE=AUDIO with a URI attribute). The reader ingests
/// the chosen rendition through a companion `HLSLiveIngestReader` so
/// demuxed-audio variants (ARD-style) direct-play with sound.
struct HLSAudioRendition: Equatable {
    let groupID: String
    let uri: String
    /// DEFAULT=YES on the EXT-X-MEDIA line. The reader prefers the
    /// default rendition of the selected variant's group.
    let isDefault: Bool
}

/// Parsed master playlist: the variants plus the audio GROUP-IDs whose
/// renditions live OUT-OF-BAND (#EXT-X-MEDIA:TYPE=AUDIO with a URI
/// attribute), and those renditions themselves. A variant referencing
/// such a group is video-only; its audio is ingested from the
/// rendition's own playlist via a companion reader (see
/// HLSLiveIngestReader). `demuxedAudioGroupIDs` is derivable from
/// `audioRenditions` but kept as a stable set so the reader's group
/// membership check stays O(1) and the pre-companion API survives.
/// EXT-X-MEDIA entries WITHOUT a URI mean the audio is muxed into the
/// variant stream itself and play fine.
struct HLSMasterPlaylist: Equatable {
    let variants: [HLSVariant]
    let demuxedAudioGroupIDs: Set<String>
    let audioRenditions: [HLSAudioRendition]
}

/// AES-128 segment encryption context resolved from the EXT-X-KEY tag
/// that governs a segment. Only METHOD=AES-128 (full-segment AES-CBC,
/// the standard clear-key HLS scheme Pluto/Samsung-TV+ and most FAST
/// providers use) is modelled here; SAMPLE-AES and other methods are
/// rejected at parse time (see `HLSMediaPlaylist.hasUnsupportedEncryption`).
/// `iv` is always the final 16-byte initialisation vector: the explicit
/// EXT-X-KEY IV attribute when present, otherwise the big-endian segment
/// media-sequence number per RFC 8216 section 5.2.
struct HLSSegmentCrypt: Equatable {
    let keyURI: String
    let iv: Data
}

/// One media segment of a media playlist.
struct HLSMediaSegment: Equatable {
    let uri: String
    let duration: Double
    /// True when an EXT-X-DISCONTINUITY tag directly precedes this segment.
    let discontinuityBefore: Bool
    /// AES-128 key context governing this segment, nil when the segment
    /// is in the clear (no EXT-X-KEY or METHOD=NONE).
    let crypt: HLSSegmentCrypt?

    init(uri: String, duration: Double, discontinuityBefore: Bool, crypt: HLSSegmentCrypt? = nil) {
        self.uri = uri
        self.duration = duration
        self.discontinuityBefore = discontinuityBefore
        self.crypt = crypt
    }
}

struct HLSMediaPlaylist: Equatable {
    let targetDuration: Double
    let mediaSequence: Int
    let segments: [HLSMediaSegment]
    let hasEndList: Bool
    /// Any EXT-X-KEY with METHOD != NONE anywhere in the playlist.
    let isEncrypted: Bool
    /// Any EXT-X-KEY whose METHOD is neither NONE nor AES-128 (e.g.
    /// SAMPLE-AES, SAMPLE-AES-CTR). AES-128 segments carry a per-segment
    /// `crypt` and are decrypted inline; an unsupported method still
    /// terminates the ingest so the host falls back.
    let hasUnsupportedEncryption: Bool
    /// Any EXT-X-MAP tag (fMP4-segment playlist).
    let hasMap: Bool
}

enum HLSPlaylist: Equatable {
    case master(HLSMasterPlaylist)
    case media(HLSMediaPlaylist)
}

/// Line-oriented parser for the subset of RFC 8216 the live ingest needs.
/// Pure (no I/O); the ingest reader feeds it fetched playlist text.
enum HLSPlaylistParser {

    static func parse(_ text: String) throws -> HLSPlaylist {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.first?.hasPrefix("#EXTM3U") == true else {
            throw HLSIngestError.playlistInvalid(reason: "missing #EXTM3U")
        }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            return .master(try parseMaster(lines))
        }
        return .media(try parseMedia(lines))
    }

    /// Resolve a playlist-relative URI against the playlist's own URL.
    static func resolve(uri: String, against base: URL) -> URL? {
        URL(string: uri, relativeTo: base)?.absoluteURL
    }

    // MARK: - Private

    private static func parseMaster(_ lines: [String]) throws -> HLSMasterPlaylist {
        var variants: [HLSVariant] = []
        var demuxedAudioGroups: Set<String> = []
        var audioRenditions: [HLSAudioRendition] = []
        var pendingBandwidth: Int?
        var pendingAudioGroup: String?
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingBandwidth = attribute("BANDWIDTH", in: line).flatMap(Int.init) ?? 0
                pendingAudioGroup = attribute("AUDIO", in: line)
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                // TYPE=AUDIO renditions WITH a URI carry their audio in a
                // separate playlist (demuxed); without a URI the audio is
                // in the variant stream itself.
                if attribute("TYPE", in: line) == "AUDIO",
                   let uri = attribute("URI", in: line),
                   let group = attribute("GROUP-ID", in: line) {
                    demuxedAudioGroups.insert(group)
                    audioRenditions.append(HLSAudioRendition(
                        groupID: group,
                        uri: uri,
                        isDefault: attribute("DEFAULT", in: line) == "YES"
                    ))
                }
            } else if !line.hasPrefix("#"), let bw = pendingBandwidth {
                variants.append(HLSVariant(bandwidth: bw, uri: line, audioGroupID: pendingAudioGroup))
                pendingBandwidth = nil
                pendingAudioGroup = nil
            }
        }
        guard !variants.isEmpty else {
            throw HLSIngestError.playlistInvalid(reason: "master playlist without variants")
        }
        return HLSMasterPlaylist(
            variants: variants,
            demuxedAudioGroupIDs: demuxedAudioGroups,
            audioRenditions: audioRenditions
        )
    }

    private static func parseMedia(_ lines: [String]) throws -> HLSMediaPlaylist {
        var targetDuration: Double?
        var mediaSequence = 0
        var segments: [HLSMediaSegment] = []
        var hasEndList = false
        var isEncrypted = false
        var hasUnsupportedEncryption = false
        var hasMap = false
        var pendingDuration: Double?
        var pendingDiscontinuity = false
        // Active EXT-X-KEY state. AES-128 keys are "sticky": one tag
        // governs every following segment until the next EXT-X-KEY
        // (METHOD=NONE clears it). Pluto/Samsung-TV+ also emit one tag
        // per segment with the same URI and an incrementing explicit IV.
        var currentKeyURI: String?
        var currentExplicitIV: Data?

        for line in lines {
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count))
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXTINF:") {
                let payload = line.dropFirst("#EXTINF:".count)
                pendingDuration = Double(payload.split(separator: ",").first.map(String.init) ?? "")
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY") && !line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
                pendingDiscontinuity = true
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let method = attribute("METHOD", in: line) ?? "NONE"
                switch method {
                case "NONE":
                    currentKeyURI = nil
                    currentExplicitIV = nil
                case "AES-128":
                    isEncrypted = true
                    currentKeyURI = attribute("URI", in: line)
                    currentExplicitIV = attribute("IV", in: line).flatMap(parseHexIV)
                    // A keyless AES-128 tag is unusable; treat as unsupported.
                    if currentKeyURI == nil { hasUnsupportedEncryption = true }
                default:
                    // SAMPLE-AES / SAMPLE-AES-CTR / anything else: not decryptable here.
                    isEncrypted = true
                    hasUnsupportedEncryption = true
                    currentKeyURI = nil
                    currentExplicitIV = nil
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                hasMap = true
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                hasEndList = true
            } else if !line.hasPrefix("#") {
                let crypt: HLSSegmentCrypt?
                if let keyURI = currentKeyURI {
                    // Explicit IV when the tag carried one, otherwise the
                    // segment's media-sequence number as a 16-byte
                    // big-endian value (RFC 8216 section 5.2).
                    let sequence = mediaSequence + segments.count
                    crypt = HLSSegmentCrypt(
                        keyURI: keyURI,
                        iv: currentExplicitIV ?? sequenceIV(sequence)
                    )
                } else {
                    crypt = nil
                }
                segments.append(HLSMediaSegment(
                    uri: line,
                    duration: pendingDuration ?? targetDuration ?? 0,
                    discontinuityBefore: pendingDiscontinuity,
                    crypt: crypt
                ))
                pendingDuration = nil
                pendingDiscontinuity = false
            }
        }
        guard let target = targetDuration else {
            throw HLSIngestError.playlistInvalid(reason: "missing TARGETDURATION")
        }
        guard !segments.isEmpty else {
            throw HLSIngestError.playlistInvalid(reason: "no segments")
        }
        return HLSMediaPlaylist(
            targetDuration: target,
            mediaSequence: mediaSequence,
            segments: segments,
            hasEndList: hasEndList,
            isEncrypted: isEncrypted,
            hasUnsupportedEncryption: hasUnsupportedEncryption,
            hasMap: hasMap
        )
    }

    /// Parse a `0x`-prefixed hex EXT-X-KEY IV into a 16-byte big-endian
    /// `Data`. Returns nil on a malformed length (caller falls back to
    /// the sequence-number IV).
    private static func parseHexIV(_ raw: String) -> Data? {
        var hex = raw.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
        guard hex.count == 32 else { return nil }
        var bytes = Data(capacity: 16)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        return bytes
    }

    /// 16-byte big-endian IV from a segment media-sequence number, the
    /// RFC 8216 default when an EXT-X-KEY carries no explicit IV.
    private static func sequenceIV(_ sequence: Int) -> Data {
        var iv = Data(repeating: 0, count: 16)
        var value = UInt64(bitPattern: Int64(sequence))
        for offset in 0..<8 {
            iv[15 - offset] = UInt8(value & 0xFF)
            value >>= 8
        }
        return iv
    }

    /// Extract a KEY=VALUE attribute from a tag line; tolerates quoted values.
    ///
    /// The match is anchored: the character before the key must be `:`
    /// or `,` (the attribute-list separators). A bare substring search
    /// matched `BANDWIDTH=` inside `AVERAGE-BANDWIDTH=` (which precedes
    /// it on typical `#EXT-X-STREAM-INF:` lines), so variant selection
    /// ranked streams by their AVERAGE values and could pick the wrong
    /// variant.
    private static func attribute(_ key: String, in line: String) -> String? {
        let needle = "\(key)="
        var searchStart = line.startIndex
        while let range = line.range(of: needle, range: searchStart..<line.endIndex) {
            searchStart = range.upperBound
            if range.lowerBound != line.startIndex {
                let before = line[line.index(before: range.lowerBound)]
                guard before == ":" || before == "," else { continue }
            }
            // Reject matches inside a quoted value: CODECS="a,KEY=1"
            // contains a legal comma-KEY sequence that is content, not
            // an attribute boundary. Inside-quotes == odd number of
            // quotes before the match.
            let quotesBefore = line[line.startIndex..<range.lowerBound]
                .reduce(0) { $1 == "\"" ? $0 + 1 : $0 }
            guard quotesBefore % 2 == 0 else { continue }
            let rest = line[range.upperBound...]
            if rest.hasPrefix("\"") {
                let afterQuote = rest.dropFirst()
                guard let end = afterQuote.firstIndex(of: "\"") else { return nil }
                return String(afterQuote[..<end])
            }
            let end = rest.firstIndex(of: ",") ?? rest.endIndex
            return String(rest[..<end])
        }
        return nil
    }
}
