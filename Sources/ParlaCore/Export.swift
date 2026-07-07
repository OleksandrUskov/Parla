import Foundation

/// Export formats for a transcript — the single source of truth for extension + display name.
/// SRT/VTT are inherently per-recording (cue indices/timecodes can't concatenate across the archive),
/// so they're excluded from whole-history export.
public enum ExportFormat: String, CaseIterable, Identifiable {
    case txt, markdown, srt, vtt, json
    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .txt:      return "txt"
        case .markdown: return "md"
        case .srt:      return "srt"
        case .vtt:      return "vtt"
        case .json:     return "json"
        }
    }

    public var displayName: String {
        switch self {
        case .txt:      return "Plain text (.txt)"
        case .markdown: return "Markdown (.md)"
        case .srt:      return "SubRip (.srt)"
        case .vtt:      return "WebVTT (.vtt)"
        case .json:     return "JSON (.json)"
        }
    }

    /// Whether the format makes sense for the WHOLE history (one file). SRT/VTT are per-recording only.
    public var supportsWholeHistory: Bool {
        switch self {
        case .txt, .markdown, .json: return true
        case .srt, .vtt:             return false
        }
    }

    /// A subtitle format (SubRip/WebVTT) — grouped + labelled together in the export menu (the video→subtitles win).
    public var isSubtitle: Bool { self == .srt || self == .vtt }

    /// Whether this format is offered for "summary only" export — prose digests (Plain/Markdown). Subtitle formats
    /// (SRT/VTT) and the full-record JSON have no meaning without the transcript body, so they're hidden in that mode.
    public var supportsInsightsOnly: Bool {
        switch self {
        case .txt, .markdown:     return true
        case .srt, .vtt, .json:   return false
        }
    }
}

/// What an export includes (AI P4) — the 3-way "Content" picker in the export menu, remembered across launches.
public enum ExportContent: String, CaseIterable, Identifiable, Sendable {
    case transcript      // the transcript only (the pre-P4 default)
    case withInsights    // transcript + AI insights + per-chapter digest
    case insightsOnly    // just the insights + per-chapter digest, NO transcript body
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .transcript:   return L("export.content.transcript")
        case .withInsights: return L("export.content.withInsights")
        case .insightsOnly: return L("export.content.insightsOnly")
        }
    }
}

// MARK: - Subtitle timecodes

/// `HH:MM:SS,mmm` (SubRip — comma before the milliseconds). Negatives clamp to zero.
public func srtTimecode(_ seconds: Double) -> String { subtitleTimecode(seconds, msSeparator: ",") }

/// `HH:MM:SS.mmm` (WebVTT — dot before the milliseconds). Negatives clamp to zero.
public func vttTimecode(_ seconds: Double) -> String { subtitleTimecode(seconds, msSeparator: ".") }

private func subtitleTimecode(_ seconds: Double, msSeparator: String) -> String {
    let safe = seconds.isFinite ? seconds : 0               // NaN/±inf would trap Int(_:) → kill the export
    let totalMs = max(0, Int((safe * 1000).rounded()))      // clamp negatives, round (not floor)
    let ms = totalMs % 1000
    let totalSec = totalMs / 1000
    let s = totalSec % 60
    let m = (totalSec / 60) % 60
    let h = totalSec / 3600
    return String(format: "%02d:%02d:%02d%@%03d", h, m, s, msSeparator, ms)
}

// MARK: - Cue derivation

/// Collapse blank lines inside a cue body. A BLANK LINE terminates a cue in both SubRip and WebVTT,
/// so an edited transcript containing a paragraph break would emit a structurally-broken subtitle
/// file (the text after the gap is parsed as a new, index-less cue). Single line breaks are kept.
public func collapseBlankLines(_ s: String) -> String {
    s.replacingOccurrences(of: #"\n[ \t]*\n+"#, with: "\n", options: .regularExpression)
}

/// The cues to render as subtitles. Mirrors `display(timestamps:)`:
/// - drops empty-text segments,
/// - for an EDITED record (text no longer matches the segments) degrades to ONE full-text cue
///   spanning `[0, durationSec]` — never emit mismatched timecodes,
/// - clamps each cue so `start ≥ 0` and `end ≥ start` (no reversed `-->` ranges),
/// - collapses blank lines in each cue body (a blank line would break the cue framing).
public func subtitleCues(_ item: TranscriptItem) -> [(start: Double, end: Double, text: String)] {
    if item.isEdited || item.segments.isEmpty {
        let text = collapseBlankLines(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else { return [] }
        return [(0, max(0, item.durationSec), text)]
    }
    return item.segments
        .map { seg -> (start: Double, end: Double, text: String) in
            let start = max(0, seg.start)
            return (start: start, end: max(start, seg.end), text: collapseBlankLines(seg.cleanText))   // strip WhisperKit tokens
        }
        .filter { !$0.text.isEmpty }   // a tokens-only segment becomes empty after cleaning → drop it
}

// MARK: - Insight header (AI P4 — opt-in via the export menu)

/// A human-readable insight header for an exported transcript: title / summary / keywords / action items,
/// each emitted ONLY when its field is set — so an insight-less note contributes NOTHING and its export stays
/// byte-identical to before P4. Returns "" when the note has no insights at all. `markdown` switches between
/// Markdown (blockquote summary, bold labels, `- [ ]`/`- [x]` GitHub checkboxes) and plain labelled lines.
/// When non-empty the block ALWAYS ends with exactly one trailing blank line, so a caller can prepend it
/// before the body. Labels are localized (resolve to the current UI language, like `exportMarkdown`'s `transcript.edited`).
public func insightBlock(_ item: TranscriptItem, markdown: Bool) -> String {
    var out = ""
    // Title: the real AI/extractive title only (NOT the sourceName fallback — the header already carries the name).
    let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !title.isEmpty {
        out += markdown ? "**\(L("transcript.title")):** \(title)\n\n" : "\(L("transcript.title")): \(title)\n"
    }
    let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !summary.isEmpty {
        out += markdown ? "> \(summary)\n\n" : "\(L("transcript.summary")): \(summary)\n"
    }
    if let keywords = item.keywords, !keywords.isEmpty {
        let joined = keywords.joined(separator: ", ")
        out += markdown ? "**\(L("transcript.keywords")):** \(joined)\n\n" : "\(L("transcript.keywords")): \(joined)\n"
    }
    if let actions = item.actions, !actions.isEmpty {
        out += markdown ? "**\(L("transcript.actions")):**\n" : "\(L("transcript.actions")):\n"
        for a in actions { out += (a.done ? "- [x] " : "- [ ] ") + a.text + "\n" }   // GFM checkboxes (space is load-bearing)
        if markdown { out += "\n" }   // close the markdown block with a blank line
    }
    guard !out.isEmpty else { return "" }
    // Plain mode emits single-`\n` lines; normalize to exactly one trailing blank line so the body is separated
    // (the markdown branches already end each block with `\n\n`).
    if !markdown && !out.hasSuffix("\n\n") { out += "\n" }
    return out
}

/// Per-chapter digest for a LONG note's export: `### [mm:ss–mm:ss]` + that chapter's summary, for every chapter
/// that has one (matched by its stable start-time window). "" for short notes / notes without chapter summaries.
/// Placed ABOVE the full transcript — a navigable digest that ADDS to the source, never replaces it. `markdown`
/// switches between a `###` heading + blockquote and plain `range` + line. Ends with one trailing blank line.
public func chapterDigest(_ item: TranscriptItem, markdown: Bool) -> String {
    guard let summaries = item.chapterSummaries, !summaries.isEmpty else { return "" }
    let chapters = AudioChunker.chapters(from: item.segments)
    guard !chapters.isEmpty else { return "" }
    var out = ""
    for chapter in chapters {
        // Match by the stable (start) window, NOT by positional index (which renumbers on time gaps).
        guard let cs = summaries.first(where: { abs($0.startSec - chapter.startSec) < 0.5 }) else { continue }
        out += markdown ? "### \(chapter.rangeLabel)\n> \(cs.summary)\n\n"
                        : "\(chapter.rangeLabel)\n\(cs.summary)\n\n"
    }
    return out
}

/// The insight header framed as a WebVTT `NOTE` comment block (spec-valid: `NOTE`, lines, then a blank line
/// that terminates it before the first cue). "" when the note has no insights. Built from the plain block,
/// which has no interior blank lines (each would otherwise close the comment early).
private func insightNoteVTT(_ item: TranscriptItem) -> String {
    let body = insightBlock(item, markdown: false)   // ends with a single trailing blank line
    return body.isEmpty ? "" : "NOTE\n\(body)"
}

// MARK: - Formatters (pure)

/// SubRip: 1-based cue index, `start --> end` (comma ms), blank line between cues.
/// Empty when there are no usable cues (never a 0-cue garbage file).
/// NOTE: insights are DELIBERATELY never injected — SubRip has no comment syntax, so any header would parse
/// as a malformed first cue and break players (WebVTT carries them in a `NOTE` block instead).
public func exportSRT(_ item: TranscriptItem) -> String {
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
/// `.withInsights` inserts a `NOTE` comment block after the header; `.insightsOnly` keeps just that NOTE (no cues).
public func exportVTT(_ item: TranscriptItem, content: ExportContent = .transcript) -> String {
    var out = "WEBVTT\n\n"
    if content != .transcript { out += insightNoteVTT(item) }   // "" when the note has no insights → byte-identical
    guard content != .insightsOnly else { return out }
    for cue in subtitleCues(item) {
        out += "\(vttTimecode(cue.start)) --> \(vttTimecode(cue.end))\n"
        out += "\(cue.text)\n\n"
    }
    return out
}

/// JSON over the REAL `Codable` model (no parallel DTO that could drift). Pretty + sorted keys →
/// deterministic bytes; default date encoding → exact round-trip.
public func exportJSON(_ item: TranscriptItem) throws -> Data {
    var clean = item
    clean.segments = item.segments.map { Segment(start: $0.start, end: $0.end, text: $0.cleanText) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(clean)
}

/// Plain text — flat (`item.text`) or timestamped (`[mm:ss] line`), via the existing `display`.
/// `.withInsights` prepends a labelled insight header; `.insightsOnly` emits only that header (no body).
public func exportPlainTXT(_ item: TranscriptItem, timestamps: Bool, content: ExportContent = .transcript) -> String {
    var out = ""
    if content != .transcript { out += insightBlock(item, markdown: false) + chapterDigest(item, markdown: false) }
    if content != .insightsOnly { out += item.display(timestamps: timestamps) }
    return out
}

/// One transcript as a Markdown block — the same shape as a single `exportText` record, minus the
/// archive title header and the trailing `---` separator (that divider sits between records).
/// `.withInsights` inserts the insight header before the body; `.insightsOnly` drops the body.
public func exportMarkdown(_ item: TranscriptItem, content: ExportContent = .transcript) -> String {
    let editedMark = item.isEdited ? " · " + L("transcript.edited") : ""
    let meta = "_\(item.date.formatted(date: .abbreviated, time: .shortened)) · \(item.language.uppercased()) · \(friendlyModel(item.model))\(editedMark)_"
    var out = "## \(item.sourceName)\n\(meta)\n\n"
    if content != .transcript { out += insightBlock(item, markdown: true) + chapterDigest(item, markdown: true) }
    if content != .insightsOnly { out += "\(item.text)\n" }
    return out
}

/// Render one item to a string for a given format (UI entry point). `.json` is handled separately
/// (it returns `Data`); this returns its UTF-8 string form for share-sheet convenience. `content` (the export-menu
/// picker) folds insights into the human-readable formats / drops the body for "summary only"; JSON is always the
/// full record, and SRT deliberately omits insights (no comment syntax) — both ignore the picker beyond cues.
public func exportString(_ item: TranscriptItem, as format: ExportFormat, timestamps: Bool = true, content: ExportContent = .transcript) -> String {
    switch format {
    case .txt:      return exportPlainTXT(item, timestamps: timestamps, content: content)
    case .markdown: return exportMarkdown(item, content: content)
    case .srt:      return exportSRT(item)                       // subtitles: content modes don't apply
    case .vtt:      return exportVTT(item, content: content)
    case .json:     return (try? exportJSON(item)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
