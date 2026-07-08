import Foundation
import Testing
@testable import AetherEngine

/// #112 (ijuniorfu): after a fast-forward / audio-track switch into the middle of a PGS (Blu-ray) line,
/// the overlay showed nothing for "ten or several tens of seconds". PGS is stateful and sparse: a line's
/// composition (object def) can precede the seek target by tens of seconds, so the fixed -2 s lead-in
/// landed after it and the active line never reconstructed. The reader now scans backward in growing
/// steps until a probe decode confirms the line active at the target (`.covered`) or that the screen is
/// genuinely empty there (`.empty`, a real dialogue gap that must NOT trigger further back-scanning);
/// only when nothing is decoded at/before the target (`.notFound`) does it seek further back.
///
/// These cover the pure coverage decision: given the ordered decoded events (time + whether the event
/// carries cues vs a PGS clear), what is the screen state at `target`.
struct Issue112PGSSeekBackscanTests {

    @Test("a line whose composition precedes the target is covered")
    func activeLineIsCovered() {
        // Composition at 580 s, still up at the 585 s seek target (PGS end is open until the next composition).
        #expect(AetherEngine.evaluateBitmapSubtitleProbe(
            eventTimes: [(time: 580.0, hasCues: true)], target: 585.0) == .covered)
    }

    @Test("a clear event before the target is a genuine gap, not a miss")
    func clearedBeforeTargetIsEmpty() {
        // Line at 580, cleared at 583, target 585: the screen is empty at target. Must NOT scan further back.
        #expect(AetherEngine.evaluateBitmapSubtitleProbe(
            eventTimes: [(time: 580.0, hasCues: true), (time: 583.0, hasCues: false)],
            target: 585.0) == .empty)
    }

    @Test("the last composition at or before the target wins")
    func lastCompositionWins() {
        // Two compositions both precede the target; the later one is the active line.
        #expect(AetherEngine.evaluateBitmapSubtitleProbe(
            eventTimes: [(time: 580.0, hasCues: true), (time: 584.0, hasCues: true)],
            target: 585.0) == .covered)
        // A composition cleared then re-shown before the target: covered by the re-show.
        #expect(AetherEngine.evaluateBitmapSubtitleProbe(
            eventTimes: [(time: 580.0, hasCues: true), (time: 582.0, hasCues: false),
                         (time: 584.0, hasCues: true)],
            target: 585.0) == .covered)
    }

    @Test("nothing decoded at or before the target means seek further back")
    func nothingBeforeTargetIsNotFound() {
        // The seek landed after the active line's composition: the only event decoded starts after target.
        #expect(AetherEngine.evaluateBitmapSubtitleProbe(
            eventTimes: [(time: 590.0, hasCues: true)], target: 585.0) == .notFound)
        // No events at all in the probed window.
        #expect(AetherEngine.evaluateBitmapSubtitleProbe(
            eventTimes: [], target: 585.0) == .notFound)
    }

    @Test("events after the target never override an earlier covered/empty state")
    func eventsAfterTargetIgnored() {
        // A future composition at 588 does not change that the 580 line is active at 585.
        #expect(AetherEngine.evaluateBitmapSubtitleProbe(
            eventTimes: [(time: 580.0, hasCues: true), (time: 588.0, hasCues: true)],
            target: 585.0) == .covered)
    }

    @Test("the back-scan step sequence grows geometrically and is capped")
    func backscanDistanceSequenceIsCapped() {
        // 2, 6, 18, 54, then the cap itself (60), then stop: five probes worst case.
        #expect(AetherEngine.bitmapBackscanDistances(cap: 60.0) == [2.0, 6.0, 18.0, 54.0, 60.0])
        // A smaller cap truncates and still ends exactly on the cap.
        #expect(AetherEngine.bitmapBackscanDistances(cap: 20.0) == [2.0, 6.0, 18.0, 20.0])
    }
}
