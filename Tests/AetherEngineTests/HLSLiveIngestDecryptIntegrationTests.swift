import XCTest
@testable import AetherEngine

/// Live network integration test for AES-128 clear-key direct play.
/// Skipped unless `AETHER_LIVE_URL` is set (a real FAST-channel HLS
/// playlist, e.g. a Pluto/Samsung-TV+ stitcher URL), so CI and the
/// default `swift test` run never depend on a transient, geo-gated,
/// token-expiring upstream. Run manually:
///
///   AETHER_LIVE_URL='https://.../master.m3u8' \
///     swift test --filter HLSLiveIngestDecryptIntegrationTests
///
/// Proves the whole direct path end to end: master -> variant ->
/// encrypted media playlist -> key fetch -> AES-128-CBC segment
/// decrypt -> clear MPEG-TS bytes. A successful decrypt is observable
/// as the TS sync byte 0x47 at the 188-byte packet cadence; ciphertext
/// would be effectively random and fail the cadence check.
final class HLSLiveIngestDecryptIntegrationTests: XCTestCase {

    func testDecryptsRealAES128ChannelToCleanTS() throws {
        guard let raw = ProcessInfo.processInfo.environment["AETHER_LIVE_URL"],
              let url = URL(string: raw) else {
            throw XCTSkip("set AETHER_LIVE_URL to run the live AES-128 ingest test")
        }

        let reader = HLSLiveIngestReader(playlistURL: url)
        defer { reader.close() }

        // Pull ~64 KB on a background thread (read() blocks on the FIFO),
        // bounded by an expectation so a dead upstream fails fast. The
        // accumulator is a reference type so the closure captures the box,
        // not a mutable local (the expectation fulfill/wait pair gives the
        // happens-before edge for the main thread's read after wait).
        final class Box: @unchecked Sendable { var data = Data() }
        let want = 64 * 1024
        let box = Box()
        let done = expectation(description: "ingested bytes")
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 32 * 1024)
            while box.data.count < want {
                let n = buf.withUnsafeMutableBufferPointer {
                    reader.read($0.baseAddress, size: Int32($0.count))
                }
                if n <= 0 { break } // EOF / error / cancelled
                box.data.append(contentsOf: buf[0..<Int(n)])
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 40)
        let got = box.data

        XCTAssertNil(reader.terminalError, "ingest went terminal: \(String(describing: reader.terminalError))")
        XCTAssertGreaterThan(got.count, 188 * 4, "too few bytes to judge TS structure")

        // First byte must be the TS sync, and the sync must recur every
        // 188 bytes across the buffer: that only holds for decrypted TS.
        XCTAssertEqual(got.first, 0x47, "stream does not start with the MPEG-TS sync byte (decrypt failed?)")
        var packets = 0
        var hits = 0
        var offset = 0
        while offset + 188 <= got.count {
            packets += 1
            if got[offset] == 0x47 { hits += 1 }
            offset += 188
        }
        XCTAssertGreaterThan(packets, 8)
        // Allow a little slack for the occasional non-188 boundary, but
        // ciphertext would score near chance (1/256), not ~100%.
        XCTAssertGreaterThan(Double(hits) / Double(packets), 0.95,
                             "TS sync cadence \(hits)/\(packets) too low; segments likely still encrypted")
    }
}
