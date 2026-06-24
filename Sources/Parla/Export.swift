import Foundation

/// Export formats for a transcript — the single source of truth for extension + display name.
/// SRT/VTT are inherently per-recording (cue indices/timecodes can't concatenate across the archive),
/// so they're excluded from whole-history export.
enum ExportFormat: String, CaseIterable, Identifiable {
    case txt, markdown, srt, vtt, json
    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .txt:      return "txt"
        case .markdown: return "md"
        case .srt:      return "srt"
        case .vtt:      return "vtt"
        case .json:     return "json"
        }
    }

    var displayName: String {
        switch self {
        case .txt:      return "Plain text (.txt)"
        case .markdown: return "Markdown (.md)"
        case .srt:      return "SubRip (.srt)"
        case .vtt:      return "WebVTT (.vtt)"
        case .json:     return "JSON (.json)"
        }
    }

    /// Whether the format makes sense for the WHOLE history (one file). SRT/VTT are per-recording only.
    var supportsWholeHistory: Bool {
        switch self {
        case .txt, .markdown, .json: return true
        case .srt, .vtt:             return false
        }
    }
}

// MARK: - Subtitle timecodes

/// `HH:MM:SS,mmm` (SubRip — comma before the milliseconds). Negatives clamp to zero.
func srtTimecode(_ seconds: Double) -> String { subtitleTimecode(seconds, msSeparator: ",") }

/// `HH:MM:SS.mmm` (WebVTT — dot before the milliseconds). Negatives clamp to zero.
func vttTimecode(_ seconds: Double) -> String { subtitleTimecode(seconds, msSeparator: ".") }

private func subtitleTimecode(_ seconds: Double, msSeparator: String) -> String {
    let totalMs = max(0, Int((seconds * 1000).rounded()))   // clamp negatives, round (not floor)
    let ms = totalMs % 1000
    let totalSec = totalMs / 1000
    let s = totalSec % 60
    let m = (totalSec / 60) % 60
    let h = totalSec / 3600
    return String(format: "%02d:%02d:%02d%@%03d", h, m, s, msSeparator, ms)
}

// MARK: - Cue derivation

/// The cues to render as subtitles. Mirrors `display(timestamps:)`:
/// - drops empty-text segments,
/// - for an EDITED record (text no longer matches the segments) degrades to ONE full-text cue
///   spanning `[0, durationSec]` — never emit mismatched timecodes,
/// - clamps each cue so `start ≥ 0` and `end ≥ start` (no reversed `-->` ranges).
func subtitleCues(_ item: TranscriptItem) -> [(start: Double, end: Double, text: String)] {
    if item.isEdited || item.segments.isEmpty {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return [(0, max(0, item.durationSec), text)]
    }
    return item.segments
        .map { seg -> (start: Double, end: Double, text: String) in
            let start = max(0, seg.start)
            return (start: start, end: max(start, seg.end), text: seg.cleanText)   // strip WhisperKit tokens
        }
        .filter { !$0.text.isEmpty }   // a tokens-only segment becomes empty after cleaning → drop it
}

// MARK: - Formatters (pure)

/// SubRip: 1-based cue index, `start --> end` (comma ms), blank line between cues.
/// Empty when there are no usable cues (never a 0-cue garbage file).
func exportSRT(_ item: TranscriptItem) -> String {
    let cues = subtitleCues(item)
    guard !cues.isEmpty else { return "" }
    var out = ""
    for (i, cue) in cues.enumerated() {
        out += "\(i + 1)\n"
        out += "\(srtTimecode(cue.start)) --> \(srtTimecode(cue.end))\n"
        out += "\(cue.text)\n\n"
    }
    return out
}

/// WebVTT: `WEBVTT` header, dot-ms timecodes, no integer cue index. Always valid (header even if empty).
func exportVTT(_ item: TranscriptItem) -> String {
    var out = "WEBVTT\n\n"
    for cue in subtitleCues(item) {
        out += "\(vttTimecode(cue.start)) --> \(vttTimecode(cue.end))\n"
        out += "\(cue.text)\n\n"
    }
    return out
}

/// JSON over the REAL `Codable` model (no parallel DTO that could drift). Pretty + sorted keys →
/// deterministic bytes; default date encoding → exact round-trip.
func exportJSON(_ item: TranscriptItem) throws -> Data {
    var clean = item
    clean.segments = item.segments.map { Segment(start: $0.start, end: $0.end, text: $0.cleanText) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(clean)
}

/// Plain text — flat (`item.text`) or timestamped (`[mm:ss] line`), via the existing `display`.
func exportPlainTXT(_ item: TranscriptItem, timestamps: Bool) -> String {
    item.display(timestamps: timestamps)
}

/// One transcript as a Markdown block — the same shape as a single `exportText` record, minus the
/// archive title header and the trailing `---` separator (that divider sits between records).
func exportMarkdown(_ item: TranscriptItem) -> String {
    let editedMark = item.isEdited ? " · " + L("transcript.edited") : ""
    let meta = "_\(item.date.formatted(date: .abbreviated, time: .shortened)) · \(item.language.uppercased()) · \(friendlyModel(item.model))\(editedMark)_"
    return "## \(item.sourceName)\n\(meta)\n\n\(item.text)\n"
}

/// Render one item to a string for a given format (UI entry point). `.json` is handled separately
/// (it returns `Data`); this returns its UTF-8 string form for share-sheet convenience.
func exportString(_ item: TranscriptItem, as format: ExportFormat, timestamps: Bool = true) -> String {
    switch format {
    case .txt:      return exportPlainTXT(item, timestamps: timestamps)
    case .markdown: return exportMarkdown(item)
    case .srt:      return exportSRT(item)
    case .vtt:      return exportVTT(item)
    case .json:     return (try? exportJSON(item)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
