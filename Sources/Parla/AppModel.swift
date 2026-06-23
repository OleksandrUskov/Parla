import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WhisperKit

@MainActor
@Observable
final class AppModel {
    var phase: EnginePhase = .idle
    var history: [TranscriptItem] = HistoryStore.load()
    var selection: TranscriptItem.ID?
    var availableModels: [String] = []
    var lastCopiedID: TranscriptItem.ID?
    var downloadingModel: String?
    var downloadProgress: Double = 0
    var searchQuery: String = ""
    var downloadedSet: Set<String> = []        // какие модели на диске (реактивно)
    var modelSizes: [String: Int64] = [:]      // размер каждой скачанной модели

    // Настройки (зеркалятся в UserDefaults).
    var selectedModel: String { didSet { UserDefaults.standard.set(selectedModel, forKey: Keys.model) } }
    var language: String { didSet { UserDefaults.standard.set(language, forKey: Keys.language) } }
    var autoCopy: Bool { didSet { UserDefaults.standard.set(autoCopy, forKey: Keys.autoCopy) } }
    var showTimestamps: Bool { didSet { UserDefaults.standard.set(showTimestamps, forKey: Keys.timestamps) } }
    var translateToEnglish: Bool { didSet { UserDefaults.standard.set(translateToEnglish, forKey: Keys.translate) } }

    // Слежение за папкой (фича 04) — тот же didSet-паттерн зеркалирования в UserDefaults.
    var watchEnabled: Bool      { didSet { UserDefaults.standard.set(watchEnabled, forKey: Keys.watchEnabled); applyWatchToggle() } }
    var watchRecursive: Bool    { didSet { UserDefaults.standard.set(watchRecursive, forKey: Keys.watchRecursive); if watchEnabled { restartWatching() } } }
    var watchWriteSidecar: Bool { didSet { UserDefaults.standard.set(watchWriteSidecar, forKey: Keys.watchSidecar) } }
    var globalHotkeyEnabled: Bool { didSet { UserDefaults.standard.set(globalHotkeyEnabled, forKey: Keys.hotkey) } }

    private var quickModeRun = false   // запуск инициирован хоткеем/меню-баром → показать тост по завершении

    var watchedFolderURL: URL?          // резолвится из bookmark — для отображения пути
    var watchQueueCount: Int = 0        // сколько файлов ждут в очереди (для статус-чипа)

    // Приватное состояние слежения/очереди.
    private var watcher: FolderWatcher?
    private var watchQueue: [URL] = []                          // ждут транскрибации (single-flight)
    private var lastSeen: [String: WatchedFileStat] = [:]       // снимок прошлого прохода (стабильность)
    private var processedKeys: [String] = []                   // FIFO-порядок обработанных dedupKey
    private var processedSet: Set<String> = []                 // = Set(processedKeys), для O(1) проверки

    private let engine = TranscriptionEngine()

    private enum Keys {
        static let model = "model"
        static let language = "language"
        static let autoCopy = "autoCopy"
        static let timestamps = "timestamps"
        static let translate = "translateToEnglish"
        static let watchEnabled = "watchEnabled"
        static let watchRecursive = "watchRecursive"
        static let watchSidecar = "watchWriteSidecar"
        static let watchBookmark = "watchBookmark"
        static let hotkey = "globalHotkeyEnabled"
        static let lastBookmark = "lastSourceBookmark"
    }

    init() {
        let d = UserDefaults.standard
        selectedModel = d.string(forKey: Keys.model) ?? "openai_whisper-large-v3-v20240930"
        language = d.string(forKey: Keys.language) ?? ""
        autoCopy = (d.object(forKey: Keys.autoCopy) as? Bool) ?? true
        showTimestamps = d.bool(forKey: Keys.timestamps)
        translateToEnglish = d.bool(forKey: Keys.translate)
        watchEnabled = d.bool(forKey: Keys.watchEnabled)
        watchRecursive = (d.object(forKey: Keys.watchRecursive) as? Bool) ?? true   // подпапки по умолчанию вкл.
        watchWriteSidecar = d.bool(forKey: Keys.watchSidecar)
        globalHotkeyEnabled = d.bool(forKey: Keys.hotkey)   // opt-in, по умолчанию выкл.
        processedKeys = ProcessedStore.load()
        processedSet = Set(processedKeys)
        availableModels = [
            "openai_whisper-tiny", "openai_whisper-base", "openai_whisper-small",
            "openai_whisper-large-v3", "openai_whisper-large-v3-v20240930",
            "openai_whisper-large-v3-v20240930_turbo_632MB",
        ]
        if !availableModels.contains(selectedModel) { availableModels.insert(selectedModel, at: 0) }
        refreshDownloaded()
    }

    var isBusy: Bool {
        switch phase { case .idle, .failed: return false; default: return true }
    }

    /// Элемент для правой панели — из ВИДИМОГО (отфильтрованного) списка, чтобы панель и
    /// сайдбар не расходились при активном поиске.
    var selectedItem: TranscriptItem? {
        if let id = selection, let found = filteredHistory.first(where: { $0.id == id }) { return found }
        return filteredHistory.first
    }

    var filteredHistory: [TranscriptItem] { filterHistory(history, query: searchQuery) }

    // MARK: Модели — статус/размер на диске

    func isDownloaded(_ model: String) -> Bool { downloadedSet.contains(model) }
    var totalModelsBytes: Int64 { modelSizes.values.reduce(0, +) }

    /// Дешёвая проверка наличия — на главном потоке; тяжёлый подсчёт размеров — в фоне.
    func refreshDownloaded() {
        let models = Set(availableModels + [selectedModel])
        var set = Set<String>()
        for m in models where TranscriptionEngine.isDownloaded(m) { set.insert(m) }
        downloadedSet = set
        let toSize = set
        Task {   // @MainActor-задача; тяжёлый walk считаем в detached и присваиваем на main
            let sizes = await Task.detached { () -> [String: Int64] in
                var s: [String: Int64] = [:]
                for m in toSize { s[m] = TranscriptionEngine.modelSize(m) }
                return s
            }.value
            self.modelSizes = sizes
        }
    }

    func refreshModels() async {
        let support = await WhisperKit.recommendedRemoteModels()
        let models = support.supported.sorted()
        guard !models.isEmpty else { return }
        availableModels = models
        // Не перебиваем выбор пользователя, если модель уже скачана (даже если её нет в рекомендованных).
        if !models.contains(selectedModel), !TranscriptionEngine.isDownloaded(selectedModel) {
            selectedModel = Self.bestDefault(from: models)
        }
        refreshDownloaded()
    }

    func downloadModel(_ name: String) async {
        guard !isBusy, downloadingModel == nil, !isDownloaded(name) else { return }
        downloadingModel = name
        downloadProgress = 0
        do {
            _ = try await WhisperKit.download(variant: name, progressCallback: { [weak self] p in
                Task { @MainActor in self?.downloadProgress = p.fractionCompleted }
            })
        } catch {
            phase = .failed("Не удалось скачать модель: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
        downloadingModel = nil
        refreshDownloaded()
    }

    func deleteModel(_ name: String) async {
        guard !isBusy, downloadingModel == nil else { return }
        do {
            try await engine.deleteModel(name)
            refreshDownloaded()
        } catch {
            phase = .failed("Не удалось удалить модель: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
    }

    /// Чистый список из 5 уровней (по одному варианту на уровень), без квантованных клонов.
    var modelTiers: [ModelTier] {
        func pick(_ cands: [String]) -> String? {
            cands.first(where: { availableModels.contains($0) })
                ?? cands.first(where: { c in availableModels.contains(where: { $0.hasPrefix(c) }) })
        }
        var tiers: [ModelTier] = []
        func add(_ title: String, _ hint: String, _ estimate: String, _ cands: [String], rec: Bool = false) {
            if let n = pick(cands) {
                tiers.append(ModelTier(title: title, hint: hint, estimate: estimate, name: n, recommended: rec))
            }
        }
        add("Tiny", "очень быстро · черновик", "~75 МБ", ["openai_whisper-tiny"])
        add("Base", "быстро · базовое качество", "~150 МБ", ["openai_whisper-base"])
        add("Small", "баланс скорость / точность", "~500 МБ", ["openai_whisper-small"])
        add("Large v3 turbo", "быстро, почти максимум · топ для ru/uk", "~630 МБ",
            ["openai_whisper-large-v3-v20240930_626MB",
             "openai_whisper-large-v3-v20240930",
             "openai_whisper-large-v3-v20240930_turbo_632MB",
             "openai_whisper-large-v3-v20240930_turbo"], rec: true)
        add("Large v3", "максимум точности · медленнее", "~1 ГБ",
            ["openai_whisper-large-v3", "openai_whisper-large-v3_947MB"])
        if !tiers.contains(where: { $0.name == selectedModel }) {
            tiers.append(ModelTier(title: friendlyModel(selectedModel), hint: "текущая выбранная",
                                   estimate: "", name: selectedModel, recommended: false))
        }
        return tiers
    }

    // MARK: Транскрибация

    func handleDrop(urls: [URL]) {
        guard !isBusy, downloadingModel == nil else { return }
        phase = .preparing("…")   // синхронно занимаем фазу — закрываем гонку двойного дропа
        Task { await transcribe(urls: urls) }
    }

    func transcribe(urls: [URL]) async {
        var files: [URL] = []
        for url in urls {
            if url.hasDirectoryPath { files.append(contentsOf: Self.audioFiles(in: url)) }
            else { files.append(url) }
        }
        guard !files.isEmpty else {
            phase = .failed("Не нашёл аудиофайлов")
            return
        }
        let total = files.count
        let jobStart = Date()
        var failures: [String] = []
        var succeeded = 0
        for (i, url) in files.enumerated() {
            // Позицию в очереди показываем только для батча (>1 файла); одиночный дроп выглядит как раньше.
            let batch = total > 1 ? BatchProgress(index: i + 1, total: total, done: i) : nil
            do {
                let r = try await transcribeOne(url: url, model: selectedModel, batch: batch)
                var item = TranscriptItem(
                    sourceName: url.lastPathComponent,
                    language: r.language,
                    durationSec: r.duration,
                    model: selectedModel,
                    text: r.text.isEmpty ? "(тишина — ничего не распознано)" : r.text,
                    segments: r.segments,
                    sourcePath: url.path,                       // запоминаем исходник для «перераспознать»
                    sourceBookmark: makeSourceBookmark(url)
                )
                // Сохраняем исходник для плеера (off-main, best-effort; ошибка не валит результат).
                let kept = await Self.keepAudio(from: url, id: item.id)
                item.audioFile = kept.file
                item.audioPlayable = kept.playable
                history.insert(item, at: 0)
                selection = item.id
                HistoryStore.save(history)
                if autoCopy, !r.text.isEmpty { copy(item.text) }
                succeeded += 1
                rememberSource(url)            // для «повторить последний файл»
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                failures.append("\(url.lastPathComponent) (\(msg))")
            }
        }
        refreshDownloaded()
        phase = failures.isEmpty ? .idle : .failed("Не удалось: \(failures.joined(separator: "; "))")

        // Уведомление: только если задание «стоило ожидания» и окно не на переднем плане.
        // Frontmost читаем в КОНЦЕ — переключение во время батча как раз и должно уведомить.
        let elapsed = Date().timeIntervalSince(jobStart)
        if BatchNotifier.shouldNotify(total: total, elapsed: elapsed, frontmost: NSApp.isActive) {
            await BatchNotifier.post(succeeded: succeeded, failed: failures.count)
        }

        // Тост для быстрого режима (хоткей/меню-бар) — у пользователя нет открытого окна с чипом.
        if quickModeRun {
            quickModeRun = false
            if !failures.isEmpty {
                QuickToast.shared.show("Не удалось распознать")
            } else {
                QuickToast.shared.show(autoCopy ? "Готово · скопировано в буфер" : "Готово")
            }
        }
    }

    /// Один файл → EngineResult: конвертация → загрузка модели (со скачиванием при надобности) →
    /// распознавание. Фазы выставляет сам (с учётом позиции в батче). Бросает на ошибке.
    /// Общий путь для свежего дропа и «перераспознать».
    private func transcribeOne(url: URL, model: String, batch: BatchProgress? = nil) async throws -> EngineResult {
        phase = .preparing(url.lastPathComponent, batch: batch)
        let wav = try await Task.detached(priority: .userInitiated) {
            try AudioConverter.toWav16k(url)
        }.value
        defer { try? FileManager.default.removeItem(at: wav) }

        phase = .loadingModel
        try await engine.ensureLoaded(model: model, progress: progressHandler())

        phase = .transcribing(url.lastPathComponent, batch: batch)
        let lang = language.isEmpty ? nil : language
        return try await engine.transcribe(wavPath: wav.path, language: lang,
                                           model: model, translate: translateToEnglish)
    }

    // MARK: Перераспознать (фича 01)

    /// Можно ли перераспознать запись: движок свободен и исходник доступен.
    func canRetranscribe(_ item: TranscriptItem) -> Bool {
        !isBusy && downloadingModel == nil && item.hasResolvableSource
    }

    /// Перезапустить запись на другой модели, заменив её содержимое НА МЕСТЕ (тот же id/позиция).
    func retranscribe(_ item: TranscriptItem, with model: String) {
        guard !isBusy, downloadingModel == nil else { return }
        guard model != item.model else { return }            // та же модель — пересчитывать нечего
        phase = .preparing(item.sourceName)                   // синхронно занимаем фазу — закрываем гонку (как handleDrop)
        Task { await runRetranscribe(item, with: model) }
    }

    private func runRetranscribe(_ item: TranscriptItem, with model: String) async {
        // Резолвим исходник ВНУТРИ задачи: файл мог исчезнуть между открытием меню и подтверждением.
        switch item.resolveSource() {
        case .missing:
            phase = .failed("Файл-источник «\(item.sourceName)» не найден — перетащи его заново")
        case .found(let url, let scoped):
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let r = try await transcribeOne(url: url, model: model)
                if let idx = history.firstIndex(where: { $0.id == item.id }) {
                    var updated = history[idx]
                    updated.language    = r.language
                    updated.durationSec = r.duration
                    updated.model       = model
                    updated.text        = r.text.isEmpty ? "(тишина — ничего не распознано)" : r.text
                    updated.segments    = r.segments
                    updated.date        = Date()
                    updated.edited      = nil   // свежее распознавание → сбрасываем флаг ручной правки (таймкоды снова валидны)
                    updated.editedAt    = nil
                    history[idx] = updated      // замена НА МЕСТЕ: id/позиция/sourcePath сохранены
                    selection = updated.id
                    HistoryStore.save(history)
                    if autoCopy, !r.text.isEmpty { copy(updated.text) }
                }
                phase = .idle
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                phase = .failed("Не удалось перераспознать: \(msg)")
            }
        }
        refreshDownloaded()   // целевая модель могла только что скачаться
    }

    private func progressHandler() -> @Sendable (ModelLoad) -> Void {
        { [weak self] load in
            Task { @MainActor in
                guard let self else { return }
                switch load {
                case .downloading(let p): self.phase = .downloadingModel(p)
                case .loading: self.phase = .loadingModel
                }
            }
        }
    }

    // MARK: Слежение за папкой (фича 04)

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
        panel.prompt = "Выбрать"
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

    private func applyWatchToggle() { watchEnabled ? startWatching() : stopWatching() }
    private func restartWatching() { stopWatching(); startWatching() }

    private func startWatching() {
        guard let folder = watchedFolderURL ?? resolveBookmarkedFolder() else { return }
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

    // MARK: Быстрая расшифровка — хоткей / меню-бар (фича 03)

    /// Триггер из хоткея или кнопки «Распознать из буфера»: берём аудиофайл из буфера и запускаем.
    func quickTranscribeFromClipboard() {
        guard !isBusy, downloadingModel == nil else {
            QuickToast.shared.show("Подожди — идёт другая задача")
            return
        }
        let urls = PasteboardReader.audioOnly(PasteboardReader.fileURLs())
        guard let first = urls.first else {
            QuickToast.shared.show("В буфере нет аудиофайла")
            return
        }
        quickModeRun = true
        QuickToast.shared.show("Распознаю «\(first.lastPathComponent)»…", sticky: true)
        handleDrop(urls: urls)   // существующий вход; гонку двойного запуска он уже закрывает
    }

    /// Повторить последний файл (если он ещё на диске).
    func transcribeLast() {
        guard !isBusy, downloadingModel == nil else { return }
        guard let url = resolveLastSource() else {
            QuickToast.shared.show("Последний файл недоступен")
            return
        }
        quickModeRun = true
        QuickToast.shared.show("Повторяю «\(url.lastPathComponent)»…", sticky: true)
        handleDrop(urls: [url])
    }

    private func rememberSource(_ url: URL) {
        if let data = try? url.bookmarkData() {   // обычный bookmark (приложение не в песочнице)
            UserDefaults.standard.set(data, forKey: Keys.lastBookmark)
        }
    }

    private func resolveLastSource() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Keys.lastBookmark) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: История

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyItem(_ item: TranscriptItem) {
        copy(item.display(timestamps: showTimestamps))
        lastCopiedID = item.id
        // «Скопировано» — кратковременная подсветка, сбрасываем.
        let id = item.id
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if lastCopiedID == id { lastCopiedID = nil }
        }
    }

    /// Сохранить отредактированный текст карточки в историю.
    /// Резолвит запись по `id` (а не по копии), штампует `edited`/`editedAt`, пишет на диск.
    /// Возвращает true, если текст реально изменился (для UI-фидбэка); no-op правка → false.
    @discardableResult
    func saveEdit(_ rawText: String, for id: TranscriptItem.ID) -> Bool {
        guard let idx = history.firstIndex(where: { $0.id == id }) else { return false }
        let (newText, changed) = normalizedEdit(rawText, from: history[idx].text)
        guard changed else { return false }   // ничего по сути не поменялось → не пишем и не штампуем
        history[idx].text = newText
        history[idx].edited = true
        history[idx].editedAt = Date()
        HistoryStore.save(history)
        selection = id                        // держим выделение на отредактированной записи
        return true
    }

    /// Скопировать исходник + при необходимости отрендерить m4a — в фоне. Best-effort.
    nonisolated static func keepAudio(from url: URL, id: UUID) async -> (file: String?, playable: String?) {
        await Task.detached(priority: .utility) {
            let file = AudioStore.copy(from: url, id: id)
            let needsRender = !AudioStore.directlyPlayable.contains(url.pathExtension.lowercased())
            let playable = needsRender ? AudioStore.makePlayable(from: url, id: id) : nil
            return (file, playable)
        }.value
    }

    func delete(_ item: TranscriptItem) {
        AudioStore.remove(item)                 // снести копию аудио вместе с записью
        history.removeAll { $0.id == item.id }
        if selection == item.id { selection = nil }
        HistoryStore.save(history)
    }

    func clearHistory() {
        history.forEach(AudioStore.remove)
        history.removeAll()
        selection = nil
        HistoryStore.save(history)
    }

    /// Очистить кэш аудио (кнопка в настройках): снести файлы и обнулить ссылки в истории.
    func clearAudioCache() {
        AudioStore.clearAll()
        for i in history.indices {
            history[i].audioFile = nil
            history[i].audioPlayable = nil
        }
        HistoryStore.save(history)
    }

    /// Экспорт всей истории в markdown-файл (диалог сохранения).
    func exportHistory() {
        guard !history.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "parla-history.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(exportText(history).utf8).write(to: url)
        } catch {
            phase = .failed("Не удалось сохранить файл: \(error.localizedDescription)")
        }
    }

    // MARK: Чистые статики

    nonisolated static func bestDefault(from models: [String]) -> String {
        if let exact = models.first(where: { $0 == "openai_whisper-large-v3-v20240930" }) { return exact }
        if let turbo = models.first(where: { $0.contains("large-v3-v20240930") }) { return turbo }
        if let v3 = models.first(where: { $0.contains("large-v3") }) { return v3 }
        if let base = models.first(where: { $0.contains("base") && !$0.contains(".en") }) { return base }
        return models.first ?? "openai_whisper-base"
    }

    nonisolated static let audioExts: Set<String> = [
        "ogg", "oga", "opus", "m4a", "mp3", "wav", "aac", "flac",
        "mp4", "mov", "m4v", "webm", "3gp", "amr", "wma", "aiff", "aif", "caf",
    ]
    nonisolated static func audioFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return en.compactMap { $0 as? URL }
            .filter { audioExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
