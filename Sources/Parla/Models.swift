import Foundation

/// A single recognized fragment with a timecode.
struct Segment: Codable, Hashable {
    var start: Double
    var end: Double
    var text: String
}

/// A single transcript in the history.
struct TranscriptItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var date: Date = Date()
    var sourceName: String
    var language: String
    var durationSec: Double
    var model: String
    var text: String
    var segments: [Segment]
    var edited: Bool? = nil           // whether the text was edited manually (Optional — otherwise old history.json won't decode)
    var editedAt: Date? = nil         // when it was edited (nil for untouched / legacy records)
    var sourcePath: String? = nil     // absolute path to the source (for "re-transcribe"); nil on old/legacy
    var sourceBookmark: Data? = nil   // fallback locator bookmark; nil is fine (Optional → legacy-compatible)
    var audioFile: String? = nil      // name of the source copy in .../Parla/audio/ (for the player); nil on old records
    var audioPlayable: String? = nil  // name of the m4a rendition for playback (Opus/video); nil if not needed/not produced

    /// Convenience accessor: nil/false → not edited.
    var isEdited: Bool { edited == true }

    /// Text with or without timecodes — for display/copying.
    /// For edited records timecodes are suppressed: the edited text no longer matches
    /// the boundaries of the original segments, so we show flat text.
    func display(timestamps: Bool) -> String {
        guard timestamps, !isEdited, !segments.isEmpty else { return text }
        return segments
            .filter { !$0.text.isEmpty }
            .map { "[\(fmtTime($0.start))] \($0.text)" }
            .joined(separator: "\n")
    }

    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

// MARK: - Finding a record's source file (feature 01 «re-transcribe»)

/// Result of trying to find a record's source.
enum SourceResolution: Equatable {
    case found(URL, scoped: Bool)   // scoped == true → must call stopAccessing… afterwards (future-proofing, under sandbox)
    case missing
}

extension TranscriptItem {
    /// Tries to find the source file: first by absolute path, then by bookmark.
    /// Non-sandboxed build: the plain path is the primary mechanism, bookmark is the fallback locator.
    func resolveSource(fileManager fm: FileManager = .default) -> SourceResolution {
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
    var hasResolvableSource: Bool {
        if case .found(let url, let scoped) = resolveSource() {
            if scoped { url.stopAccessingSecurityScopedResource() }
            return true
        }
        return false
    }
}

/// Best-effort source bookmark when a record is created. Plain (not security-scoped) — good enough
/// as a fallback locator in a non-sandboxed build. We ignore errors: the primary mechanism is the path.
func makeSourceBookmark(_ url: URL) -> Data? {
    try? url.bookmarkData()
}

func fmtTime(_ s: Double) -> String {
    let t = max(0, Int(s.rounded()))
    return String(format: "%02d:%02d", t / 60, t % 60)
}

/// Normalized edit: strip CRLF and trailing whitespace/newlines.
/// An empty result doesn't overwrite the original. Returns (newText, changed).
func normalizedEdit(_ raw: String, from original: String) -> (text: String, changed: Bool) {
    let trimmed = raw.replacingOccurrences(of: "\r\n", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let new = trimmed.isEmpty ? original : trimmed   // don't let the whole text get wiped by accident
    return (new, new != original)
}

/// «openai_whisper-large-v3-v20240930_turbo_632MB» → «Large v3 v20240930 turbo 632MB».
func prettyModel(_ raw: String) -> String {
    var s = raw.replacingOccurrences(of: "openai_whisper-", with: "")
    s = s.replacingOccurrences(of: "_", with: " ")
    s = s.replacingOccurrences(of: "-", with: " ")
    guard let first = s.first else { return raw }
    return first.uppercased() + s.dropFirst()
}

/// Short friendly name of the variant for the chip/metadata.
func friendlyModel(_ raw: String) -> String {
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
struct ModelTier: Identifiable {
    let title: String
    let hint: String          // quality/speed only, no size
    let estimate: String      // approximate size before download, e.g. "~630 МБ" ("" — unknown)
    let name: String
    let recommended: Bool
    var id: String { name }
}

// MARK: - History: filter, export, size formatting

/// Search over the history (case-insensitive, by text and file name).
func filterHistory(_ items: [TranscriptItem], query: String) -> [TranscriptItem] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return items }
    return items.filter { $0.text.lowercased().contains(q) || $0.sourceName.lowercased().contains(q) }
}

/// The entire history as a single markdown text (for export/backup).
func exportText(_ items: [TranscriptItem]) -> String {
    var out = L("export.title")
    for it in items {
        out += "## \(it.sourceName)\n"
        let editedMark = it.isEdited ? " · " + L("transcript.edited") : ""
        out += "_\(it.date.formatted(date: .abbreviated, time: .shortened)) · \(it.language.uppercased()) · \(friendlyModel(it.model))\(editedMark)_\n\n"
        out += it.text + "\n\n---\n\n"
    }
    return out
}

func formatBytes(_ bytes: Int64) -> String {
    if bytes <= 0 { return "—" }
    let mb = Double(bytes) / 1_048_576
    if mb >= 1024 { return Lf("unit.gb.fmt", mb / 1024) }
    return Lf("unit.mb.fmt", mb)
}

/// Position in batch processing: «index out of total». Only for a folder drop / multiple files.
struct BatchProgress: Equatable {
    var index: Int     // 1-based: current file
    var total: Int     // total files in the job (>= 2; for a single file — nil instead of the struct)
    var done: Int      // completed before the current one (for the bottom bar): index-1
}

enum EnginePhase: Equatable {
    case idle
    case preparing(String, batch: BatchProgress? = nil)
    case downloadingModel(Double)   // 0...1, actual download (one time)
    case loadingModel               // loading into memory (fast, every launch)
    case transcribing(String, batch: BatchProgress? = nil)
    case failed(String)
}

/// «msg.ogg» (3 of 12)» for a batch, or just «msg.ogg» for a single file.
func batchLabel(_ name: String, _ b: BatchProgress?) -> String {
    guard let b, b.total > 1 else { return Lf("batch.label.single", name) }
    return Lf("batch.label.multi", name, b.index, b.total)
}

/// Russian pluralization (1 файл / 2 файла / 5 файлов).
func pluralRu(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let a = abs(n) % 100, b = a % 10
    if a > 10 && a < 20 { return many }
    if b == 1 { return one }
    if b >= 2 && b <= 4 { return few }
    return many
}

/// History store in ~/Library/Application Support/Parla/history.json
enum HistoryStore {
    /// Path to the history file in ~/Library/Application Support/Parla/.
    /// `var` (not `let`) is a test seam: tests swap the path for a temporary one so they don't touch
    /// the user's real history. In production the value never changes.
    static var fileURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parla", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("history.json")
    }()

    static func load() -> [TranscriptItem] {
        migrateLegacyIfNeeded()
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([TranscriptItem].self, from: data)) ?? []
    }

    /// One-time history migration from the old app name (Murmur → Parla).
    private static func migrateLegacyIfNeeded() {
        let legacy = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/history.json")
        migrate(target: fileURL, legacy: legacy)
    }

    /// Pure testable logic: copy legacy → target if target doesn't have a file yet.
    static func migrate(target: URL, legacy: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target.path), fm.fileExists(atPath: legacy.path) else { return }
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.copyItem(at: legacy, to: target)
    }

    static func save(_ items: [TranscriptItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Folder watching (feature 04)

/// File snapshot: for checking whether it's «finished writing» (size+mtime stable) and as a deduplication key.
struct WatchedFileStat: Equatable {
    let url: URL
    let size: Int64
    let mtime: Date
    /// Stable, cheap identity: path + size + mtime. Changes when the contents change
    /// (same file, new bytes → new key → transcribe again).
    var dedupKey: String { "\(url.path)|\(size)|\(Int(mtime.timeIntervalSince1970))" }
}

/// Pure watching core: everything testable, no file system inside.
/// FSEvents/the timer only CALL these functions — they make no decisions themselves.
enum FolderScan {
    /// From a folder snapshot, pick the files that: (a) aren't processed yet (no dedupKey in `processed`),
    /// (b) have «settled» — size+mtime matched the previous observation (`lastSeen`).
    /// Returns (ready to work on, new lastSeen for the next pass).
    static func newStableFiles(
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
    static func capProcessed(_ ordered: [String], max: Int) -> [String] {
        guard max >= 0, ordered.count > max else { return ordered }
        return Array(ordered.suffix(max))
    }
}

/// Store for the set of processed keys in ~/Library/Application Support/Parla/processed.json.
/// Mirrors HistoryStore (including the `var fileURL` test seam).
enum ProcessedStore {
    static var fileURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parla", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("processed.json")
    }()

    static func load() -> [String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }   // no file → empty, no crash
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func save(_ keys: [String]) {
        guard let data = try? JSONEncoder().encode(keys) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Audio store for the player (feature 06)

/// Copies of the source audio next to the history: ~/Library/Application Support/Parla/audio/.
/// The folder is derived from `HistoryStore.fileURL` → automatically moves to a temporary path in tests.
enum AudioStore {
    /// Formats AVAudioPlayer opens directly — they don't need an .m4a rendition.
    static let directlyPlayable: Set<String> = ["m4a", "mp3", "wav", "aac", "caf", "aiff", "aif"]

    static var folder: URL {
        HistoryStore.fileURL.deletingLastPathComponent().appendingPathComponent("audio", isDirectory: true)
    }
    private static func ensureFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Copy file name: "<uuid>.<ext>" (ext lowercased, or "bin"). Pure function.
    static func fileName(for id: UUID, sourceExtension ext: String) -> String {
        let e = ext.lowercased()
        return e.isEmpty ? "\(id.uuidString).bin" : "\(id.uuidString).\(e)"
    }

    /// Best URL for playback: first the m4a rendition, then the copy of the original (if the file is there).
    static func playableURL(for item: TranscriptItem) -> URL? {
        for name in [item.audioPlayable, item.audioFile].compactMap({ $0 }) {
            let u = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// Copies the source into the store. Returns the file name or nil (on error we don't fail the transcription).
    static func copy(from src: URL, id: UUID) -> String? {
        ensureFolder()
        let name = fileName(for: id, sourceExtension: src.pathExtension)
        let dest = folder.appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: src, to: dest)
            return name
        } catch { return nil }
    }

    /// Makes an m4a rendition of the source for playback. Returns the name or nil. Best-effort.
    static func makePlayable(from src: URL, id: UUID) -> String? {
        ensureFolder()
        let name = "\(id.uuidString).m4a"
        let dest = folder.appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try AudioConverter.toM4a(src, to: dest)
            return name
        } catch { return nil }
    }

    /// Delete a record's audio (the copy and the rendition).
    static func remove(_ item: TranscriptItem) {
        for name in [item.audioFile, item.audioPlayable].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Wipe the entire audio cache (for the «Clear audio cache» button in settings).
    static func clearAll() {
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return }
        for u in items { try? FileManager.default.removeItem(at: u) }
    }

    static func totalBytes() -> Int64 { TranscriptionEngine.folderSize(at: folder) }

    /// Size of one record's audio files (copy + rendition). 0 if there are no files.
    static func bytes(of item: TranscriptItem) -> Int64 {
        [item.audioFile, item.audioPlayable].compactMap { $0 }.reduce(Int64(0)) { $0 + fileSize($1) }
    }
    private static func fileSize(_ name: String) -> Int64 {
        let u = folder.appendingPathComponent(name)
        return Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Wipe orphan files: everything in audio/ not referenced by any record (catches leftovers from a crash
    /// between copy and save, an unfinished ffmpeg .m4a). Doesn't touch the text — files only.
    static func pruneOrphans(keeping history: [TranscriptItem]) {
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
    static func enforceAudioCap(_ history: [TranscriptItem], capBytes: Int64,
                                sizeOf: (TranscriptItem) -> Int64,
                                protected: Set<UUID>) -> [UUID] {
        var total = history.reduce(Int64(0)) { $0 + sizeOf($1) }
        guard total > capBytes else { return [] }
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
}

/// Index of the segment whose [start, …) contains t (for highlighting the active segment during playback).
/// We take the last segment with `start <= t` — robust to gaps/overlaps in Whisper's output.
/// nil if t is before the first segment or there are no segments.
func activeSegmentIndex(_ segments: [Segment], at t: Double) -> Int? {
    guard !segments.isEmpty else { return nil }
    var idx: Int? = nil
    for (i, s) in segments.enumerated() where s.start <= t + 0.0001 { idx = i }
    return idx
}
