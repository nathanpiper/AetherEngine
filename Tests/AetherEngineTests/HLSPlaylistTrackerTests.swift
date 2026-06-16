import XCTest
@testable import AetherEngine

final class HLSPlaylistTrackerTests: XCTestCase {

    private func playlist(sequence: Int, uris: [String], duration: Double = 4) -> HLSMediaPlaylist {
        HLSMediaPlaylist(
            targetDuration: duration,
            mediaSequence: sequence,
            segments: uris.map { HLSMediaSegment(uri: $0, duration: duration, discontinuityBefore: false) },
            hasEndList: false,
            isEncrypted: false,
            hasUnsupportedEncryption: false,
            hasMap: false
        )
    }

    func testPrimesAtLiveEdgeWithCoverageTarget() {
        // 4s segments: coverage = max(8, 1.5 * 4) = 8s. The second segment
        // reaches it, so the join takes exactly two (previous behaviour).
        var tracker = HLSPlaylistTracker(edgeOffset: 3, minJoinCoverageSeconds: 8)
        let new = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c", "d", "e", "f"]))
        XCTAssertEqual(new.map(\.uri), ["e", "f"])
        XCTAssertEqual(tracker.stallCount, 0)
    }

    func testPrimeRespectsSegmentCountCapWhenCoverageWantsMore() {
        // Tiny 1s segments: the 8s coverage target would want 8 segments,
        // edgeOffset caps at 3.
        var tracker = HLSPlaylistTracker(edgeOffset: 3, minJoinCoverageSeconds: 8)
        let new = tracker.newSegments(in: playlist(sequence: 0, uris: ["a", "b", "c", "d", "e", "f"], duration: 1))
        XCTAssertEqual(new.map(\.uri), ["d", "e", "f"])
    }

    func testPrimeCoversUpstreamCadenceForLongSegments() {
        // 12s segments: coverage = max(8, 1.5 * 12) = 18s. One segment
        // (12s) is below it, two (24s) reach it: take exactly two, so the
        // buffer rides out a full upstream inter-batch gap.
        var tracker = HLSPlaylistTracker(edgeOffset: 3, minJoinCoverageSeconds: 8)
        let new = tracker.newSegments(in: playlist(sequence: 50, uris: ["a", "b", "c"], duration: 12))
        XCTAssertEqual(new.map(\.uri), ["b", "c"])
    }

    func testPrimeCoversBurstyTenSecondUpstream() {
        // The device-repro shape: 10s upstream segments. Coverage =
        // max(8, 1.5 * 10) = 15s -> two segments / 20s, one full upstream
        // cadence of buffer across the burst gap.
        var tracker = HLSPlaylistTracker(edgeOffset: 3, minJoinCoverageSeconds: 8)
        let new = tracker.newSegments(in: playlist(sequence: 7, uris: ["a", "b", "c", "d"], duration: 10))
        XCTAssertEqual(new.map(\.uri), ["c", "d"])
    }

    func testPrimesAtWindowStartWhenWindowIsShort() {
        var tracker = HLSPlaylistTracker(edgeOffset: 3, minJoinCoverageSeconds: 8)
        let new = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b"]))
        XCTAssertEqual(new.map(\.uri), ["a", "b"])
    }

    func testReturnsOnlyNewSegmentsOnRefresh() {
        var tracker = HLSPlaylistTracker(edgeOffset: 3, minJoinCoverageSeconds: 8)
        _ = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c"]))
        let new = tracker.newSegments(in: playlist(sequence: 101, uris: ["b", "c", "d"]))
        XCTAssertEqual(new.map(\.uri), ["d"])
    }

    func testCountsStallsAndResets() {
        var tracker = HLSPlaylistTracker(edgeOffset: 3, minJoinCoverageSeconds: 8)
        _ = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c"]))
        _ = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c"]))
        XCTAssertEqual(tracker.stallCount, 1)
        _ = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c"]))
        XCTAssertEqual(tracker.stallCount, 2)
        _ = tracker.newSegments(in: playlist(sequence: 101, uris: ["b", "c", "d"]))
        XCTAssertEqual(tracker.stallCount, 0)
    }

    func testWindowSlidePastCursorRejoinsAtEdgeWithDiscontinuity() {
        var tracker = HLSPlaylistTracker(edgeOffset: 3, minJoinCoverageSeconds: 8)
        _ = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c"]))
        // Provider window slid far past our cursor: rejoin at the edge
        // (duration-capped to two 4s segments).
        let new = tracker.newSegments(in: playlist(sequence: 500, uris: ["x", "y", "z", "w", "v", "u"]))
        XCTAssertEqual(new.map(\.uri), ["v", "u"])
        XCTAssertTrue(new[0].discontinuityBefore, "rejoin must be marked as a discontinuity")
    }
}
