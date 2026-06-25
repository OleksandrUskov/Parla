import Foundation

/// Pure segment-level streaming reconciliation (MIC_DICTATION P3).
///
/// The live dictation loop decodes a sliding window of the growing audio every ~1.5–2 s. This core takes
/// each window's segments and splits them into a **stable confirmed prefix** and a **dimmed hypothesis
/// tail**: it confirms all-but-the-last-`holdback` segments (the live edge keeps shifting as right-context
/// arrives, so the last couple of segments are volatile) and advances a cursor to the confirmed boundary so
/// the next window starts there — keeping each decode bounded instead of re-reading the whole recording.
///
/// Cutting only at **segment** boundaries (never mid-word) is the RU/UK guardrail: Whisper segments end at
/// pauses/clause boundaries, so the confirmed text never truncates a case/aspect ending mid-word. This drives
/// the *live preview only*; the saved transcript still comes from a full offline decode, so streaming
/// artifacts never reach stored text. No audio types inside → fully unit-testable (mirrors `SilenceDetector`).
struct StreamingReconciler {
    /// Trailing segments withheld from confirmation each tick (most likely to change as more audio arrives).
    /// WhisperKit's `AudioStreamTranscriber` uses 2.
    let holdback: Int

    /// The stable, confirmed transcript so far (segment texts joined in order). Render this solid.
    private(set) var confirmedText: String = ""

    /// Absolute audio position (seconds from capture start) where the confirmed prefix ends — i.e. where the
    /// next decode window should begin. The orchestrator turns this into a sample index for `liveSamples(from:)`.
    private(set) var confirmedSeconds: Double = 0

    /// The trailing un-confirmed segment texts joined — the live, dimmed tail. Recomputed every tick.
    private(set) var hypothesisText: String = ""

    init(holdback: Int = 2) { self.holdback = max(0, holdback) }

    /// The full live text to show (confirmed prefix + dimmed hypothesis), for callers that render one string.
    var liveText: String { Self.appended(confirmedText, hypothesisText) }

    /// Feed the decode of the current window.
    /// - Parameters:
    ///   - segments: the window's segments, with times **relative to the window start**.
    ///   - windowStart: absolute seconds the window began at (equal to `confirmedSeconds` when the orchestrator
    ///     starts the window at the cursor).
    ///
    /// Confirms all but the last `holdback` segments, appends their text to `confirmedText`, and advances
    /// `confirmedSeconds` to the last confirmed segment's absolute end. Segments are never re-confirmed:
    /// because the next window starts at the advanced cursor, already-confirmed audio is not decoded again.
    mutating func ingest(segments: [Segment], windowStart: Double) {
        let confirmCount = max(0, segments.count - holdback)
        let confirmed = segments.prefix(confirmCount)
        let tail = segments.dropFirst(confirmCount)

        if let last = confirmed.last {
            confirmedText = Self.appended(confirmedText, Self.join(confirmed))
            confirmedSeconds = windowStart + last.end
        }
        hypothesisText = Self.join(tail)
    }

    /// Trim + join segment texts with single spaces, dropping any that strip to empty.
    private static func join<S: Sequence>(_ segs: S) -> String where S.Element == Segment {
        segs.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Append `next` to `base` with a single separating space (no leading/trailing space, no double space).
    private static func appended(_ base: String, _ next: String) -> String {
        if next.isEmpty { return base }
        if base.isEmpty { return next }
        return base + " " + next
    }
}
