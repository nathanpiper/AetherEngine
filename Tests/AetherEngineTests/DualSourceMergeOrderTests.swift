// Tests/AetherEngineTests/DualSourceMergeOrderTests.swift
//
// Verifies the pure DTS ordering behind the producer's dual-demuxer
// pull-merge (demuxed-audio HLS ingest): given the two lookahead
// packets' ordering ticks and time bases, the side (audio rendition)
// packet must be yielded exactly when its rescaled timestamp is
// strictly lower, with ties going to the main (video) packet. The
// blocking read mechanics around the decision are not testable without
// demuxers; the ordering is the part past device bugs would live in.
import XCTest
import Libavutil
@testable import AetherEngine

final class DualSourceMergeOrderTests: XCTestCase {

    private let ts90k = AVRational(num: 1, den: 90_000)

    func testInterleavesByDtsInSharedTimebase() {
        // Both renditions on the MPEG-TS 90 kHz clock, video at 25 fps
        // (3600-tick spacing), audio AAC at ~21.3 ms (1920-tick
        // spacing). Walk one second of each cadence through the
        // comparison and check the merge always picks the earlier one.
        var videoDts: Int64 = 0
        var audioDts: Int64 = 900   // intrinsic head-of-stream offset
        for _ in 0..<100 {
            let sideFirst = DualSourceMergeOrder.sideFirst(
                mainTicks: videoDts, mainTimeBase: ts90k,
                sideTicks: audioDts, sideTimeBase: ts90k
            )
            XCTAssertEqual(sideFirst, audioDts < videoDts,
                           "video=\(videoDts) audio=\(audioDts)")
            if sideFirst { audioDts += 1920 } else { videoDts += 3600 }
        }
    }

    func testUnequalCadenceDrainsTheLaggingSource() {
        // Audio packets are far denser than video: between two video
        // packets the merge must keep yielding side packets until the
        // side lookahead catches up past the main one.
        let videoDts: Int64 = 7200
        var audioDts: Int64 = 0
        var sideYields = 0
        while DualSourceMergeOrder.sideFirst(
            mainTicks: videoDts, mainTimeBase: ts90k,
            sideTicks: audioDts, sideTimeBase: ts90k
        ) {
            sideYields += 1
            audioDts += 1920
        }
        XCTAssertEqual(sideYields, 4)  // 0, 1920, 3840, 5760 < 7200
        XCTAssertEqual(audioDts, 7680)
    }

    func testRescalesAcrossDifferentTimebases() {
        // Main in 1/1000, side in 1/90000: 500 ms video vs 400 ms and
        // 600 ms audio. The comparison must happen on a common clock,
        // not on raw ticks (45000 raw ticks would dwarf 500).
        let ms = AVRational(num: 1, den: 1000)
        XCTAssertTrue(DualSourceMergeOrder.sideFirst(
            mainTicks: 500, mainTimeBase: ms,
            sideTicks: 36_000, sideTimeBase: ts90k   // 400 ms
        ))
        XCTAssertFalse(DualSourceMergeOrder.sideFirst(
            mainTicks: 500, mainTimeBase: ms,
            sideTicks: 54_000, sideTimeBase: ts90k   // 600 ms
        ))
    }

    func testTieYieldsMainFirst() {
        // Equal timestamps: video leads the interleave (segment cuts
        // key off video keyframes).
        XCTAssertFalse(DualSourceMergeOrder.sideFirst(
            mainTicks: 3600, mainTimeBase: ts90k,
            sideTicks: 3600, sideTimeBase: ts90k
        ))
    }

    func testTimestamplessPacketYieldsImmediately() {
        // Int64.min is the "no dts and no pts" key: such a packet is
        // yielded right away instead of being rescaled (the pump's
        // NOPTS repair downstream owns the actual fix-up).
        XCTAssertTrue(DualSourceMergeOrder.sideFirst(
            mainTicks: 100, mainTimeBase: ts90k,
            sideTicks: Int64.min, sideTimeBase: ts90k
        ))
        XCTAssertFalse(DualSourceMergeOrder.sideFirst(
            mainTicks: Int64.min, mainTimeBase: ts90k,
            sideTicks: 100, sideTimeBase: ts90k
        ))
    }
}
