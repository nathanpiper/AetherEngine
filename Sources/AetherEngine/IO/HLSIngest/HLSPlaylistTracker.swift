import Foundation

/// Pure cursor over successive refreshes of a live media playlist.
/// Feed it each freshly parsed playlist; it returns the segments to fetch,
/// in order, exactly once each. Handles the three live realities:
/// initial join (start near the live edge), normal forward growth, and the
/// provider window sliding past our cursor (rejoin at the edge, flagged as
/// a discontinuity so downstream timestamp rebase has a deterministic cue).
/// Policy notes: joins target a duration COVERAGE, not a segment count:
/// the join takes the newest segments until their summed duration reaches
/// `max(minJoinCoverageSeconds, 1.5 * playlist.targetDuration)`, capped at
/// `edgeOffset` segments (always at least one). Joining on segment count
/// alone burst up to 36s of backlog on providers with long segments, which
/// made the local live playlist grow many times faster than real time and
/// reliably tripped a one-time AVPlayer pacing stall a few seconds into
/// every direct session (device repro 2026-06-11); the ~8s floor keeps the
/// startup shape close to the proven stall-free server-remux cushion. The
/// 1.5x-targetDuration term raises the coverage for long-segment upstreams
/// (e.g. 10s segments -> two segments / 20s) so AVPlayer always holds at
/// least one upstream-cadence worth of buffer across the bursty
/// inter-batch arrival gap (device repro 2026-06-11: ~5s stalls every
/// ~20s with a single-segment join). A rejoin after a window slide resets
/// `stallCount`; a playlist that SHRINKS (spec-violating server) is
/// indistinguishable from a stall and counts as one, which is the desired
/// pressure toward the stall budget.
struct HLSPlaylistTracker {
    /// Hard cap on how many segments behind the live edge to start.
    private let edgeOffset: Int
    /// Floor for the join's duration-coverage target; the effective target
    /// is `max(minJoinCoverageSeconds, 1.5 * playlist.targetDuration)`.
    private let minJoinCoverageSeconds: Double
    /// Next media-sequence number we have NOT yet returned. nil until primed.
    private(set) var nextSequence: Int?
    /// Consecutive refreshes that produced no new segment.
    private(set) var stallCount = 0

    init(edgeOffset: Int = 3, minJoinCoverageSeconds: Double = 8) {
        self.edgeOffset = edgeOffset
        self.minJoinCoverageSeconds = minJoinCoverageSeconds
    }

    mutating func newSegments(in playlist: HLSMediaPlaylist) -> [HLSMediaSegment] {
        let windowStart = playlist.mediaSequence
        let windowEnd = playlist.mediaSequence + playlist.segments.count // exclusive

        func segments(from sequence: Int, markFirstDiscontinuity: Bool) -> [HLSMediaSegment] {
            let startIndex = sequence - windowStart
            guard startIndex < playlist.segments.count else { return [] }
            var result = Array(playlist.segments[max(0, startIndex)...])
            if markFirstDiscontinuity, !result.isEmpty {
                let first = result[0]
                result[0] = HLSMediaSegment(
                    uri: first.uri, duration: first.duration,
                    discontinuityBefore: true, crypt: first.crypt
                )
            }
            return result
        }

        /// Join sequence: walk back from the live edge, taking the newest
        /// segments until the summed duration REACHES the coverage target
        /// `max(minJoinCoverageSeconds, 1.5 * targetDuration)`, capped at
        /// `edgeOffset` segments. Always at least one segment. For 4s
        /// upstreams this is the previous behaviour exactly (2 segments /
        /// 8s); for 10s upstreams it takes 2 segments / 20s so the buffer
        /// rides out the ~10s bursty inter-batch gap.
        func joinStart() -> Int {
            let coverage = max(minJoinCoverageSeconds, 1.5 * playlist.targetDuration)
            var taken = 0
            var seconds = 0.0
            for segment in playlist.segments.reversed() {
                if taken >= edgeOffset { break }
                if taken > 0, seconds >= coverage { break }
                taken += 1
                seconds += segment.duration
            }
            return windowEnd - taken
        }

        guard let cursor = nextSequence else {
            // Initial join near the live edge, duration-capped.
            nextSequence = windowEnd
            return segments(from: joinStart(), markFirstDiscontinuity: false)
        }

        if cursor < windowStart {
            // Window slid past us: rejoin near the edge, mark the seam.
            nextSequence = windowEnd
            stallCount = 0
            return segments(from: joinStart(), markFirstDiscontinuity: true)
        }

        let fresh = segments(from: cursor, markFirstDiscontinuity: false)
        if fresh.isEmpty {
            stallCount += 1
        } else {
            stallCount = 0
            nextSequence = windowEnd
        }
        return fresh
    }
}
