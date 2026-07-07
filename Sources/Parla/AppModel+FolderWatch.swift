import Foundation
import ParlaCore
import AppKit

/// Folder watching (feature 04): FSEvents → pick out settled new files → single-flight
/// queue that shares a «lane» with manual drop via `isBusy`.
extension AppModel {
    /// Resume watching on launch (called from ParlaApp). Resolves the saved folder.
    func startWatchingIfEnabled() {
        watchedFolderURL = resolveBookmarkedFolder()
        if watchEnabled { startWatching() }
    }

    /// Pick a folder via the system dialog and remember it (the bookmark survives restarts).
    func pickWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("folder.choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Plain bookmark: the app isn't sandboxed. If we sandbox later (App Store),
        // switch to .withSecurityScope + start/stopAccessingSecurityScopedResource.
        if let data = try? url.bookmarkData() {
            UserDefaults.standard.set(data, forKey: Keys.watchBookmark)
        }
        watchedFolderURL = url
        if watchEnabled { restartWatching() }
    }

    private func resolveBookmarkedFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Keys.watchBookmark) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
    }

    func applyWatchToggle() { watchEnabled ? startWatching() : stopWatching() }
    func restartWatching() { stopWatching(); startWatching() }

    /// Re-apply the current watch config after a settings change (wired to `AppModel.syncWatch`). Enabled →
    /// restart (stop→start, which CLEARS the stale watch queue + re-scans under the new recursive setting);
    /// disabled → stop. Preserves the pre-extraction didSet semantics (watchRecursive change cleared the queue).
    func reapplyWatch() { watchEnabled ? restartWatching() : stopWatching() }

    private func startWatching() {
        guard let folder = watchedFolderURL ?? resolveBookmarkedFolder() else { return }
        watcher?.stop()   // safety: never drop the old watcher without stop() (its thread holds a +1 on itself)
        watchedFolderURL = folder
        // «NEW ONLY» POLICY: record the current contents as already-seen, do NOT enqueue them.
        let now = Self.scanFolder(folder, recursive: watchRecursive)
        lastSeen = Dictionary(now.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        let w = FolderWatcher(folder: folder, recursive: watchRecursive) { [weak self] in
            self?.handleFolderChange()
        }
        watcher = w
        w.start()
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
        watchQueue.removeAll()
        watchQueueCount = 0
    }

    /// FSEvents/timer poked us: re-read the folder, pick out settled new files → enqueue them.
    private func handleFolderChange() {
        guard let folder = watchedFolderURL else { return }
        let current = Self.scanFolder(folder, recursive: watchRecursive)
        let (ready, next) = FolderScan.newStableFiles(current: current, lastSeen: lastSeen, processed: processedSet)
        lastSeen = next
        for stat in ready where !watchQueue.contains(stat.url) {
            watchQueue.append(stat.url)
            markProcessed(stat.dedupKey)     // mark RIGHT on enqueue → no duplicates and no endless retry
        }
        watchQueueCount = watchQueue.count
        pumpQueues()
    }

    /// Single-flight: run one at a time, only when the engine is free. Manual drop and watching
    /// share one «lane» via `isBusy` — they never overlap. (Internal: also re-pumped by +Dictation
    /// after a dictation releases the lane.)
    func drainQueue() {
        guard !isBusy, downloadingModel == nil, !watchQueue.isEmpty else { return }
        let next = watchQueue.removeFirst()
        watchQueueCount = watchQueue.count
        phase = .preparing(next.lastPathComponent)   // claim the phase synchronously → closes the double-start race
        Task {
            await transcribe(urls: [next], isWatcherRun: true)   // THE SAME path as manual drop; coalesce the beep
            if watchWriteSidecar { writeSidecar(for: next) }
            pumpQueues()                             // pull the next one (manual first, then watch) once free
        }
    }

    private func markProcessed(_ key: String) {
        guard !processedSet.contains(key) else { return }
        processedSet.insert(key)
        processedKeys.append(key)
        let capped = FolderScan.capProcessed(processedKeys, max: 2000)
        if capped.count != processedKeys.count {
            processedKeys = capped
            processedSet = Set(capped)
        }
        ProcessedStore.save(processedKeys)
    }

    /// Find the record produced for `url` by its UNIQUE absolute path, not its (non-unique across
    /// subfolders) filename — so recursive watch can't write the wrong record's text to a .txt.
    nonisolated static func sidecarTarget(in history: [TranscriptItem], for url: URL) -> TranscriptItem? {
        history.first { $0.sourcePath == url.path }
    }

    /// Sidecar path for a transcribed file: the FULL source name + ".txt" (voice.ogg → voice.ogg.txt).
    /// Keeping the audio extension means two same-basename files (voice.ogg + voice.opus) get DISTINCT
    /// sidecars instead of both clobbering one voice.txt, and a transcript can't land on a user's own
    /// hand-written "voice.txt".
    nonisolated static func sidecarURL(for src: URL) -> URL { src.appendingPathExtension("txt") }

    /// What to write for a sidecar — or nil to skip. Pure (testable). NEVER clobber a file Parla
    /// didn't create: a pre-existing file at the path is the user's, so skip. Folder-watch writes each
    /// file's sidecar once (the dedup set gates re-processing), so skip-if-exists loses nothing of ours.
    nonisolated static func sidecarPlan(text: String, targetExists: Bool) -> Data? {
        targetExists ? nil : Data(text.utf8)
    }

    private func writeSidecar(for src: URL) {
        guard let item = Self.sidecarTarget(in: history, for: src) else { return }
        let txt = Self.sidecarURL(for: src)
        let exists = FileManager.default.fileExists(atPath: txt.path)
        guard let data = Self.sidecarPlan(text: item.display(timestamps: showTimestamps), targetExists: exists)
        else { return }
        try? data.write(to: txt, options: .atomic)
    }

    /// Folder snapshot: audio files + their size/mtime. `nonisolated` — the heavy walk can run off main.
    nonisolated static func scanFolder(_ dir: URL, recursive: Bool) -> [WatchedFileStat] {
        let fm = FileManager.default
        let opts: FileManager.DirectoryEnumerationOptions = recursive ? [] : [.skipsSubdirectoryDescendants]
        guard let en = fm.enumerator(at: dir,
                                     includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                     options: opts) else { return [] }
        return en.compactMap { $0 as? URL }
            .filter { audioExts.contains($0.pathExtension.lowercased()) }
            .compactMap { url in
                let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard let size = v?.fileSize, let mtime = v?.contentModificationDate else { return nil }
                return WatchedFileStat(url: url, size: Int64(size), mtime: mtime)
            }
    }
}
