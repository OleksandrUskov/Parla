import Foundation

/// A single recognized fragment with a timecode.
public struct Segment: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    /// Display/export text with WhisperKit special tokens removed. No-op on already-clean segments
    /// (new recordings — the engine strips at the source), so it's safe to use everywhere text is
    /// shown or exported, and it also cleans up older records saved before the engine fix.
    public var cleanText: String { stripWhisperTokens(text) }
}

/// Strip WhisperKit special tokens from a segment's raw text: control tokens
/// (`<|startoftranscript|>`, `<|ru|>`, `<|transcribe|>`, `<|endoftext|>`) and inline timestamp
/// tokens (`<|8.52|>`). WhisperKit's per-segment `.text` carries these verbatim (the overall
/// `.text` does not), so without this they leak into the UI and every export. Collapses the
/// double spaces the removed tokens leave behind and trims.
public func stripWhisperTokens(_ s: String) -> String {
    s.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A single AI-extracted action item (Local-AI Layer). `done` is user-toggleable and persisted.
/// Lives here (not in `LocalLLMService.swift`) because it's part of the persisted data model —
/// `TranscriptItem.actions` stores `[ActionItem]?` and `AIInsights` carries it transiently.
public struct ActionItem: Codable, Hashable, Sendable {
    public var text: String
    public var done: Bool = false
}

extension ActionItem {
    private enum CodingKeys: String, CodingKey { case text, done }
    /// Tolerant decode: a missing `done` defaults to false instead of throwing. Synthesized Decodable
    /// does NOT apply the `= false` for an absent key, and an `ActionItem` decodes nested inside
    /// `FailableDecodable<TranscriptItem>` on the salvage path — a `keyNotFound` there would drop the
    /// WHOLE record (text/segments/audio), not just this field. Mirrors Parla's Optional-field decode
    /// discipline for the nested non-Optional type. Living in an extension keeps the memberwise init +
    /// the synthesized `encode(to:)` (which always writes both keys).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(text: try c.decode(String.self, forKey: .text),
                  done: try c.decodeIfPresent(Bool.self, forKey: .done) ?? false)
    }
}

/// One per-chapter summary for a long recording. Persisted on `TranscriptItem.chapterSummaries`,
/// keyed by the chapter's time window `(startSec,endSec)` — a STABLE key (the window is `bucket * chapterSizeSec`,
/// deterministic from the segments), so it survives re-bucketing / renumbering that a bare positional index would not.
public struct ChapterSummary: Codable, Hashable, Sendable {
    public var startSec: Double
    public var endSec: Double
    public var summary: String
}

extension ChapterSummary {
    private enum CodingKeys: String, CodingKey { case startSec, endSec, summary }
    /// Tolerant decode (mirrors `ActionItem`): a missing field defaults instead of throwing. A `ChapterSummary`
    /// decodes nested inside `FailableDecodable<TranscriptItem>` on the salvage path, where a `keyNotFound` would
    /// drop the WHOLE record. Living in an extension keeps the memberwise init + the synthesized `encode(to:)`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(startSec: try c.decodeIfPresent(Double.self, forKey: .startSec) ?? 0,
                  endSec: try c.decodeIfPresent(Double.self, forKey: .endSec) ?? 0,
                  summary: try c.decodeIfPresent(String.self, forKey: .summary) ?? "")
    }
}

/// Identifies one chapter of one note — the key for the per-chapter "regenerate this chapter" spinner state.
public struct ChapterRef: Hashable, Sendable {
    public let note: UUID
    public let startSec: Double   // the chapter's stable window start (bucket * chapterSizeSec)
    public init(note: UUID, startSec: Double) { self.note = note; self.startSec = startSec }
}

/// A single transcript in the history.
public struct TranscriptItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var date: Date = Date()
    public var sourceName: String
    public var language: String
    public var durationSec: Double
    public var model: String
    public var text: String
    public var segments: [Segment]
    public var edited: Bool? = nil           // whether the text was edited manually (Optional — otherwise old history.json won't decode)
    public var editedAt: Date? = nil         // when it was edited (nil for untouched / legacy records)
    public var sourcePath: String? = nil     // absolute path to the source (for "re-transcribe"); nil on old/legacy
    public var sourceBookmark: Data? = nil   // fallback locator bookmark; nil is fine (Optional → legacy-compatible)
    public var audioFile: String? = nil      // name of the source copy in .../Parla/audio/ (for the player); nil on old records
    public var audioPlayable: String? = nil  // name of the m4a rendition for playback (Opus/video); nil if not needed/not produced
    // Local-AI Layer (all Optional → legacy history.json decodes unchanged; pinned by a legacy-decode test).
    public var title: String?         = nil  // AI/extractive auto-title; nil = legacy/disabled → fall back to sourceName
    public var summary: String?       = nil  // AI/extractive TL;DR; nil = none yet
    public var actions: [ActionItem]? = nil  // [ActionItem]?, NOT [ActionItem] — absent key → nil, not a masking []
    public var aiModel: String?       = nil  // which backend/model produced the insights (provenance / regeneration)
    public var titleEdited: Bool?     = nil  // user renamed the title by hand → never overwrite it on regeneration
    public var keywords: [String]?    = nil  // embedding-ranked topic tags (KeyBERT-style); nil = none/legacy
    public var chapterSummaries: [ChapterSummary]? = nil  // per-chapter generative summaries for LONG notes; nil = none/short/legacy

    public init(id: UUID = UUID(), date: Date = Date(), sourceName: String, language: String, durationSec: Double,
                model: String, text: String, segments: [Segment], edited: Bool? = nil, editedAt: Date? = nil,
                sourcePath: String? = nil, sourceBookmark: Data? = nil, audioFile: String? = nil, audioPlayable: String? = nil,
                title: String? = nil, summary: String? = nil, actions: [ActionItem]? = nil, aiModel: String? = nil,
                titleEdited: Bool? = nil, keywords: [String]? = nil, chapterSummaries: [ChapterSummary]? = nil) {
        self.id = id; self.date = date; self.sourceName = sourceName; self.language = language
        self.durationSec = durationSec; self.model = model; self.text = text; self.segments = segments
        self.edited = edited; self.editedAt = editedAt; self.sourcePath = sourcePath; self.sourceBookmark = sourceBookmark
        self.audioFile = audioFile; self.audioPlayable = audioPlayable; self.title = title; self.summary = summary
        self.actions = actions; self.aiModel = aiModel; self.titleEdited = titleEdited; self.keywords = keywords
        self.chapterSummaries = chapterSummaries
    }

    /// Convenience accessor: nil/false → not edited.
    public var isEdited: Bool { edited == true }

    /// Sidebar/title text: the AI/extractive title when present, else the raw source name (e.g. `msg123.ogg`).
    /// nil, empty, OR whitespace-only title → fall back to `sourceName`, so legacy/disabled records stay
    /// identical and a model that emits a blank/whitespace title (P1/P2) can't render an empty sidebar label.
    public var displayTitle: String {
        if let t = title, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t }
        return sourceName
    }

    /// Text with or without timecodes — for display/copying.
    /// For edited records timecodes are suppressed: the edited text no longer matches
    /// the boundaries of the original segments, so we show flat text.
    public func display(timestamps: Bool) -> String {
        guard timestamps, !isEdited, !segments.isEmpty else { return text }
        return segments
            .map { (time: fmtTime($0.start), text: $0.cleanText) }
            .filter { !$0.text.isEmpty }   // a tokens-only segment becomes empty after cleaning → drop it
            .map { "[\($0.time)] \($0.text)" }
            .joined(separator: "\n")
    }

    public var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

// MARK: - Finding a record's source file (feature 01 «re-transcribe»)

/// Result of trying to find a record's source.
public enum SourceResolution: Equatable {
    case found(URL, scoped: Bool)   // scoped == true → must call stopAccessing… afterwards (future-proofing, under sandbox)
    case missing
}

extension TranscriptItem {
    /// Tries to find the source file: first by absolute path, then by bookmark.
    /// Non-sandboxed build: the plain path is the primary mechanism, bookmark is the fallback locator.
    public func resolveSource(fileManager fm: FileManager = .default) -> SourceResolution {
        if let p = sourcePath, fm.fileExists(atPath: p) {
            return .found(URL(fileURLWithPath: p), scoped: false)
        }
        if let data = sourceBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
               fm.fileExists(atPath: url.path) {
                return .found(url, scoped: false)   // plain bookmark (not security-scoped — the app isn't sandboxed)
            }
        }
        return .missing
    }

    /// Whether the source is available right now (for enabling/disabling the «re-transcribe» item).
    public var hasResolvableSource: Bool {
        if case .found(let url, let scoped) = resolveSource() {
            if scoped { url.stopAccessingSecurityScopedResource() }
            return true
        }
        return false
    }
}

/// Best-effort source bookmark when a record is created. Plain (not security-scoped) — good enough
/// as a fallback locator in a non-sandboxed build. We ignore errors: the primary mechanism is the path.
public func makeSourceBookmark(_ url: URL) -> Data? {
    try? url.bookmarkData()
}

public func fmtTime(_ s: Double) -> String {
    let t = max(0, Int(s.rounded()))
    return String(format: "%02d:%02d", t / 60, t % 60)
}

/// Normalized edit: strip CRLF and trailing whitespace/newlines.
/// An empty result doesn't overwrite the original. Returns (newText, changed).
public func normalizedEdit(_ raw: String, from original: String) -> (text: String, changed: Bool) {
    let trimmed = raw.replacingOccurrences(of: "\r\n", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let new = trimmed.isEmpty ? original : trimmed   // don't let the whole text get wiped by accident
    return (new, new != original)
}

/// «openai_whisper-large-v3-v20240930_turbo_632MB» → «Large v3 v20240930 turbo 632MB».
public func prettyModel(_ raw: String) -> String {
    var s = raw.replacingOccurrences(of: "openai_whisper-", with: "")
    s = s.replacingOccurrences(of: "_", with: " ")
    s = s.replacingOccurrences(of: "-", with: " ")
    guard let first = s.first else { return raw }
    return first.uppercased() + s.dropFirst()
}

/// Short friendly name of the variant for the chip/metadata.
public func friendlyModel(_ raw: String) -> String {
    if raw.contains("large-v3-v20240930") { return "Large v3 turbo" }
    if raw.contains("distil") && raw.contains("large-v3") { return "Distil Large v3" }
    if raw.contains("large-v3") { return "Large v3" }
    if raw.contains("large-v2") { return "Large v2" }
    if raw.contains("medium") { return "Medium" }
    if raw.contains("small") { return "Small" }
    if raw.contains("base") { return "Base" }
    if raw.contains("tiny") { return "Tiny" }
    return prettyModel(raw)
}

/// One model «tier» in the manager (resolves to a real variant).
public struct ModelTier: Identifiable {
    public let title: String
    public let hint: String          // quality/speed only, no size
    public let estimate: String      // approximate size before download, e.g. "~630 МБ" ("" — unknown)
    public let name: String
    public let recommended: Bool
    public var id: String { name }
}

// MARK: - History: filter, export, size formatting

/// Search over the history (case-insensitive). Matches a literal substring of the text or file name
/// (fast path), OR — when a `lemmaIndex` is supplied — every query word's lemma against the note's lemma
/// set, so «деньги» also finds «денег»/«деньгами» (morphology-aware). The lemma path is skipped when the
/// index is empty (not yet built) or the query has no content lemmas, degrading to plain substring.
public func filterHistory(_ items: [TranscriptItem], query: String,
                   lemmaIndex: [UUID: Set<String>] = [:]) -> [TranscriptItem] {
    let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let q = raw.lowercased()
    guard !q.isEmpty else { return items }
    // Lemmatize the query with `searchLemmaSet` — the SAME script-routed transform the index uses, so the two
    // sides can't disagree (NLTagger only normalizes a standalone inflected word when its language is set).
    let queryLemmas = lemmaIndex.isEmpty ? [] : searchLemmaSet(of: raw)
    return items.filter { item in
        if item.text.lowercased().contains(q) || item.sourceName.lowercased().contains(q) { return true }
        guard !queryLemmas.isEmpty, let lemmas = lemmaIndex[item.id] else { return false }
        return queryLemmas.isSubset(of: lemmas)   // all query lemmas present (in any inflected form)
    }
}

/// The entire history as a single markdown text (for export/backup). Honors the export `content` mode: each record
/// gets the SAME insight header as the per-item Markdown export (shared `insightBlock`/`chapterDigest` → no drift),
/// and `.insightsOnly` drops the transcript bodies.
public func exportText(_ items: [TranscriptItem], content: ExportContent = .transcript) -> String {
    var out = L("export.title")
    for it in items {
        out += "## \(it.sourceName)\n"
        let editedMark = it.isEdited ? " · " + L("transcript.edited") : ""
        out += "_\(it.date.formatted(date: .abbreviated, time: .shortened)) · \(it.language.uppercased()) · \(friendlyModel(it.model))\(editedMark)_\n\n"
        if content != .transcript { out += insightBlock(it, markdown: true); out += chapterDigest(it, markdown: true) }   // "" when none
        if content != .insightsOnly { out += it.text + "\n\n" }
        out += "---\n\n"
    }
    return out
}

public func formatBytes(_ bytes: Int64) -> String {
    if bytes <= 0 { return "—" }
    let mb = Double(bytes) / 1_048_576
    if mb >= 1024 { return Lf("unit.gb.fmt", mb / 1024) }
    return Lf("unit.mb.fmt", mb)
}

/// Position in batch processing: «index out of total». Only for a folder drop / multiple files.
public struct BatchProgress: Equatable {
    public var index: Int     // 1-based: current file
    public var total: Int     // total files in the job (>= 2; for a single file — nil instead of the struct)
    public var done: Int      // completed before the current one (for the bottom bar): index-1
}

public enum EnginePhase: Equatable {
    case idle
    case preparing(String, batch: BatchProgress? = nil)
    case downloadingModel(Double)   // 0...1, actual download (one time)
    case loadingModel               // loading into memory: the FIRST compile (ANE) can take minutes,
                                    // cached after — every later launch is fast (see status.loadingmodel.firstrun)
    case transcribing(String, batch: BatchProgress? = nil)
    case failed(String)
}

/// «msg.ogg» (3 of 12)» for a batch, or just «msg.ogg» for a single file.
public func batchLabel(_ name: String, _ b: BatchProgress?) -> String {
    guard let b, b.total > 1 else { return Lf("batch.label.single", name) }
    return Lf("batch.label.multi", name, b.index, b.total)
}


/// History store in ~/Library/Application Support/Parla/history.json
/// Decodes T, or holds nil if that one element is corrupt — so a single bad record can't abort the
/// whole array decode (and wipe the archive). Used by HistoryStore.load's salvage path.
public struct FailableDecodable<T: Decodable>: Decodable {
    public let value: T?
    public init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

public enum HistoryStore {
    /// Path to the history file in ~/Library/Application Support/Parla/.
    /// `var` (not `let`) is a test seam: tests swap the path for a temporary one so they don't touch
    /// the user's real history. In production the value never changes.
    /// `nonisolated(unsafe)`: a deliberate global-mutable opt-out — written only on the main actor
    /// (prod: never after launch; tests: serialized via `withTemporaryHistoryStore`), read widely.
    nonisolated(unsafe) static var fileURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parla", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("history.json")
    }()

    public static func load() -> [TranscriptItem] {
        migrateLegacyIfNeeded()
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        // Happy path: a clean array of records.
        if let items = try? JSONDecoder().decode([TranscriptItem].self, from: data) { return items }
        // Corrupt: salvage every still-decodable record so one bad element (a truncated write, a manual
        // edit, or a record whose required field changed type) never costs the whole archive. (Unknown
        // *extra* keys don't need salvaging — Codable ignores them; the real risk is a required field.)
        if let salvaged = try? JSONDecoder().decode([FailableDecodable<TranscriptItem>].self, from: data) {
            let items = salvaged.compactMap(\.value)
            if items.count < salvaged.count {   // we actually dropped corrupt elements
                quarantine()                    // move the original aside for manual recovery…
                save(items)                     // …and persist the cleaned subset (no re-salvage next launch)
            }
            return items
        }
        // Not even a valid array → keep the bytes, start fresh — never silently clobbered by save().
        quarantine()
        return []
    }

    /// Move a corrupt history.json aside to history.corrupt-<ts>.json so the next save() can't
    /// overwrite the user's only copy. Recovery artifact — never loaded by the app.
    private static func quarantine() {
        let ts = Int(Date().timeIntervalSince1970)
        let dest = fileURL.deletingLastPathComponent().appendingPathComponent("history.corrupt-\(ts).json")
        try? FileManager.default.moveItem(at: fileURL, to: dest)
    }

    /// Legacy app-support dir (the old "Murmur" name) to migrate from. `var` test-seam so unit tests
    /// never touch the real ~/Library/Application Support/Murmur. `nonisolated(unsafe)`: same benign
    /// main-actor-only-write opt-out as `fileURL`.
    nonisolated(unsafe) static var legacyBase: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Murmur", isDirectory: true)

    /// One-time migration from the old app name (Murmur → Parla). Copies history.json AND the player
    /// audio dir AND the folder-watch dedup set — so migrated records keep playback and the watched
    /// folder doesn't re-transcribe everything once. All guarded by "target missing" → idempotent.
    private static func migrateLegacyIfNeeded() {
        // "Murmur" (Parla's former name) was a macOS-only app → iOS never had that Application Support dir.
        // Under the iOS sandbox this migration is at best dead FS churn on every launch, so skip it there.
        #if os(macOS)
        let parla = fileURL.deletingLastPathComponent()
        migrate(target: fileURL, legacy: legacyBase.appendingPathComponent("history.json"))
        migrate(target: parla.appendingPathComponent("processed.json"),
                legacy: legacyBase.appendingPathComponent("processed.json"))
        migrateDir(target: parla.appendingPathComponent("audio", isDirectory: true),
                   legacy: legacyBase.appendingPathComponent("audio", isDirectory: true))
        #endif
    }

    /// Crash-safe copy: stage to a temp sibling, then atomically rename into place. A crash (or full
    /// disk) mid-copy leaves only the `.migrating` staging file — NEVER a truncated `target` — so the
    /// "target missing" guard correctly retries next launch instead of treating a partial file as
    /// already-migrated. Any stale staging from a prior crash is cleared first.
    private static func atomicCopy(_ legacy: URL, to target: URL) {
        let fm = FileManager.default
        let staging = target.appendingPathExtension("migrating")
        try? fm.removeItem(at: staging)
        do {
            try fm.copyItem(at: legacy, to: staging)
            try fm.moveItem(at: staging, to: target)
        } catch {
            try? fm.removeItem(at: staging)
        }
    }

    /// Pure testable logic: copy a legacy FILE → target if target doesn't have a file yet (atomic).
    public static func migrate(target: URL, legacy: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target.path), fm.fileExists(atPath: legacy.path) else { return }
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        atomicCopy(legacy, to: target)
    }

    /// Copy a legacy DIRECTORY → target if target doesn't exist yet (idempotent, best-effort, atomic).
    public static func migrateDir(target: URL, legacy: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard !fm.fileExists(atPath: target.path),
              fm.fileExists(atPath: legacy.path, isDirectory: &isDir), isDir.boolValue else { return }
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        atomicCopy(legacy, to: target)
    }

    public static func save(_ items: [TranscriptItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Folder watching (feature 04)

/// File snapshot: for checking whether it's «finished writing» (size+mtime stable) and as a deduplication key.
public struct WatchedFileStat: Equatable {
    public let url: URL
    public let size: Int64
    public let mtime: Date
    public init(url: URL, size: Int64, mtime: Date) { self.url = url; self.size = size; self.mtime = mtime }
    /// Stable, cheap identity: path + size + mtime. Changes when the contents change
    /// (same file, new bytes → new key → transcribe again).
    public var dedupKey: String { "\(url.path)|\(size)|\(Int(mtime.timeIntervalSince1970))" }
}

/// Pure watching core: everything testable, no file system inside.
/// FSEvents/the timer only CALL these functions — they make no decisions themselves.
public enum FolderScan {
    /// From a folder snapshot, pick the files that: (a) aren't processed yet (no dedupKey in `processed`),
    /// (b) have «settled» — size+mtime matched the previous observation (`lastSeen`).
    /// Returns (ready to work on, new lastSeen for the next pass).
    public static func newStableFiles(
        current: [WatchedFileStat],
        lastSeen: [String: WatchedFileStat],   // key = path
        processed: Set<String>                 // dedupKey of already processed
    ) -> (ready: [WatchedFileStat], nextLastSeen: [String: WatchedFileStat]) {
        var ready: [WatchedFileStat] = []
        var next: [String: WatchedFileStat] = [:]
        for stat in current {
            next[stat.url.path] = stat
            if processed.contains(stat.dedupKey) { continue }     // already done
            if let prev = lastSeen[stat.url.path], prev == stat {
                ready.append(stat)                                // unchanged since last time → finished writing
            }
            // new OR changed → just remember it in next, wait for the next pass
        }
        return (ready.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }, next)
    }

    /// FIFO trimming of the processed set so it doesn't grow forever (old keys are dropped).
    public static func capProcessed(_ ordered: [String], max: Int) -> [String] {
        guard max >= 0, ordered.count > max else { return ordered }
        return Array(ordered.suffix(max))
    }
}

/// Store for the set of processed keys in ~/Library/Application Support/Parla/processed.json.
/// Mirrors HistoryStore (including the `var fileURL` test seam).
public enum ProcessedStore {
    /// `nonisolated(unsafe)`: same benign main-actor-only-write test seam as `HistoryStore.fileURL`.
    nonisolated(unsafe) static var fileURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parla", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("processed.json")
    }()

    public static func load() -> [String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }   // no file → empty, no crash
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    public static func save(_ keys: [String]) {
        guard let data = try? JSONEncoder().encode(keys) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Audio store for the player (feature 06)

/// Copies of the source audio next to the history: ~/Library/Application Support/Parla/audio/.
/// The folder is derived from `HistoryStore.fileURL` → automatically moves to a temporary path in tests.
public enum AudioStore {
    /// Formats AVAudioPlayer opens directly — they don't need an .m4a rendition.
    public static let directlyPlayable: Set<String> = ["m4a", "mp3", "wav", "aac", "caf", "aiff", "aif"]

    public static var folder: URL {
        HistoryStore.fileURL.deletingLastPathComponent().appendingPathComponent("audio", isDirectory: true)
    }
    private static func ensureFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Copy file name: "<uuid>.<ext>" (ext lowercased, or "bin"). Pure function.
    public static func fileName(for id: UUID, sourceExtension ext: String) -> String {
        let e = ext.lowercased()
        return e.isEmpty ? "\(id.uuidString).bin" : "\(id.uuidString).\(e)"
    }

    /// Best URL for playback: first the m4a rendition, then the copy of the original (if the file is there).
    public static func playableURL(for item: TranscriptItem) -> URL? {
        for name in [item.audioPlayable, item.audioFile].compactMap({ $0 }) {
            let u = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// Copies the source into the store. Returns the file name or nil (on error we don't fail the transcription).
    public static func copy(from src: URL, id: UUID) -> String? {
        ensureFolder()
        let name = fileName(for: id, sourceExtension: src.pathExtension)
        let dest = folder.appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: src, to: dest)
            return name
        } catch { return nil }
    }

    /// Makes a playback rendition of the source. Prefers a compact AAC .m4a; if the AAC encoder can't handle the
    /// source (seen on some webm), logs why and falls back to a plain PCM .wav (bigger, but AVAudioPlayer always
    /// opens it). Returns the rendition's file name, or nil if both fail. Best-effort — never touches the transcript.
    public static func makePlayable(from src: URL, id: UUID, using decoder: any AudioDecoding) -> String? {
        ensureFolder()
        let m4a = "\(id.uuidString).m4a"
        let m4aDest = folder.appendingPathComponent(m4a)
        do {
            if FileManager.default.fileExists(atPath: m4aDest.path) { try FileManager.default.removeItem(at: m4aDest) }
            try decoder.renderPlayableM4a(from: src, to: m4aDest)
            return m4a
        } catch {
            NSLog("Parla: AAC playback render failed for %@ — %@; trying a PCM WAV fallback", src.lastPathComponent, error.localizedDescription)
        }
        let wav = "\(id.uuidString).playable.wav"
        let wavDest = folder.appendingPathComponent(wav)
        do {
            if FileManager.default.fileExists(atPath: wavDest.path) { try FileManager.default.removeItem(at: wavDest) }
            try decoder.renderPlayableWav(from: src, to: wavDest)
            return wav
        } catch {
            NSLog("Parla: PCM WAV playback render also failed for %@ — %@", src.lastPathComponent, error.localizedDescription)
            return nil
        }
    }

    /// Delete a record's audio (the copy and the rendition).
    public static func remove(_ item: TranscriptItem) {
        for name in [item.audioFile, item.audioPlayable].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Wipe the entire audio cache (for the «Clear audio cache» button in settings).
    public static func clearAll() {
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return }
        for u in items { try? FileManager.default.removeItem(at: u) }
    }

    public static func totalBytes() -> Int64 { TranscriptionEngine.folderSize(at: folder) }

    /// Size of one record's audio files (copy + rendition). 0 if there are no files.
    public static func bytes(of item: TranscriptItem) -> Int64 {
        [item.audioFile, item.audioPlayable].compactMap { $0 }.reduce(Int64(0)) { $0 + fileSize($1) }
    }
    private static func fileSize(_ name: String) -> Int64 {
        let u = folder.appendingPathComponent(name)
        return Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Wipe orphan files: everything in audio/ not referenced by any record (catches leftovers from a crash
    /// between copy and save, an unfinished playback rendition). Doesn't touch the text — files only.
    public static func pruneOrphans(keeping history: [TranscriptItem]) {
        let referenced = Set(history.flatMap { [$0.audioFile, $0.audioPlayable].compactMap { $0 } })
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return }
        for f in files where !referenced.contains(f.lastPathComponent) {
            try? FileManager.default.removeItem(at: f)
        }
    }

    /// PURE LRU-eviction core: which records to strip of audio to fit within the cap.
    /// THE TEXT IS NOT TOUCHED — the caller only nulls out audioFile/audioPlayable and deletes those files.
    /// `history[0]` is the newest (insert at:0), so «old» = larger index → we go from the tail.
    /// `sizeOf` is injected (no FS in the core → deterministic and testable). `protected`
    /// (selected/playing + just added) is NEVER evicted — even if that slightly exceeds
    /// the cap (partial compliance is correct, we don't yank audio out from under the player).
    public static func enforceAudioCap(_ history: [TranscriptItem], capBytes: Int64,
                                sizeOf: (TranscriptItem) -> Int64,
                                protected: Set<UUID>) -> [UUID] {
        var total = history.reduce(Int64(0)) { $0 + sizeOf($1) }
        guard total > capBytes else { return [] }
        // If the protected entries ALONE bust the cap, no amount of eviction reaches it — and the loop below
        // would then walk off the end and strip every other note. One 1-hour import (source copy + rendered
        // .m4a) can pass the 500 MB default on its own, and `transcribe` has already selected it, so this is a
        // real user path, not a corner case. Protection is transient (it follows the displayed entry), so the
        // right move is to wait: the next pass, with that entry no longer selected, restores the cap normally.
        // Evicting here cannot achieve compliance and would permanently destroy the whole back catalogue's audio.
        let protectedBytes = history.filter { protected.contains($0.id) }.reduce(Int64(0)) { $0 + sizeOf($1) }
        guard protectedBytes <= capBytes else { return [] }
        var evict: [UUID] = []
        for item in history.reversed() {                 // from the tail (old) to the head (new)
            if total <= capBytes { break }
            let bytes = sizeOf(item)
            guard bytes > 0, !protected.contains(item.id) else { continue }   // no audio or protected
            evict.append(item.id)
            total -= bytes
        }
        return evict
    }

    /// Pure TOCTOU re-check: drop the now-protected (displayed/playing) id from an eviction plan.
    /// Applied AFTER the off-main pass, so the entry the user switched to mid-pass is never evicted.
    /// nil protection → plan unchanged. Invariant: the protected id is never in the result.
    public static func applyProtection(_ plan: [UUID], evicting protectedNow: UUID?) -> [UUID] {
        guard let p = protectedNow else { return plan }
        return plan.filter { $0 != p }
    }
}

/// Index of the segment whose [start, …) contains t (for highlighting the active segment during playback).
/// We take the last segment with `start <= t` — robust to gaps/overlaps in Whisper's output.
/// nil if t is before the first segment or there are no segments.
public func activeSegmentIndex(_ segments: [Segment], at t: Double) -> Int? {
    guard !segments.isEmpty else { return nil }
    var idx: Int? = nil
    for (i, s) in segments.enumerated() where s.start <= t + 0.0001 { idx = i }
    return idx
}
