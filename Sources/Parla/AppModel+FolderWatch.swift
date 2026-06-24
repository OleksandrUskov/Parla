import Foundation
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
        drainQueue()
    }

    /// Single-flight: run one at a time, only when the engine is free. Manual drop and watching
    /// share one «lane» via `isBusy` — they never overlap.
    private func drainQueue() {
        guard !isBusy, downloadingModel == nil, !watchQueue.isEmpty else { return }
        let next = watchQueue.removeFirst()
        watchQueueCount = watchQueue.count
        phase = .preparing(next.lastPathComponent)   // claim the phase synchronously → closes the double-start race
        Task {
            await transcribe(urls: [next])           // THE SAME path as manual drop
            if watchWriteSidecar { writeSidecar(for: next) }
            drainQueue()                             // pull the next one once we're free again
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

    private func writeSidecar(for src: URL) {
        guard let item = history.first(where: { $0.sourceName == src.lastPathComponent }) else { return }
        let txt = src.deletingPathExtension().appendingPathExtension("txt")
        try? Data(item.display(timestamps: showTimestamps).utf8).write(to: txt, options: .atomic)
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
