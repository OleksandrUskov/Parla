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
    /// - Parameter flush: confirm EVERY segment this tick (holdback 0). The orchestrator sets it when the
    ///   decode window has grown large without the cursor advancing (continuous low-pause speech where
    ///   Whisper emits ≤ holdback segments per window) — flushing makes the cursor catch up so the next
    ///   window stays bounded instead of re-decoding an ever-growing buffer. Normal ticks hold the tail back.
    mutating func ingest(segments: [Segment], windowStart: Double, flush: Bool = false) {
        let effectiveHoldback = flush ? 0 : holdback
        let confirmCount = max(0, segments.count - effectiveHoldback)
        let confirmed = segments.prefix(confirmCount)
        let tail = segments.dropFirst(confirmCount)

        if let last = confirmed.last {
            // Overlap-aware append: the next window restarts at the cursor and may re-emit the last confirmed
            // word(s) (the cut rarely lands on the true acoustic boundary, and each window is decoded cold),
            // so drop any leading words already ending confirmedText — else the preview shows "привет привет".
            confirmedText = Self.mergeDedup(confirmedText, Self.join(confirmed))
            confirmedSeconds = windowStart + last.end
        }
        hypothesisText = Self.join(tail)
    }

    /// Append `addition` to `base`, dropping any leading words of `addition` that already form the tail of
    /// `base` (word-level overlap, capped at 8 words). Removes the cross-window duplicate-word artifact that
    /// a blind append produces when a re-decoded window re-emits the previous cut's trailing words.
    static func mergeDedup(_ base: String, _ addition: String) -> String {
        if addition.isEmpty { return base }
        if base.isEmpty { return addition }
        let baseWords = base.split(separator: " ")
        let addWords = addition.split(separator: " ")
        let maxOverlap = min(baseWords.count, addWords.count, 8)
        var overlap = 0
        var k = maxOverlap
        while k > 0 {
            if baseWords.suffix(k).elementsEqual(addWords.prefix(k)) { overlap = k; break }
            k -= 1
        }
        let kept = addWords.dropFirst(overlap)
        return kept.isEmpty ? base : base + " " + kept.joined(separator: " ")
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
