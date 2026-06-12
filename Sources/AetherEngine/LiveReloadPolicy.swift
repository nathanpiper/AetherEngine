import Foundation

/// Positioning policy for pipeline reloads (audio-track switch,
/// background-return reopen), extracted as pure decisions so the
/// rules are unit-testable and cannot drift between the three call
/// sites (`reloadWithAudioOverride`'s two backend branches and
/// `reloadAtCurrentPosition`).
///
/// The live rules exist because of a device-verified stall (tvOS 26,
/// Jellyfin live `stream.ts`, 2026-06): an audio-switch reload of a
/// LIVE session rebuilt the pipeline against the SAME upstream URL,
/// and Jellyfin re-served its transcode buffer from the start at I/O
/// speed. The new producer therefore cut the entire backlog
/// (segments 0..19, ~60 s) BEFORE AVPlayer's first playlist fetch,
/// so the reloaded session joined a 20-segment live playlist, where
/// a fresh live join sees only the 2-segment startup cushion (the
/// server holds the first manifest response until exactly that
/// cushion exists; see `VideoSegmentProvider.liveStartupSegments`).
/// Against that backlog shape, the host's pre-readiness
/// zero-tolerance seek-to-0 pointed ~60 s behind the live edge while
/// AVPlayer's own live-join logic targeted the edge minus holdback;
/// the item fetched init.mp4 and every listed segment but never
/// reached `readyToPlay`, parking in `waitingToPlay` forever (frozen
/// frame, no recovery). A reload must therefore behave like a fresh
/// live join: no positioning to a stale clock, and no explicit start
/// seek that fights AVPlayer's live-edge selection.
enum LiveReloadPolicy {

    /// Start position a reload hands to `loadNative` / `loadSoftware`
    /// / `load(url:)`.
    ///
    /// - VOD: resume at the pre-reload playhead (an audio switch must
    ///   not lose the user's position). Positions <= 1 s collapse to
    ///   nil so a switch right at the head doesn't pay the seek.
    /// - Live: ALWAYS nil. The pre-reload playhead is a stale clock
    ///   against the rebuilt session's fresh output timeline: the DVR
    ///   window restarts at the rejoin, so a resume position is
    ///   meaningless at best and (as a pre-readiness seek on a live
    ///   playlist) stall-prone at worst. A future enhancement could
    ///   restore the DVR offset by translating the old
    ///   `behindLiveSeconds` into the new window once the rejoined
    ///   session has built enough history; today the user rejoins at
    ///   the live edge, matching channel-zap behavior.
    static func resumePosition(isLive: Bool, currentTime: Double) -> Double? {
        if isLive { return nil }
        return currentTime > 1 ? currentTime : nil
    }

    /// Whether the native host should skip its explicit initial seek
    /// (`seek(to: startPosition ?? 0)`) and leave the join position to
    /// AVPlayer.
    ///
    /// - Live REJOIN (reload of a live session): true. The reloaded
    ///   playlist can present a multi-segment backlog (the upstream
    ///   re-serves its buffer at I/O speed, see the type comment), and
    ///   the zero-tolerance seek-to-0 against that backlog is the
    ///   prime suspect for the never-ready AVPlayerItem. Skipping the
    ///   seek gives AVPlayer its standard live join: edge minus
    ///   holdback (3 x TARGETDURATION), or the playlist start when the
    ///   playlist is shorter than the holdback. Same policy as the
    ///   `loadRemoteHLS` bypass, which always wanted AVPlayer's
    ///   natural live-edge start.
    /// - Initial live JOIN: false, deliberately. The first manifest is
    ///   held until the 2-segment startup cushion exists, so seg0 IS
    ///   the cushioned live edge and the explicit seek-to-0 reinforces
    ///   the intended start (device-verified live startup behavior;
    ///   do not change it from here).
    /// - VOD: false. The explicit seek is what makes
    ///   replay-from-beginning land at 0:00 (see the comment at the
    ///   host's call site).
    static func skipInitialSeek(isLive: Bool, isRejoin: Bool) -> Bool {
        isLive && isRejoin
    }
}
