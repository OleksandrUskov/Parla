import Foundation

/// History: copy, inline edit (feature 02), delete, export to Markdown.
extension AppModel {
    public func copy(_ text: String) { copyToClipboard(text) }

    public func copyItem(_ item: TranscriptItem) {
        copy(item.display(timestamps: showTimestamps))
        lastCopiedID = item.id
        // «Copied» — brief highlight, then reset.
        let id = item.id
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if lastCopiedID == id { lastCopiedID = nil }
        }
    }

    /// Save the edited card text to history.
    /// Resolves the entry by `id` (not by a copy), stamps `edited`/`editedAt`, writes to disk.
    /// Returns true if the text actually changed (for UI feedback); a no-op edit → false.
    @discardableResult
    public func saveEdit(_ rawText: String, for id: TranscriptItem.ID) -> Bool {
        guard let idx = history.firstIndex(where: { $0.id == id }) else { return false }
        let (newText, changed) = normalizedEdit(rawText, from: history[idx].text)
        guard changed else { return false }   // nothing meaningfully changed → don't write or stamp
        history[idx].text = newText
        history[idx].edited = true
        history[idx].editedAt = Date()
        selection = id                        // keep the selection on the edited entry (before invalidating Related)
        invalidateDerivedData(for: id)        // drop stale vector/lemmas/insights from the OLD text + clear Related
        HistoryStore.save(history)
        // NOTE: saveEdit stays fully SYNCHRONOUS. The re-embed/re-lemmatize pass (refreshSemanticIndex) is kicked
        // by the CALLER (the editor's commit handler), NOT here — a fire-and-forget Task from a store mutation can
        // outlive a test's temp-store scope. Indexes are invalidated synchronously above (model already consistent).
        return true
    }

    public func delete(_ item: TranscriptItem) {
        AudioStore.remove(item)                 // drop the audio copy along with the entry
        Self.pruneImportedSource(item.sourcePath)  // …and the iOS import-container copy (no-op elsewhere)
        EmbeddingStore.remove([item.id])        // …and its semantic vector (no orphan in embeddings.json)
        embeddingIndex[item.id] = nil           // keep the in-memory mirrors in sync (doc↔doc related + search)
        lemmaIndex[item.id] = nil
        history.removeAll { $0.id == item.id }
        if selection == item.id { selection = nil }
        HistoryStore.save(history)
        refreshRelatedNotes()                   // the open note's "Related" may have referenced the deleted item
    }

    public func clearHistory() {
        history.forEach(AudioStore.remove)
        history.forEach { Self.pruneImportedSource($0.sourcePath) }   // …and the iOS import-container copies
        EmbeddingStore.pruneOrphans(keeping: [])   // wipe all vectors along with the history
        // …and the long-audio resume record, which holds the full TEXT of every completed chunk. It is not a
        // note, so nothing here reached it, and "All transcripts and their audio will be permanently deleted"
        // was therefore not true: half an hour of the user's speech could survive in cleartext beside a history
        // file they had just emptied.
        ChunkProgressStore.clear()
        embeddingIndex.removeAll()
        lemmaIndex.removeAll()
        history.removeAll()
        selection = nil
        relatedIDs = []
        HistoryStore.save(history)
    }

    /// Where iOS import copies live. A settable `var` — like `HistoryStore.fileURL` — because this directory is
    /// DELETED FROM: `pruneImportedOrphans` removes every unreferenced subdirectory in it. Without a redirect the
    /// prune tests created their fixtures in the user's REAL container and swept it with `keeping: []`, which is
    /// safe only for as long as macOS never puts anything there. This project has already had a test clobber real
    /// user data once; a destructive path with no injectable root is the same shape waiting to happen again.
    /// `nonisolated(unsafe)`: a test seam, written only in `setUp`.
    nonisolated(unsafe) public static var importsRoot: URL = defaultImportsRoot()

    /// The production location — kept separate so a test can assert it while `importsRoot` itself is redirected.
    public nonisolated static func defaultImportsRoot() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return StorageRoot.defaultURL().appendingPathComponent("imports", isDirectory: true)
    }

    /// Remove an iOS import-container copy (`Application Support/Parla/imports/<uuid>/<name>`) when its note is
    /// deleted. The iOS import funnel keeps that copy as the note's `sourcePath` for re-transcribe, so without
    /// this it leaks forever (unbounded disk growth on device). A no-op for any source OUTSIDE that dir (macOS
    /// originals, AV-native drops) — the prefix guard makes it cross-platform-safe.
    nonisolated static func pruneImportedSource(_ sourcePath: String?) {
        guard let sourcePath else { return }
        let fm = FileManager.default
        let importsRoot = Self.importsRoot.path + "/"
        let dir = (sourcePath as NSString).deletingLastPathComponent   // the per-import <uuid> dir
        guard (dir + "/").hasPrefix(importsRoot) else { return }        // only Parla-managed imports
        try? fm.removeItem(atPath: dir)
    }

    /// Sweep abandoned iOS import copies: remove every `imports/<uuid>/` dir NOT referenced by a saved note's
    /// sourcePath. A failed transcription keeps its copy so «Try again» works, a crash between copy and save leaves
    /// one, a cancelled queued job drops one — none of which delete()/clearHistory ever reach. Call at LAUNCH
    /// (`AppModel.iOS()`), where nothing is in-flight/queued and `lastAttemptedURLs` is empty, so it's race-free and
    /// never removes a copy still in use. A no-op on macOS (no imports/ dir). Mirrors AudioStore.pruneOrphans.
    /// `age` is a GRACE PERIOD, and it is load-bearing: "unreferenced" does not mean "unwanted". A drop that hits
    /// a Pro gate (batch, or the free length cap) produces no note, so its container copy is unreferenced — while
    /// being the user's ONLY remaining copy, since `ShareInbox.drain` has already cleared the share inbox. Without
    /// a grace period the next launch deleted it, so two voice notes shared from Telegram by a free user were
    /// paywalled and then destroyed, and buying Pro afterwards could not bring them back. In-session retry works
    /// off `lastAttemptedURLs`, but that is memory only — this is what survives a relaunch.
    /// The cost is that a genuinely dead copy (crash between copy and save) lingers for a week. That is the right
    /// side to err on: the bytes are the user's own audio.
    public nonisolated static func pruneImportedOrphans(keeping history: [TranscriptItem],
                                                        olderThan age: TimeInterval = 604_800,
                                                        now: Date = Date()) {
        let fm = FileManager.default
        let root = importsRoot
        guard let dirs = try? fm.contentsOfDirectory(at: root,
                                                     includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        // Referenced <uuid> dir names (each sourcePath is imports/<uuid>/<name>).
        let referenced = Set(history.compactMap { $0.sourcePath.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent
        } })
        for dir in dirs where !referenced.contains(dir.lastPathComponent) {
            // Unreadable timestamp → KEEP. Deleting on "I can't tell how old this is" is the destructive guess.
            guard let mtime = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(mtime) > age else { continue }
            try? fm.removeItem(at: dir)
        }
    }

    /// Export the entire history to a markdown file (save dialog). The picker is the `presentSavePanel`
    /// platform seam (macOS: NSSavePanel); the render + write + error handling stay here in Core.
    public func exportHistory() {
        guard !history.isEmpty else { return }
        guard let url = presentSavePanel("parla-history.md", ["md"]) else { return }
        do {
            try Data(exportText(history, content: exportContent).utf8).write(to: url)
        } catch {
            phase = .failed(Lf("error.save.failed", error.localizedDescription))
        }
    }

    /// Export ONE transcript in the chosen format (save dialog). The format rendering is the pure
    /// `Export.swift` layer; this just runs the picker seam + writes, reusing `exportHistory`'s error path.
    public func export(_ item: TranscriptItem, as format: ExportFormat) {
        let base = (item.sourceName as NSString).deletingPathExtension
        guard let url = presentSavePanel("\(base).\(format.fileExtension)", [format.fileExtension]) else { return }
        do {
            let data = format == .json
                ? try exportJSON(item)
                : Data(exportString(item, as: format, timestamps: showTimestamps, content: exportContent).utf8)
            try data.write(to: url)
        } catch {
            phase = .failed(Lf("error.save.failed", error.localizedDescription))
        }
    }
}
