// Tests/AetherEngineTests/LiveReloadPolicyTests.swift
//
// Pins the reload positioning policy that fixes the live-reload stall
// (audio-switch reload of a live session left AVPlayer in waitingToPlay
// forever): live reloads must never resume at a stale clock and must
// skip the host's explicit initial seek, while VOD reloads keep the
// resume-at-playhead behavior and initial live joins keep the verified
// seek-to-0. The policy is a pure decision (LiveReloadPolicy) precisely
// so these rules are testable without a pipeline.
import XCTest
@testable import AetherEngine

final class LiveReloadPolicyTests: XCTestCase {

    // MARK: - resumePosition

    func testVODReloadResumesAtPlayhead() {
        XCTAssertEqual(
            LiveReloadPolicy.resumePosition(isLive: false, currentTime: 25.4), 25.4,
            "a VOD audio switch must not lose the user's position"
        )
    }

    func testVODReloadNearHeadCollapsesToNil() {
        // Positions <= 1 s collapse to nil so a switch at the head
        // doesn't pay a pointless seek (matches the historical
        // `resumeAt > 1` guard).
        XCTAssertNil(LiveReloadPolicy.resumePosition(isLive: false, currentTime: 0.0))
        XCTAssertNil(LiveReloadPolicy.resumePosition(isLive: false, currentTime: 1.0))
        XCTAssertNotNil(LiveReloadPolicy.resumePosition(isLive: false, currentTime: 1.01))
    }

    func testLiveReloadNeverResumesAtStaleClock() {
        // The core of the live-reload policy: the pre-reload playhead is
        // a stale clock against the rebuilt session's fresh timeline.
        // Whatever the playhead was, a live reload must come back nil.
        for playhead in [0.0, 0.5, 25.4, 3600.0] {
            XCTAssertNil(
                LiveReloadPolicy.resumePosition(isLive: true, currentTime: playhead),
                "live reload must rejoin the live edge, not resume at \(playhead)s"
            )
        }
    }

    // MARK: - skipInitialSeek

    func testLiveRejoinSkipsTheHostSeek() {
        XCTAssertTrue(
            LiveReloadPolicy.skipInitialSeek(isLive: true, isRejoin: true),
            "a live REJOIN must leave the join position to AVPlayer (the rebuilt "
            + "playlist can present a backlog where seek-to-0 points a window "
            + "behind the live edge and wedges item readiness)"
        )
    }

    func testInitialLiveJoinKeepsTheSeek() {
        XCTAssertFalse(
            LiveReloadPolicy.skipInitialSeek(isLive: true, isRejoin: false),
            "the initial live join's seek-to-0 is device-verified behavior "
            + "(seg0 IS the cushioned live edge at the first manifest); the "
            + "rejoin policy must not change it"
        )
    }

    func testVODNeverSkipsTheSeek() {
        // VOD relies on the explicit seek for replay-from-beginning,
        // rejoin or not.
        XCTAssertFalse(LiveReloadPolicy.skipInitialSeek(isLive: false, isRejoin: false))
        XCTAssertFalse(LiveReloadPolicy.skipInitialSeek(isLive: false, isRejoin: true))
    }

    // MARK: - LoadOptions plumbing

    func testHostsCannotSetLiveRejoin() {
        // The rejoin marker is engine-internal: every publicly
        // constructible LoadOptions carries false, so no host load can
        // accidentally opt a FRESH join out of the verified seek-to-0.
        XCTAssertFalse(LoadOptions().isLiveRejoin)
        XCTAssertFalse(LoadOptions(isLive: true, dvrWindowSeconds: 600).isLiveRejoin)
    }
}
