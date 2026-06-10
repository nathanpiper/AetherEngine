import Foundation
import Combine

/// Timer-sampled diagnostic surface, split out of `AetherEngine`'s own
/// `ObservableObject` (AetherEngine#29, follow-up).
///
/// `liveTelemetry` is rewritten at 1 Hz by `LiveTelemetrySampler` for
/// the entire lifetime of every playback session, VOD included. While
/// it lived as a `@Published` property on the engine itself, every
/// sample fired `engine.objectWillChange`, so ANY SwiftUI view
/// observing the engine (via `@ObservedObject` / `@EnvironmentObject`)
/// re-rendered its body once per second even if it never read
/// telemetry. That is the same render-storm class the 3.0.0 clock
/// split fixed for `currentTime`; on tvOS a 1 Hz re-render in the tree
/// that presents the player is enough to blink an open native `Menu`.
///
/// Host usage mirrors `PlaybackClock`:
/// - **Polling / one-shot reads** keep working unchanged through the
///   engine's computed forwarder (`engine.liveTelemetry`).
/// - **Stats overlays** observe this object, not the engine: put
///   `@ObservedObject var diagnostics = engine.diagnostics` in the
///   overlay view, or subscribe to `engine.diagnostics.$liveTelemetry`
///   in a view model.
/// - **Everything else** observes the engine and never re-renders on
///   telemetry samples.
@MainActor
public final class EngineDiagnostics: ObservableObject {

    /// 1 Hz snapshot of live playback telemetry while the engine is
    /// `.playing` or `.paused`. `nil` while idle. Driven by
    /// `LiveTelemetrySampler`; cleared in `stopInternal` so a new
    /// session never inherits the previous session's numbers.
    @Published public internal(set) var liveTelemetry: LiveTelemetry?
}
