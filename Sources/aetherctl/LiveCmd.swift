import Foundation
import AetherEngine

// MARK: - high-bitrate seed generation

/// Ensure a high-bitrate (~22 Mbps) 1080p H.264 MPEG-TS seed exists at
/// `path`, generating it with ffmpeg if absent. A realistic ~20+ Mbps video
/// bitrate is what makes AVPlayer's retain-everything memory behaviour show
/// up clearly in resident_size over a multi-minute run; the prior ~0.5 MB/s
/// synthetic seed was far too small to reproduce it. H.264 routes through the
/// NATIVE AVPlayer path, which is exactly what we want to stress for the
/// B4-gating retention question. Returns true if the seed exists (or was
/// generated) and looks like a non-trivial TS file; false on any failure.
func ensureHighBitrateSeed(path: String) -> Bool {
    let fm = FileManager.default
    if fm.fileExists(atPath: path) {
        let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        // A real ~22 Mbps x 10 s clip is ~25 MB; anything tiny is suspect.
        if size > 5_000_000 {
            print("high-bitrate seed present: \(path) (\(size) bytes, \(String(format: "%.1f", Double(size) / 1_048_576.0)) MB)")
            return true
        }
        print("high-bitrate seed at \(path) is only \(size) bytes; regenerating")
    }

    // Resolve an ffmpeg binary. Homebrew install path first, then PATH.
    let ffmpegCandidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
    guard let ffmpeg = ffmpegCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
        print("ERROR: ffmpeg not found on \(ffmpegCandidates). Install it (brew install ffmpeg) to generate the high-bitrate seed.")
        return false
    }

    // Ensure the parent directory exists.
    let dir = (path as NSString).deletingLastPathComponent
    if !dir.isEmpty {
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    print("generating high-bitrate seed via ffmpeg (\(ffmpeg)) -> \(path) ...")

    // The seed is a CHEAP intro spliced in front of a HIGH-BITRATE body, both
    // 1080p H.264 with a matching 5 s closed GOP (-g 150 at 30 fps). Why the
    // two-stage shape:
    //
    //  - The live producer cuts a segment at the first keyframe >= its ~4 s
    //    target, so a 5 s GOP yields clean 5 s segments and the served playlist
    //    advertises an EXT-X-TARGETDURATION that matches them.
    //  - At startup the producer's FIRST segment must be demuxed + remuxed +
    //    published before AVPlayer's initial-buffering stall timer fires (the
    //    manifest is empty / target=1 until then; AVPlayer demands an update
    //    within 1.5 * target = ~1.5 s). A high-bitrate first segment is ~12-14 MB
    //    and its remux exceeds that window on the loopback path, so AVPlayer
    //    dies with CoreMedia -12888 ("Playlist File unchanged...") at the very
    //    first frame, every time. A ~1.5 Mbps, 6 s intro makes seg-0 small
    //    enough to publish well within the window, AVPlayer starts, and the
    //    producer then races into the 22 Mbps body (it reads far faster than 1x
    //    once AVPlayer is healthy and pulling).
    //  - The 22 Mbps, 24 s body is the part that stresses AVPlayer retention:
    //    firmly high-bitrate (~44x the old ~0.5 MB/s synthetic seed), so a
    //    93%-retain leak over a multi-minute unpaced run is unmistakable in
    //    resident_size. H.264 routes through the NATIVE AVPlayer path.
    //
    // The two TS files are byte-concatenated (raw MPEG-TS is concatenable; the
    // demuxer absorbs the splice). LiveFixture loops the whole seed, so the
    // cheap intro recurs once per ~30 s loop, which is harmless.
    let tmp = NSTemporaryDirectory()
    let introPath = (tmp as NSString).appendingPathComponent("aetherctl-seed-intro.ts")
    let bodyPath  = (tmp as NSString).appendingPathComponent("aetherctl-seed-body.ts")

    func runFFmpeg(_ args: [String], label: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch {
            print("ERROR: failed to launch ffmpeg (\(label)): \(error.localizedDescription)")
            return false
        }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            print("ERROR: ffmpeg (\(label)) exited \(proc.terminationStatus). Output tail:")
            if let text = String(data: out, encoding: .utf8) { print(String(text.suffix(2000))) }
            return false
        }
        return true
    }

    let introArgs = [
        "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30:duration=6",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=6",
        "-c:v", "libx264", "-b:v", "1500k", "-maxrate", "1500k", "-bufsize", "3M",
        "-g", "150", "-keyint_min", "150", "-sc_threshold", "0",
        "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k",
        "-muxrate", "2M", "-f", "mpegts", introPath, "-y"
    ]
    let bodyArgs = [
        "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30:duration=24",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=24",
        "-c:v", "libx264", "-b:v", "22M", "-maxrate", "22M", "-bufsize", "44M",
        "-g", "150", "-keyint_min", "150", "-sc_threshold", "0",
        "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k",
        "-muxrate", "24M", "-f", "mpegts", bodyPath, "-y"
    ]
    guard runFFmpeg(introArgs, label: "intro"), runFFmpeg(bodyArgs, label: "body") else {
        return false
    }

    // Byte-concatenate intro + body into the seed.
    guard let introData = try? Data(contentsOf: URL(fileURLWithPath: introPath)),
          let bodyData  = try? Data(contentsOf: URL(fileURLWithPath: bodyPath)) else {
        print("ERROR: could not read generated intro/body TS files")
        return false
    }
    var combined = introData
    combined.append(bodyData)
    do {
        try combined.write(to: URL(fileURLWithPath: path))
    } catch {
        print("ERROR: could not write combined seed to \(path): \(error.localizedDescription)")
        return false
    }
    try? fm.removeItem(atPath: introPath)
    try? fm.removeItem(atPath: bodyPath)

    let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
    guard size > 5_000_000 else {
        print("ERROR: generated seed at \(path) is only \(size) bytes; ffmpeg may have failed silently.")
        return false
    }
    print("generated high-bitrate seed: \(path) (\(size) bytes, \(String(format: "%.1f", Double(size) / 1_048_576.0)) MB; ~1.5 Mbps 6 s intro + 22 Mbps 24 s body)")
    return true
}

// MARK: - live

/// Start a `LiveFixture` (endless MPEG-TS over loopback), load it into a
/// fresh engine with `LoadOptions(isLive: true)`, play for `playSeconds`,
/// and verdict on whether the live path advanced the clock.
///
/// `dvrWindow` (from `--dvr-window`) is threaded into
/// `LoadOptions.dvrWindowSeconds`. `nil` means live-only: the live window is
/// still bounded by `LiveWindowSizing.liveOnlyFloorSeconds`.
func runLive(
    seconds playSeconds: Double,
    seed seedPath: String?,
    dvrWindow: Double?,
    serveOnly: Bool,
    measureRSS: Bool,
    reportCacheBytes: Bool,
    rewindTest: Bool = false,
    forceSoftware: Bool = false,
    dropAfter: Double? = nil,
    discontinuityAt: Double? = nil,
    realtime: Bool = false
) -> Int32 {
    EngineLog.handler = { print($0) }

    // TEST-ONLY: force the live source through SoftwarePlaybackHost so the
    // H.264 fixture exercises the SW live + DVR path. Cleared on the way
    // out so it never bleeds into a subsequent invocation in-process.
    AetherEngine.setForceSoftwarePathForTesting(forceSoftware)
    if forceSoftware {
        print("aetherctl live: --sw set, forcing SoftwarePlaybackHost routing")
    }
    defer { AetherEngine.setForceSoftwarePathForTesting(false) }

    // Resolve the seed relative to the repo root (CWD under `swift run`).
    let resolvedSeed = seedPath ?? "Fixtures/user/h264-ts-sample.ts"
    print("aetherctl live: seed=\(resolvedSeed) seconds=\(playSeconds)" +
          (dvrWindow.map { " dvr-window=\($0)" } ?? " dvr-window=none (live-only floor)") +
          (dropAfter.map { " drop-after=\($0)s" } ?? "") +
          (discontinuityAt.map { " discontinuity-at=\($0)s" } ?? "") +
          (measureRSS ? " measure-rss=true" : "") +
          (reportCacheBytes ? " report-cache-bytes=true" : ""))

    let fixture: LiveFixture
    do {
        fixture = try LiveFixture(seedPath: resolvedSeed)
    } catch {
        print("ERROR: \(error)")
        return 1
    }
    fixture.dropAfterSeconds = dropAfter
    fixture.discontinuityAfterSeconds = discontinuityAt
    fixture.paced = realtime
    if realtime {
        print("aetherctl live: --realtime set, pacing fixture output at ~1x")
    }

    let liveURL: URL
    do {
        liveURL = try fixture.start()
    } catch {
        print("ERROR: \(error)")
        return 1
    }
    print("=== LIVE URL ===")
    print(liveURL.absoluteString)
    print("================")

    // Diagnostic: park the fixture so curl / ffprobe can inspect the
    // served endless stream directly, without the engine attached. Used
    // to validate the fixture's TS rewrite in isolation.
    //
    //   curl -s http://127.0.0.1:<port>/live.ts | head -c 3000000 > /tmp/x.ts
    //   ffprobe -v error -show_entries packet=pts -of csv /tmp/x.ts
    if serveOnly {
        print("Fixture parked (--serve-only). Ctrl-C to stop.")
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler {
            fixture.stop()
            exit(0)
        }
        src.resume()
        RunLoop.main.run()
        return 0 // unreachable
    }

    let box = UncheckedBox<Int32?>(nil)
    Task { @MainActor in
        if rewindTest {
            box.value = await liveRewindTest(url: liveURL, seconds: playSeconds,
                                             dvrWindow: dvrWindow ?? 60)
            fixture.stop()
            CFRunLoopStop(CFRunLoopGetMain())
            return
        }
        box.value = await liveSmokeTest(url: liveURL, seconds: playSeconds,
                                        dvrWindow: dvrWindow, measureRSS: measureRSS,
                                        reportCacheBytes: reportCacheBytes,
                                        checkMonotonic: discontinuityAt != nil)
        fixture.stop()
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
}

@MainActor
private func liveSmokeTest(url: URL, seconds playSeconds: Double,
                           dvrWindow: Double? = nil,
                           measureRSS: Bool = false,
                           reportCacheBytes: Bool = false,
                           checkMonotonic: Bool = false) async -> Int32 {
    let engine: AetherEngine
    do {
        engine = try AetherEngine()
    } catch {
        print("VERDICT: live FAIL: engine init error: \(error.localizedDescription)")
        return 1
    }

    var options = LoadOptions(isLive: true)
    options.suppressDisplayCriteria = true
    options.dvrWindowSeconds = dvrWindow

    do {
        try await engine.load(url: url, options: options)
    } catch {
        // The native HLS path (H.264 / HEVC) currently requires a finite
        // duration to build its segment plan, so an unbounded live source
        // throws `zeroDuration` here. That unbounded-duration segment
        // producer is what the later plan tasks add; this harness reaching
        // a load failure on the fixture is the expected pre-feature state,
        // not a fixture defect (the fixture serves a valid, continuous TS,
        // verifiable with `aetherctl live --serve-only` + ffprobe).
        print("VERDICT: live FAIL: load error: \(error.localizedDescription)")
        engine.stop()
        return 1
    }

    print(String(format: "  post-load state=%@ isLive=%@ t=%.2fs",
                 "\(engine.state)", "\(engine.isLive)", engine.currentTime))

    if measureRSS {
        print("RSS_HEADER: elapsed_s  phys_footprint_mb  resident_mb")
    }
    if reportCacheBytes {
        print("CACHE_HEADER: elapsed_s  disk_bytes  disk_mb")
        // Emit an initial sample at t=0 so the plateau has a baseline.
        let b0 = engine.segmentCacheDiskBytes ?? 0
        print(String(format: "CACHE_BYTES: elapsed=0s  disk=%lld B  disk=%.2f MB",
                     b0, Double(b0) / 1_048_576.0))
    }

    let startTime = Date()
    var lastRSSTick: Double = 0
    var lastCacheTick: Double = 0

    // Monotonicity tracking for the discontinuity test. The session
    // timeline (currentTime on SW, and the live edge on both paths) must
    // never jump backward and must never leap forward by the raw PTS delta
    // (1000 s). We watch both per-tick maxima and the largest single-tick
    // forward step; a leap >> the playhead-vs-realtime over-run would be the
    // failure signature of an unhandled discontinuity.
    var monotonicViolation = false
    var maxForwardStep: Double = 0
    var prevCurrentTime = engine.currentTime
    var prevEdgeTime = engine.liveEdgeTime
    // The fixture races well ahead of wall clock, so a single 1 s tick can
    // legitimately advance the timeline by several seconds. A genuine
    // unhandled +1000 s discontinuity dwarfs that; 100 s is a safe ceiling
    // that no normal over-run reaches but any raw-PTS leap exceeds.
    let leapCeiling: Double = 100.0

    let ticks = max(1, Int(playSeconds))
    for tick in 0..<ticks {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let elapsed = Date().timeIntervalSince(startTime)
        if checkMonotonic {
            let ct = engine.currentTime
            let et = engine.liveEdgeTime
            // Backward jump on either axis is a hard violation.
            if ct + 0.5 < prevCurrentTime || et + 0.5 < prevEdgeTime {
                monotonicViolation = true
                print(String(format: "  MONOTONIC VIOLATION (backward): "
                             + "currentTime %.2f->%.2f edge %.2f->%.2f",
                             prevCurrentTime, ct, prevEdgeTime, et))
            }
            // Forward leap by ~the raw PTS delta is the unhandled-jump
            // signature.
            let ctStep = ct - prevCurrentTime
            let etStep = et - prevEdgeTime
            maxForwardStep = max(maxForwardStep, max(ctStep, etStep))
            if ctStep > leapCeiling || etStep > leapCeiling {
                monotonicViolation = true
                print(String(format: "  MONOTONIC VIOLATION (raw-PTS leap): "
                             + "currentTime step=%.2f edge step=%.2f",
                             ctStep, etStep))
            }
            prevCurrentTime = ct
            prevEdgeTime = et
        }
        print(String(format: "  state=%@ isLive=%@ t=%.2fs edge=%.2fs",
                     "\(engine.state)", "\(engine.isLive)", engine.currentTime, engine.liveEdgeTime))
        // Print RSS sample every 30 s when --measure-rss is set.
        if measureRSS && (elapsed - lastRSSTick >= 30.0 || tick == ticks - 1) {
            let phys = physFootprintBytes()
            let res  = residentBytes()
            let physMB = phys >= 0 ? Double(phys) / 1_048_576.0 : -1
            let resMB  = res  >= 0 ? Double(res)  / 1_048_576.0 : -1
            print(String(format: "RSS_SAMPLE: elapsed=%.0fs  phys=%.1fMB  resident=%.1fMB",
                         elapsed, physMB, resMB))
            lastRSSTick = elapsed
        }
        // Print the cache disk footprint every 60 s when
        // --report-cache-bytes is set (plus a final sample at the end of
        // the run so a short run still shows the plateau).
        if reportCacheBytes && (elapsed - lastCacheTick >= 60.0 || tick == ticks - 1) {
            let bytes = engine.segmentCacheDiskBytes ?? 0
            print(String(format: "CACHE_BYTES: elapsed=%.0fs  disk=%lld B  disk=%.2f MB",
                         elapsed, bytes, Double(bytes) / 1_048_576.0))
            lastCacheTick = elapsed
        }
    }

    let finalState = engine.state
    let finalIsLive = engine.isLive
    let finalTime = engine.currentTime
    let finalEdge = engine.liveEdgeTime
    engine.stop()

    // Scale the "advanced past 15s" bar to the play window: a 20 s run
    // should clear ~15 s, a shorter run scales proportionally (minus a
    // small warm-up allowance for first-segment latency).
    let advanceTarget = playSeconds >= 20 ? 15.0 : max(1.0, playSeconds * 0.6)

    let playing: Bool
    if case .playing = finalState { playing = true } else { playing = false }

    // "Has the session advanced" is judged on currentTime when it ticks
    // (native AVPlayer, and the SW path once its audio clock runs), else on
    // the live edge (the SW video-only fixture advances the edge from video
    // PTS while the audio-driven currentTime stays at 0). Either crossing the
    // bar proves continued playback past the discontinuity point.
    let advanced = max(finalTime, finalEdge)

    if checkMonotonic && monotonicViolation {
        print(String(format: "VERDICT: live FAIL (monotonic violation across "
                     + "discontinuity; maxForwardStep=%.2fs, t=%.2fs, edge=%.2fs)",
                     maxForwardStep, finalTime, finalEdge))
        return 1
    }

    if finalIsLive, playing, advanced >= advanceTarget {
        let mono = checkMonotonic
            ? String(format: " monotonic OK maxStep=%.2fs", maxForwardStep)
            : ""
        print(String(format: "VERDICT: live playing (isLive=%@, state=%@, t=%.2fs, edge=%.2fs >= %.2fs)%@",
                     "\(finalIsLive)", "\(finalState)", finalTime, finalEdge, advanceTarget, mono))
        return 0
    }
    print(String(format: "VERDICT: live FAIL (isLive=%@, state=%@, t=%.2fs, edge=%.2fs, needed >=%.2fs)",
                 "\(finalIsLive)", "\(finalState)", finalTime, finalEdge, advanceTarget))
    return 1
}

/// DVR rewind test: play ~40s with a DVR window, rewind 20s off the live edge,
/// assert the playhead moved back and `behindLiveSeconds` is roughly 20, then
/// return to the live edge and assert `isAtLiveEdge`. Prints PASS/FAIL per
/// step and `VERDICT: native DVR rewind+return OK` only when both pass.
@MainActor
private func liveRewindTest(url: URL, seconds playSeconds: Double,
                            dvrWindow: Double) async -> Int32 {
    let engine: AetherEngine
    do {
        engine = try AetherEngine()
    } catch {
        print("VERDICT: live FAIL: engine init error: \(error.localizedDescription)")
        return 1
    }

    var options = LoadOptions(isLive: true)
    options.suppressDisplayCriteria = true
    options.dvrWindowSeconds = dvrWindow

    do {
        try await engine.load(url: url, options: options)
    } catch {
        print("VERDICT: live FAIL: load error: \(error.localizedDescription)")
        engine.stop()
        return 1
    }
    print(String(format: "  post-load state=%@ isLive=%@ dvrWindow=%.0fs t=%.2fs",
                 "\(engine.state)", "\(engine.isLive)", dvrWindow, engine.currentTime))

    // Warm up for ~40s so the DVR window has enough history to rewind into.
    // Sample behindLiveSeconds every ~4s during this NORMAL playback phase and
    // collect the series: on a 1x (--realtime) feed it should stay roughly
    // stable and small, not the continuously-growing ~30-40s racing-ahead
    // artifact a fast (unpaced) fixture produces.
    let warmup = max(playSeconds, 40.0)
    var normalBehindSamples: [Double] = []
    print("  NORMAL_PLAYBACK behindLiveSeconds series (every ~4s, 1x feed):")
    for i in 0..<Int(warmup) {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if i % 4 == 0 || i == Int(warmup) - 1 {
            let b = engine.behindLiveSeconds
            normalBehindSamples.append(b)
            print(String(format: "    +%2ds  t=%.2f  edge=%.2f  behind=%.2f",
                         i + 1, engine.currentTime, engine.liveEdgeTime, b))
        }
    }
    // Stability of the normal-playback behind series: max - min over the
    // samples taken after a short settle (skip the first sample, which can be
    // mid warm-up). A 1x feed holds behind in a narrow band; a racing feed
    // ramps it monotonically.
    let settled = normalBehindSamples.count > 1 ? Array(normalBehindSamples.dropFirst()) : normalBehindSamples
    let normalMin = settled.min() ?? 0
    let normalMax = settled.max() ?? 0
    let normalSpread = normalMax - normalMin
    print(String(format: "  NORMAL_PLAYBACK behind: min=%.2f max=%.2f spread=%.2f (stable if spread small and max not ~30-40)",
                 normalMin, normalMax, normalSpread))
    print(String(format: "  pre-rewind edge=%.2fs t=%.2fs behind=%.2fs range=%@",
                 engine.liveEdgeTime, engine.currentTime, engine.behindLiveSeconds,
                 engine.seekableLiveRange.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "nil"))

    // --- Rewind 20s off the live edge ---
    // Note: comparing absolute currentTime before vs after the seek is the
    // wrong invariant for a live stream (the playhead keeps advancing and the
    // edge lurches forward in discrete steps as new segments publish). The
    // correct post-seek invariant is: the playhead sits ~20s behind the edge,
    // i.e. behindLiveSeconds settles near 20, and the playhead is below where
    // it would be at the edge. Sample on each of the next ~5s and take the
    // settled minimum behind, which is robust against an edge lurch landing on
    // the final sample.
    let edgeBefore = engine.liveEdgeTime
    let timeBefore = engine.currentTime
    await engine.seek(to: edgeBefore - 20)
    var behindSamples: [Double] = []
    var timeAfter = engine.currentTime
    for i in 0..<5 {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        timeAfter = engine.currentTime
        let b = engine.behindLiveSeconds
        behindSamples.append(b)
        print(String(format: "    +%ds t=%.2f edge=%.2f behind=%.2f", i + 1,
                     timeAfter, engine.liveEdgeTime, b))
    }
    // The settled behind right after the seek (before any edge lurch) is the
    // minimum of the early samples; that is the true rewind depth.
    let behindAfter = behindSamples.min() ?? engine.behindLiveSeconds
    // Playhead moved back relative to the live edge it was rewound from.
    let movedBack = timeAfter < edgeBefore
    let behindOK = abs(behindAfter - 20) <= 5
    let rewindPass = movedBack && behindOK
    print(String(format: "  REWIND: edgeBefore=%.2f tBefore=%.2f -> tAfter=%.2f settledBehind=%.2f (belowEdge=%@, behind~20=%@)",
                 edgeBefore, timeBefore, timeAfter, behindAfter,
                 "\(movedBack)", "\(behindOK)"))
    print("  REWIND: \(rewindPass ? "PASS" : "FAIL")")

    // --- Return to the live edge ---
    await engine.seekToLiveEdge()
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    let atEdge = engine.isAtLiveEdge
    print(String(format: "  RETURN: behind=%.2fs isAtLiveEdge=%@",
                 engine.behindLiveSeconds, "\(atEdge)"))
    print("  RETURN: \(atEdge ? "PASS" : "FAIL")")

    engine.stop()

    // Normal-playback stability gate: on a 1x feed the behind series should sit
    // in a narrow band well below the racing-ahead ~30-40s artifact. Generous
    // bound: spread <= 15s and max < 30s. Informational, but folded into the
    // PASS/FAIL so the "behind is stable at 1x" claim is checked, not asserted.
    let normalStable = normalSpread <= 15.0 && normalMax < 30.0
    print(String(format: "  NORMAL_STABLE: %@ (spread=%.2f max=%.2f)",
                 normalStable ? "PASS" : "FAIL", normalSpread, normalMax))

    if rewindPass && atEdge && normalStable {
        print("VERDICT: native DVR rewind+return OK; behind stable at 1x")
        return 0
    }
    print(String(format: "VERDICT: native DVR rewind+return FAIL (rewind=%@ return=%@ normalStable=%@)",
                 "\(rewindPass)", "\(atEdge)", "\(normalStable)"))
    return 1
}
