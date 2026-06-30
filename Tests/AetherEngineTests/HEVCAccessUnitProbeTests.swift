import XCTest
@testable import AetherEngine

final class HEVCAccessUnitProbeTests: XCTestCase {

    /// Build one AVCC NAL (4-byte BE length prefix + 2-byte HEVC header + payload).
    private func nal(_ type: UInt8, payload: [UInt8] = [0x00]) -> [UInt8] {
        // byte0: forbidden_zero(0) | nal_unit_type(6) | nuh_layer_id MSB(0) = type << 1.
        let header: [UInt8] = [(type << 1) & 0x7E, 0x01]
        let body = header + payload
        let n = body.count
        let prefix: [UInt8] = [
            UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF),
            UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF),
        ]
        return prefix + body
    }

    func testIDRAccessUnitWithParameterSets() {
        let au = nal(32) + nal(33) + nal(34) + nal(19)  // VPS, SPS, PPS, IDR_W_RADL
        let t = HEVCAccessUnitProbe.firstSliceNALType(au)
        XCTAssertEqual(t, 19)
        XCTAssertTrue(HEVCAccessUnitProbe.isIDR(t!))
        XCTAssertTrue(HEVCAccessUnitProbe.isIRAP(t!))
        XCTAssertFalse(HEVCAccessUnitProbe.isCRA(t!))
    }

    func testCRAAccessUnitSkipsLeadingSEI() {
        let au = nal(39) + nal(21)  // SEI_PREFIX (non-VCL), CRA_NUT
        let t = HEVCAccessUnitProbe.firstSliceNALType(au)
        XCTAssertEqual(t, 21)
        XCTAssertTrue(HEVCAccessUnitProbe.isCRA(t!))
        XCTAssertTrue(HEVCAccessUnitProbe.isIRAP(t!))
        XCTAssertFalse(HEVCAccessUnitProbe.isIDR(t!))
    }

    func testRASLLeadingPictureIsNotIRAP() {
        let t = HEVCAccessUnitProbe.firstSliceNALType(nal(9))  // RASL_R
        XCTAssertEqual(t, 9)
        XCTAssertTrue(HEVCAccessUnitProbe.isRASL(t!))
        XCTAssertFalse(HEVCAccessUnitProbe.isIRAP(t!))
    }

    func testTrailingPictureIsNotIRAP() {
        let t = HEVCAccessUnitProbe.firstSliceNALType(nal(1))  // TRAIL_R
        XCTAssertEqual(t, 1)
        XCTAssertFalse(HEVCAccessUnitProbe.isIRAP(t!))
        XCTAssertFalse(HEVCAccessUnitProbe.isRASL(t!))
    }

    func testNonVCLOnlyReturnsNil() {
        let au = nal(32) + nal(33) + nal(34)  // VPS, SPS, PPS only
        XCTAssertNil(HEVCAccessUnitProbe.firstSliceNALType(au))
    }

    func testTruncatedPrefixReturnsNil() {
        XCTAssertNil(HEVCAccessUnitProbe.firstSliceNALType([0x00, 0x00, 0x10]))
    }

    func testLengthExceedingBufferStops() {
        // prefix claims 100 bytes; buffer holds 2 -> stop, nil.
        XCTAssertNil(HEVCAccessUnitProbe.firstSliceNALType([0x00, 0x00, 0x00, 0x64, 0x26, 0x01]))
    }

    func testLabels() {
        XCTAssertEqual(HEVCAccessUnitProbe.label(forSliceType: 21), "CRA")
        XCTAssertEqual(HEVCAccessUnitProbe.label(forSliceType: 19), "IDR")
        XCTAssertEqual(HEVCAccessUnitProbe.label(forSliceType: 20), "IDR")
        XCTAssertEqual(HEVCAccessUnitProbe.label(forSliceType: 9), "RASL")
        XCTAssertEqual(HEVCAccessUnitProbe.label(forSliceType: 7), "RADL")
    }
}
