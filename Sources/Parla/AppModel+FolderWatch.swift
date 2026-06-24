import Foundation
import AppKit

/// Слежение за папкой (фича 04): FSEvents → отбор устаканившихся новых файлов → single-flight
/// очередь, делящая «полосу» с ручным дропом через `isBusy`.
extension AppModel {
    /// Возобновить слежение на старте (зовётся из ParlaApp). Резолвит сохранённую папку.
    func startWatchingIfEnabled() {
        watchedFolderURL = resolveBookmarkedFolder()
        if watchEnabled { startWatching() }
    }

    /// Выбрать папку через системный диалог и запомнить её (bookmark переживает перезапуск).
    func pickWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("folder.choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Обычный bookmark: приложение не в песочнице. При будущей сэндбоксации (App Store)
        // заменить на .withSecurityScope + start/stopAccessingSecurityScopedResource.
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
        watcher?.stop()   // защита: никогда не теряем старый watcher без stop() (его поток держит +1 на себя)
        watchedFolderURL = folder
        // ПОЛИТИКА «только новые»: фиксируем текущее содержимое как уже-виденное, в очередь НЕ ставим.
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

    /// FSEvents/таймер дёрнул нас: перечитать папку, отобрать устаканившиеся новые файлы → в очередь.
    private func handleFolderChange() {
        guard let folder = watchedFolderURL else { return }
        let current = Self.scanFolder(folder, recursive: watchRecursive)
        let (ready, next) = FolderScan.newStableFiles(current: current, lastSeen: lastSeen, processed: processedSet)
        lastSeen = next
        for stat in ready where !watchQueue.contains(stat.url) {
            watchQueue.append(stat.url)
            markProcessed(stat.dedupKey)     // помечаем СРАЗУ при постановке → нет повторов и нет вечного ретрая
        }
        watchQueueCount = watchQueue.count
        drainQueue()
    }

    /// Single-flight: запускаем по одному, только когда движок свободен. Манульный дроп и слежение
    /// делят одну «полосу» через `isBusy` — никогда не пересекаются.
    private func drainQueue() {
        guard !isBusy, downloadingModel == nil, !watchQueue.isEmpty else { return }
        let next = watchQueue.removeFirst()
        watchQueueCount = watchQueue.count
        phase = .preparing(next.lastPathComponent)   // синхронно занимаем фазу → закрываем гонку двойного запуска
        Task {
            await transcribe(urls: [next])           // ТОТ ЖЕ путь, что у ручного дропа
            if watchWriteSidecar { writeSidecar(for: next) }
            drainQueue()                             // тянем следующий, когда снова свободны
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

    /// Снимок папки: аудиофайлы + их size/mtime. `nonisolated` — тяжёлый walk можно звать вне main.
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
