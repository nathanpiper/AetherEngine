import XCTest
@testable import AetherEngine

final class BDTitleSelectorTests: XCTestCase {
    func test_picksLongestPlaylist() {
        let a = MPLSPlaylist(clipIDs: ["00001"], durationTicks: 100)
        let b = MPLSPlaylist(clipIDs: ["00002", "00003"], durationTicks: 9000)
        let c = MPLSPlaylist(clipIDs: ["00004"], durationTicks: 500)
        XCTAssertEqual(BDTitleSelector.selectMainTitle([a, b, c]), b)
    }

    func test_nilWhenEmpty() {
        XCTAssertNil(BDTitleSelector.selectMainTitle([]))
    }

    // MARK: - enumerateTitles (#67)

    func test_enumerateTitlesSortsLongestFirstAndDropsShort() {
        let main = MPLSPlaylist(clipIDs: ["00001", "00002"], durationTicks: 5_400_000)  // 120s
        let episode = MPLSPlaylist(clipIDs: ["00003"], durationTicks: 2_700_000)        // 60s
        let menu = MPLSPlaylist(clipIDs: ["00009"], durationTicks: 90_000)              // 2s, below 10s floor
        let titles = BDTitleSelector.enumerateTitles([episode, menu, main])
        XCTAssertEqual(titles.count, 2)                       // the 2s menu loop is dropped
        XCTAssertEqual(titles.map(\.id), [0, 1])             // ordinals assigned after sorting
        XCTAssertEqual(titles[0].durationTicks, 5_400_000)  // longest is id 0 (the main feature)
        XCTAssertEqual(titles[0].bdClipIDs, ["00001", "00002"])
        XCTAssertEqual(titles[1].durationTicks, 2_700_000)
    }

    func test_enumerateTitlesNeverEmptyWhenAllShort() {
        // If filtering would leave nothing, the unfiltered set is used (a disc with only short
        // playlists must still expose them rather than become unplayable).
        let a = MPLSPlaylist(clipIDs: ["1"], durationTicks: 100)
        let b = MPLSPlaylist(clipIDs: ["2"], durationTicks: 500)
        let titles = BDTitleSelector.enumerateTitles([a, b])
        XCTAssertEqual(titles.count, 2)
        XCTAssertEqual(titles[0].durationTicks, 500)  // still sorted longest-first
    }

    func test_enumerateTitlesEmptyInput() {
        XCTAssertTrue(BDTitleSelector.enumerateTitles([]).isEmpty)
    }

    func test_enumerateTitlesCarriesChapters() {
        let main = MPLSPlaylist(clipIDs: ["00001"], durationTicks: 5_400_000,
                                chapterStartTicks: [0, 1_350_000, 2_700_000])
        let titles = BDTitleSelector.enumerateTitles([main])
        XCTAssertEqual(titles.count, 1)
        XCTAssertEqual(titles[0].chapters.map(\.id), [0, 1, 2])           // chapter ids are 0-based ordinals
        XCTAssertEqual(titles[0].chapters.map(\.startTicks), [0, 1_350_000, 2_700_000])
        XCTAssertEqual(titles[0].titleInfo().chapterCount, 3)
    }

    // MARK: - Repeated-clip decoy demotion (AE#105)

    // Anti-rip Blu-rays (e.g. TRON: Legacy 4K) pad PLAYLIST with a decoy .mpls that references one
    // short menu/loop clip hundreds of times, inflating its declared duration to 5+ hours while the
    // demuxer only ever probes the first clip's ~76s of PTS. Duration-max selection crowned that decoy
    // as the main title, so scrubbing/snapshots past 76s landed past the demuxer's EOF and came back
    // blank. The real feature is a single-clip 2:05 title and must win.
    private func decoyPlaylist() -> MPLSPlaylist {
        MPLSPlaylist(clipIDs: ["00046"] + Array(repeating: "00038", count: 252),
                     durationTicks: 872_865_000)  // 5:23:17, but really one looped 76s clip
    }
    private func featurePlaylist() -> MPLSPlaylist {
        MPLSPlaylist(clipIDs: ["00070"], durationTicks: 337_860_000)  // 2:05:08, a single real clip
    }

    func test_selectMainTitleIgnoresRepeatedClipDecoy() {
        XCTAssertEqual(BDTitleSelector.selectMainTitle([decoyPlaylist(), featurePlaylist()]),
                       featurePlaylist())
    }

    func test_enumerateTitlesDemotesRepeatedClipDecoy() {
        let titles = BDTitleSelector.enumerateTitles([decoyPlaylist(), featurePlaylist()])
        XCTAssertEqual(titles.first?.bdClipIDs, ["00070"])          // real feature is the main title (id 0)
        XCTAssertFalse(titles.contains { $0.bdClipIDs == decoyPlaylist().clipIDs })  // decoy dropped entirely
    }

    func test_enumerateTitlesKeepsDecoyWhenItIsTheOnlyPlaylist() {
        // Never leave a disc with zero titles: if every playlist is a decoy, expose them anyway.
        let titles = BDTitleSelector.enumerateTitles([decoyPlaylist()])
        XCTAssertEqual(titles.count, 1)
    }

    func test_isRepeatedClipDecoyToleratesLightClipReuse() {
        // Seamless-branching / multi-angle titles legitimately reuse a clip a couple of times. A clip
        // that appears twice in a four-clip title is NOT a decoy; only a single clip dominating the
        // PlayItem list is.
        let branching = MPLSPlaylist(clipIDs: ["A", "B", "A", "C"], durationTicks: 5_400_000)
        XCTAssertFalse(BDTitleSelector.isRepeatedClipDecoy(branching))
        XCTAssertTrue(BDTitleSelector.isRepeatedClipDecoy(decoyPlaylist()))
    }
}
