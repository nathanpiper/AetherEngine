// Tests/AetherEngineTests/NativeSubtitleAvailabilityTests.swift
import XCTest
@testable import AetherEngine

final class NativeSubtitleAvailabilityTests: XCTestCase {
    private func textCue(_ id: Int, _ start: Double, _ end: Double, _ text: String) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: .text(text))
    }

    func test_storeWithCuesMakesRenditionAvailable_clearResets() {
        let store = NativeSubtitleCueStore()
        store.appendCues([textCue(1, 0, 1, "x")])
        XCTAssertEqual(store.cueCount, 1)
        store.clear()
        XCTAssertEqual(store.cueCount, 0)
    }

    func test_replaceCuesPopulatesStore() {
        let store = NativeSubtitleCueStore()
        store.replaceCues([textCue(1, 0, 1, "a"), textCue(2, 2, 3, "b")])
        XCTAssertEqual(store.cueCount, 2)
    }

    func test_appendCuesAccumulates() {
        let store = NativeSubtitleCueStore()
        store.appendCues([textCue(1, 0, 1, "a")])
        store.appendCues([textCue(2, 1, 2, "b")])
        XCTAssertEqual(store.cueCount, 2)
    }

    // Mirrors the engine's "available once ANY store in the set has cues,
    // reset when ALL are cleared" rule (#55, all-tracks).
    private func renditionAvailable(_ stores: [NativeSubtitleCueStore]) -> Bool {
        stores.contains { $0.cueCount > 0 }
    }

    func test_setAvailabilityFlipsWhenAnyStorePopulated_resetsOnClearAll() {
        let stores = [NativeSubtitleCueStore(), NativeSubtitleCueStore()]
        XCTAssertFalse(renditionAvailable(stores), "empty set => unavailable")

        // Populate only the second store: the set is still available.
        stores[1].appendCues([textCue(1, 0, 1, "deu")])
        XCTAssertTrue(renditionAvailable(stores), "one populated store => available")

        // Populate the first too; still available.
        stores[0].appendCues([textCue(2, 0, 1, "eng")])
        XCTAssertTrue(renditionAvailable(stores))

        // Clearing only one keeps it available (the other still has cues).
        stores[0].clear()
        XCTAssertTrue(renditionAvailable(stores), "one remaining populated store => still available")

        // Clearing ALL stores resets availability.
        stores[1].clear()
        XCTAssertFalse(renditionAvailable(stores), "all cleared => unavailable")
    }

    func test_eachStoreInSetAccumulatesIndependently() {
        let stores = [NativeSubtitleCueStore(), NativeSubtitleCueStore()]
        stores[0].appendCues([textCue(1, 0, 1, "a"), textCue(2, 1, 2, "b")])
        stores[1].appendCues([textCue(3, 0, 1, "c")])
        XCTAssertEqual(stores[0].cueCount, 2)
        XCTAssertEqual(stores[1].cueCount, 1)
    }

    func test_loadOptionsPrepareNativeSubtitleDefaultsFalse() {
        let opts = LoadOptions()
        XCTAssertFalse(opts.prepareNativeSubtitles)
    }

    func test_loadOptionsPrepareNativeSubtitleRoundTrips() {
        let opts = LoadOptions(prepareNativeSubtitles: true)
        XCTAssertTrue(opts.prepareNativeSubtitles)
    }
}
