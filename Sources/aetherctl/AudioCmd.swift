import Foundation
import AetherEngine

// MARK: - audio

/// Load a source through the engine's audio-only path and play it,
/// printing the synchronizer clock once a second. Confirms FFmpeg
/// decode -> AVSampleBufferAudioRenderer works end-to-end on macOS.
func runAudio(url: URL, seconds playSeconds: Double) -> Int32 {
    print("aetherctl audio: \(url.absoluteString) (play \(playSeconds)s)")
    // AetherEngine is @MainActor, so it must be driven on the main thread
    // under a live run loop, NOT through the main-thread-blocking
    // `runBlocking` semaphore: that would deadlock the instant the engine
    // needs the main actor (the main thread would be parked on the
    // semaphore and could never service the MainActor executor). Running
    // CFRunLoopRun keeps the main actor executor AND the
    // Timer.publish(on: .main) clock mirror alive while the @MainActor
    // task drives playback, then the task stops the run loop when done.
    let box = UncheckedBox<Int32?>(nil)
    Task { @MainActor in
        box.value = await audioSmokeTest(url: url, seconds: playSeconds)
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
}

@MainActor
private func audioSmokeTest(url: URL, seconds playSeconds: Double) async -> Int32 {
    let engine: AetherEngine
    do {
        engine = try AetherEngine()
    } catch {
        print("engine init failed: \(error.localizedDescription)")
        return 1
    }
    do {
        try await engine.load(url: url, options: LoadOptions(audioOnly: true))
    } catch {
        print("load failed: \(error.localizedDescription)")
        return 1
    }
    let backend = engine.playbackBackend
    print("backend=\(backend.rawValue) decoder=\(engine.activeAudioDecoder ?? "?") duration=\(String(format: "%.1f", engine.duration))s")
    guard backend == .audio else {
        print("FAIL: expected backend .audio, got \(backend.rawValue)")
        return 1
    }
    let duration = engine.duration
    let ticks = max(1, Int(playSeconds))
    for _ in 0..<ticks {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        print(String(format: "  t=%.2fs", engine.currentTime))
    }
    let finalTime = engine.currentTime
    let endState = engine.state
    let finalDuration = engine.duration
    print("  final duration=\(String(format: "%.1f", finalDuration))s")
    engine.stop()
    if finalTime <= 0.5 {
        print("FAIL: clock did not advance (t=\(finalTime)); decode or render path is silent")
        return 1
    }
    // If we stopped sampling well before the file's end, the engine MUST
    // still be playing. If it already reached .idle, the demuxer raced to
    // EOF and ended the track early (the missing-back-pressure regression).
    if duration > 0, playSeconds < duration - 1.0 {
        if case .playing = endState {
            // expected
        } else {
            print("FAIL: engine left .playing early (state=\(endState)) at t=\(String(format: "%.2f", finalTime))s of \(String(format: "%.1f", duration))s; demuxer raced to EOF")
            return 1
        }
    }
    print("OK: audio path advanced the clock to \(String(format: "%.2f", finalTime))s (state=\(endState), duration=\(String(format: "%.1f", duration))s)")
    return 0
}
