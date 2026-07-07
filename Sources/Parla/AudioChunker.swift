import Foundation
import ParlaCore

/// Pure planning + stitching for the chunked long-audio pipeline. **No I/O** — the actual ffmpeg
/// split and per-chunk transcription live in the caller; this computes the chunk count, decides when
/// to chunk, reassembles per-chunk timecodes into one global timeline, and buckets segments into
/// chapters for the long-recording view. All deterministic + unit-testable in the pure-logic style.
enum AudioChunker {
    /// Recordings longer than this (seconds) use the chunked pipeline; shorter ones stay single-pass.
    static let longThresholdSec: Double = 600    // 10 min

    /// Each chunk's wall length (seconds). ~2 min keeps one chunk's WAV + samples small in memory.
    static let chunkLengthSec: Double = 120      // 2 min

    /// Default chapter-bucket width for the long-recording view.
    static let chapterSizeSec: Double = 120      // 2 min

    /// Whether a recording of this length should use the chunked pipeline.
    static func isLong(durationSec: Double, threshold: Double = longThresholdSec) -> Bool {
        durationSec > threshold
    }

    /// Whether to use the chunked pipeline: a long recording with ffmpeg available. Deliberately
    /// INDEPENDENT of batch membership — a long file dropped alongside others must still be chunked
    /// (bounded memory), not run whole in a single pass.
    static func shouldChunk(durationSec: Double, ffmpegAvailable: Bool) -> Bool {
        ffmpegAvailable && isLong(durationSec: durationSec)
    }

    /// Number of chunks for a given duration (always ≥ 1).
    static func chunkCount(durationSec: Double, chunkLength: Double = chunkLengthSec) -> Int {
        guard durationSec > 0, chunkLength > 0 else { return 1 }
        return max(1, Int((durationSec / chunkLength).rounded(.up)))
    }

    /// Offset one chunk's segments into the global timeline: chunk `k` covers `[k*chunkLength, …)`,
    /// so every local timecode shifts by `k*chunkLength`.
    /// NOTE: ffmpeg's segment muxer cuts on frame boundaries, so a real chunk's start drifts from the
    /// nominal `k*chunkLength` by tens of ms (measured ≤ ~20 ms accumulated over a 25-min file) — a
    /// constant per-chunk offset, not compounding. Imperceptible for subtitles, and `stitch`'s sort +
    /// `subtitleCues`'s end≥start clamp absorb any tiny overlap. Left nominal for simplicity.
    static func offsetSegments(_ segs: [Segment], chunkIndex k: Int,
                               chunkLength: Double = chunkLengthSec) -> [Segment] {
        let shift = Double(k) * chunkLength
        return segs.map { Segment(start: $0.start + shift, end: $0.end + shift, text: $0.text) }
    }

    /// Stitch per-chunk segment arrays (in chunk order, index 0…N-1) into one global, sorted list.
    static func stitch(chunkSegments: [[Segment]], chunkLength: Double = chunkLengthSec) -> [Segment] {
        chunkSegments.enumerated()
            .flatMap { k, segs in offsetSegments(segs, chunkIndex: k, chunkLength: chunkLength) }
            .sorted { $0.start < $1.start }
    }

    /// Representation of a FAILED chunk on the timeline: a ZERO-width marker segment carrying `label`
    /// (offsetSegments later shifts it to the chunk's start). Zero width so it can't claim a fake
    /// 2-min span that would overlap the next chunk. The caller feeds the same `label` into the flat
    /// text too, so a gap shows in BOTH the segment view and copy/TXT/MD — not only in segments.
    static func failedChunkSegment(label: String) -> Segment { Segment(start: 0, end: 0, text: label) }

    /// Language for a stitched long-audio result: the first chunk's actually-reported language wins
    /// (mirrors the single-pass path, which returns the engine's reported language — the requested one
    /// if requested, else the detected one), falling back to the requested language, then "". Empty
    /// per-chunk languages (failed/silent chunks) are skipped — so Auto-mode long files keep a real
    /// detected language instead of saving "".
    static func resolveLanguage(chunkLanguages: [String], requested: String?) -> String {
        chunkLanguages.first(where: { !$0.isEmpty }) ?? requested ?? ""
    }

    /// Bucket already-global (stitched) segments into fixed `size`-second windows for the chapter view.
    /// A pure function of the segments + size — no persisted state. Empty windows are skipped (a
    /// chapter only exists where there's speech); chapters are renumbered 1…M for display.
    static func chapters(from segments: [Segment], size: Double = chapterSizeSec) -> [Chapter] {
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
struct Chapter: Identifiable, Equatable {
    let index: Int          // 0-based display order
    let startSec: Double    // window start (bucket * size)
    let endSec: Double      // window end
    let segments: [Segment]
    var id: Int { index }

    /// `[mm:ss–mm:ss]` window label.
    var rangeLabel: String { "[\(fmtTime(startSec))–\(fmtTime(endSec))]" }

    /// The chapter's transcript text for summarization/export: segment `cleanText` (WhisperKit tokens
    /// stripped — load-bearing), empty segments dropped, space-joined. Pure + unit-testable.
    var joinedText: String {
        segments.map(\.cleanText).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
