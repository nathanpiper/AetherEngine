// Tests/AetherEngineTests/LivePlaylistRefreshTests.swift
//
// Invariants of the live media playlist across refresh-generation
// bumps, pinned because the live-reload stall investigation showed the
// reload join consuming exactly this shape: a playlist regenerated from
// seg0 whose EXT-X-SODALITE-REFRESH counter had advanced several
// generations while the producer raced through a re-served backlog.
// The playlist itself must stay spec-valid and byte-distinguishable
// across consecutive builds regardless of how fast segments append:
//
//   - no #EXT-X-ENDLIST and no #EXT-X-PLAYLIST-TYPE (a sliding live
//     playlist per RFC 8216 §4.3.3.5),
//   - #EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES advertised (URL live
//     sources honor blocking reload),
//   - #EXT-X-MEDIA-SEQUENCE equals the snapshot's firstVisible,
//   - exactly one #EXTINF + URI pair per visible segment,
//   - the refresh counter makes two consecutive builds differ even
//     when no segment was appended in between (the anti--12888 line).
import XCTest
@testable import AetherEngine

/// Live provider with a hand-controlled snapshot, so the test drives
/// the exact sequence of (count, firstVisible, refreshCounter) the
/// playlist builder sees across builds. Only members the media-playlist
/// builder reads are meaningful; the rest take protocol defaults.
private final class ScriptedLiveProvider: HLSSegmentProvider, @unchecked Sendable {
    var count: Int
    var firstVisible: Int = 0
    var refresh: Int = 0

    init(count: Int) { self.count = count }

    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { count }
    func segmentDuration(at index: Int) -> Double { 4.0 }
    var playlistType: HLSPlaylistType { .live }
    var liveTargetSegmentDuration: Double? { 4.0 }

    func notePlaylistBuild() -> (visibleCount: Int, firstVisible: Int, refreshCounter: Int, endlistAdded: Bool, discontinuitySequence: Int) {
        refresh += 1
        return (count, firstVisible, refresh, false, 0)
    }
}

final class LivePlaylistRefreshTests: XCTestCase {

    private func lines(_ playlist: String) -> [String] {
        playlist.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// The reload join shape from the device repro: a playlist
    /// regenerated from seg0 with a 20-segment backlog (window has not
    /// slid). It must list every segment from 0, stay open-ended, and
    /// keep the blocking-reload contract.
    func testBacklogJoinShapeIsValidAndComplete() {
        let provider = ScriptedLiveProvider(count: 20)
        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        let ls = lines(playlist)

        XCTAssertTrue(ls.contains("#EXT-X-MEDIA-SEQUENCE:0"))
        XCTAssertTrue(ls.contains("#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES"))
        XCTAssertFalse(ls.contains("#EXT-X-ENDLIST"),
                       "a live playlist must stay open so AVPlayer keeps polling")
        XCTAssertFalse(ls.contains(where: { $0.hasPrefix("#EXT-X-PLAYLIST-TYPE") }),
                       "sliding live playlists carry no PLAYLIST-TYPE tag")
        XCTAssertEqual(ls.filter { $0.hasPrefix("#EXTINF:") }.count, 20)
        XCTAssertEqual(ls.first(where: { $0.hasPrefix("seg") }), "seg0.mp4")
        XCTAssertTrue(ls.contains("seg19.mp4"))
    }

    /// Two consecutive builds with NO new segment must still differ at
    /// the byte level (the refresh counter line), so AVPlayer's
    /// "Playlist File unchanged" (-12888) check never trips during a
    /// quiet window.
    func testConsecutiveBuildsDifferViaRefreshCounter() {
        let provider = ScriptedLiveProvider(count: 3)
        let first = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        let second = HLSLocalServer.buildMediaPlaylistText(provider: provider)

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(lines(first).contains("#EXT-X-SODALITE-REFRESH:1"))
        XCTAssertTrue(lines(second).contains("#EXT-X-SODALITE-REFRESH:2"))

        // And the refresh line is the ONLY difference for an unchanged
        // window: stripping it makes the builds identical, proving the
        // counter cannot disturb segment listing or tags.
        func stripped(_ s: String) -> [String] {
            lines(s).filter { !$0.hasPrefix("#EXT-X-SODALITE-REFRESH:") }
        }
        XCTAssertEqual(stripped(first), stripped(second))
    }

    /// A refresh-generation bump across appended segments (the reload's
    /// racing producer) keeps MEDIA-SEQUENCE anchored to firstVisible
    /// and extends the listing at the tail only.
    func testAppendAcrossRefreshBumpKeepsSequenceAnchored() {
        let provider = ScriptedLiveProvider(count: 2)
        let first = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        XCTAssertEqual(lines(first).filter { $0.hasPrefix("#EXTINF:") }.count, 2)

        // Producer races: 18 more segments before the next fetch.
        provider.count = 20
        let second = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        let ls = lines(second)
        XCTAssertTrue(ls.contains("#EXT-X-MEDIA-SEQUENCE:0"),
                      "no window slide happened, so the sequence must stay 0")
        XCTAssertEqual(ls.filter { $0.hasPrefix("#EXTINF:") }.count, 20)

        // Window slide (firstVisible advances): MEDIA-SEQUENCE follows
        // and segments below it disappear from the listing.
        provider.firstVisible = 5
        let third = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        let ls3 = lines(third)
        XCTAssertTrue(ls3.contains("#EXT-X-MEDIA-SEQUENCE:5"))
        XCTAssertFalse(ls3.contains("seg4.mp4"))
        XCTAssertEqual(ls3.first(where: { $0.hasPrefix("seg") }), "seg5.mp4")
        XCTAssertEqual(ls3.filter { $0.hasPrefix("#EXTINF:") }.count, 15)
    }
}
