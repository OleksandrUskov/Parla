import Foundation

/// Pure planning + stitching for the chunked long-audio pipeline. **No I/O** — the actual ffmpeg
/// split and per-chunk transcription live in the caller; this computes the chunk count, decides when
/// to chunk, reassembles per-chunk timecodes into one global timeline, and buckets segments into
/// chapters for the long-recording view. All deterministic + unit-testable in the pure-logic style.
public enum AudioChunker {
    /// Recordings longer than this (seconds) use the chunked pipeline; shorter ones stay single-pass.
    public static let longThresholdSec: Double = 600    // 10 min

    /// Each chunk's wall length (seconds). ~2 min keeps one chunk's WAV + samples small in memory.
    public static let chunkLengthSec: Double = 120      // 2 min

    /// Default chapter-bucket width for the long-recording view.
    public static let chapterSizeSec: Double = 120      // 2 min

    /// Whether a recording of this length should use the chunked pipeline.
    public static func isLong(durationSec: Double, threshold: Double = longThresholdSec) -> Bool {
        durationSec > threshold
    }

    /// Whether to use the chunked pipeline: a long recording with a chunking-capable decoder. Deliberately
    /// INDEPENDENT of batch membership — a long file dropped alongside others must still be chunked
    /// (bounded memory), not run whole in a single pass.
    public static func shouldChunk(durationSec: Double, chunkingAvailable: Bool) -> Bool {
        chunkingAvailable && isLong(durationSec: durationSec)
    }

    /// Number of chunks for a given duration (always ≥ 1).
    public static func chunkCount(durationSec: Double, chunkLength: Double = chunkLengthSec) -> Int {
        guard durationSec > 0, chunkLength > 0 else { return 1 }
        return max(1, Int((durationSec / chunkLength).rounded(.up)))
    }

    /// Offset one chunk's segments into the global timeline: chunk `k` covers `[k*chunkLength, …)`,
    /// so every local timecode shifts by `k*chunkLength`.
    /// NOTE: the in-process ChunkWriter cuts EXACTLY on `k*chunkLength` boundaries, so a chunk's start
    /// matches the nominal offset with no drift. `stitch`'s sort + `subtitleCues`'s end≥start clamp still
    /// absorb any tiny overlap from rounding.
    public static func offsetSegments(_ segs: [Segment], chunkIndex k: Int,
                               chunkLength: Double = chunkLengthSec) -> [Segment] {
        let shift = Double(k) * chunkLength
        return segs.map { Segment(start: $0.start + shift, end: $0.end + shift, text: $0.text) }
    }

    /// Stitch per-chunk segment arrays (in chunk order, index 0…N-1) into one global, sorted list.
    public static func stitch(chunkSegments: [[Segment]], chunkLength: Double = chunkLengthSec) -> [Segment] {
        chunkSegments.enumerated()
            .flatMap { k, segs in offsetSegments(segs, chunkIndex: k, chunkLength: chunkLength) }
            .sorted { $0.start < $1.start }
    }

    /// Representation of a FAILED chunk on the timeline: a ZERO-width marker segment carrying `label`
    /// (offsetSegments later shifts it to the chunk's start). Zero width so it can't claim a fake
    /// 2-min span that would overlap the next chunk. The caller feeds the same `label` into the flat
    /// text too, so a gap shows in BOTH the segment view and copy/TXT/MD — not only in segments.
    public static func failedChunkSegment(label: String) -> Segment { Segment(start: 0, end: 0, text: label) }

    /// Language for a stitched long-audio result: the first chunk's actually-reported language wins
    /// (mirrors the single-pass path, which returns the engine's reported language — the requested one
    /// if requested, else the detected one), falling back to the requested language, then "". Empty
    /// per-chunk languages (failed/silent chunks) are skipped — so Auto-mode long files keep a real
    /// detected language instead of saving "".
    public static func resolveLanguage(chunkLanguages: [String], requested: String?) -> String {
        chunkLanguages.first(where: { !$0.isEmpty }) ?? requested ?? ""
    }

    /// Bucket already-global (stitched) segments into fixed `size`-second windows for the chapter view.
    /// A pure function of the segments + size — no persisted state. Empty windows are skipped (a
    /// chapter only exists where there's speech); chapters are renumbered 1…M for display.
    public static func chapters(from segments: [Segment], size: Double = chapterSizeSec) -> [Chapter] {
        guard !segments.isEmpty, size > 0 else { return [] }
        let grouped = Dictionary(grouping: segments) { max(0, Int($0.start / size)) }
        return grouped.keys.sorted().enumerated().map { displayIdx, bucket in
            let segs = (grouped[bucket] ?? []).sorted { $0.start < $1.start }
            return Chapter(index: displayIdx,
                           startSec: Double(bucket) * size,
                           endSec: Double(bucket + 1) * size,
                           segments: segs)
        }
    }
}

/// One chapter of a long recording: a `size`-second window of the timeline plus the segments in it.
/// Derived at render time from `segments` — never persisted (see LONG_AUDIO_CHUNKING blueprint §4).
public struct Chapter: Identifiable, Equatable {
    public let index: Int          // 0-based display order
    public let startSec: Double    // window start (bucket * size)
    public let endSec: Double      // window end
    public let segments: [Segment]
    public var id: Int { index }

    /// `[mm:ss–mm:ss]` window label.
    public var rangeLabel: String { "[\(fmtTime(startSec))–\(fmtTime(endSec))]" }

    /// The chapter's transcript text for summarization/export: segment `cleanText` (WhisperKit tokens
    /// stripped — load-bearing), empty segments dropped, space-joined. Pure + unit-testable.
    public var joinedText: String {
        segments.map(\.cleanText).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
