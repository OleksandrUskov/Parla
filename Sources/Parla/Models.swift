import Foundation

/// Один распознанный фрагмент с таймкодом.
struct Segment: Codable, Hashable {
    var start: Double
    var end: Double
    var text: String
}

/// Одна расшифровка в истории.
struct TranscriptItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var date: Date = Date()
    var sourceName: String
    var language: String
    var durationSec: Double
    var model: String
    var text: String
    var segments: [Segment]
    var edited: Bool? = nil           // правился ли текст вручную (Optional — иначе старый history.json не декодится)
    var editedAt: Date? = nil         // когда правился (nil для нетронутых / легаси-записей)
    var sourcePath: String? = nil     // абсолютный путь к исходнику (для «перераспознать»); nil у старых/легаси
    var sourceBookmark: Data? = nil   // запасной локатор-bookmark; nil — норм (Optional → легаси-совместимо)
    var audioFile: String? = nil      // имя копии исходника в .../Parla/audio/ (для плеера); nil у старых записей
    var audioPlayable: String? = nil  // имя m4a-рендишена для проигрывания (Opus/видео); nil если не нужен/не вышел

    /// Удобный аксессор: nil/false → не редактировалось.
    var isEdited: Bool { edited == true }

    /// Текст с таймкодами или без — для отображения/копирования.
    /// Для отредактированных записей таймкоды подавляются: правленый текст уже не совпадает
    /// с границами исходных сегментов, поэтому показываем плоский текст.
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

// MARK: - Поиск исходного файла записи (фича 01 «перераспознать»)

/// Результат попытки найти исходник записи.
enum SourceResolution: Equatable {
    case found(URL, scoped: Bool)   // scoped == true → надо вызвать stopAccessing… после (на будущее, под sandbox)
    case missing
}

extension TranscriptItem {
    /// Пытается найти исходный файл: сначала по абсолютному пути, затем по bookmark.
    /// Несендбоксный билд: обычный путь — основной механизм, bookmark — запасной локатор.
    func resolveSource(fileManager fm: FileManager = .default) -> SourceResolution {
        if let p = sourcePath, fm.fileExists(atPath: p) {
            return .found(URL(fileURLWithPath: p), scoped: false)
        }
        if let data = sourceBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
               fm.fileExists(atPath: url.path) {
                return .found(url, scoped: false)   // обычный bookmark (не security-scoped — приложение не в песочнице)
            }
        }
        return .missing
    }

    /// Доступен ли исходник прямо сейчас (для включения/выключения пункта «перераспознать»).
    var hasResolvableSource: Bool {
        if case .found(let url, let scoped) = resolveSource() {
            if scoped { url.stopAccessingSecurityScopedResource() }
            return true
        }
        return false
    }
}

/// Best-effort bookmark исходника при создании записи. Обычный (не security-scoped) — годится
/// как запасной локатор в несендбоксном билде. Ошибки игнорируем: основной механизм — путь.
func makeSourceBookmark(_ url: URL) -> Data? {
    try? url.bookmarkData()
}

func fmtTime(_ s: Double) -> String {
    let t = max(0, Int(s.rounded()))
    return String(format: "%02d:%02d", t / 60, t % 60)
}

/// Нормализованная правка: убираем CRLF и хвостовые пробелы/переводы строк.
/// Пустой результат не затирает оригинал. Возвращает (newText, changed).
func normalizedEdit(_ raw: String, from original: String) -> (text: String, changed: Bool) {
    let trimmed = raw.replacingOccurrences(of: "\r\n", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let new = trimmed.isEmpty ? original : trimmed   // не даём случайно стереть весь текст
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

/// Короткое дружелюбное имя варианта для чипа/метаданных.
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

/// Один «уровень» модели в менеджере (резолвится в реальный вариант).
struct ModelTier: Identifiable {
    let title: String
    let hint: String          // только качество/скорость, без размера
    let estimate: String      // примерный размер до скачивания, напр. "~630 МБ" ("" — неизвестно)
    let name: String
    let recommended: Bool
    var id: String { name }
}

// MARK: - История: фильтр, экспорт, форматирование размера

/// Поиск по истории (без учёта регистра, по тексту и имени файла).
func filterHistory(_ items: [TranscriptItem], query: String) -> [TranscriptItem] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return items }
    return items.filter { $0.text.lowercased().contains(q) || $0.sourceName.lowercased().contains(q) }
}

/// Вся история в один markdown-текст (для экспорта/бэкапа).
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

/// Позиция в пакетной обработке: «index из total». Только для дропа папки / нескольких файлов.
struct BatchProgress: Equatable {
    var index: Int     // 1-based: текущий файл
    var total: Int     // всего файлов в задании (>= 2; для одиночного — nil вместо структуры)
    var done: Int      // завершённых до текущего (для нижнего бара): index-1
}

enum EnginePhase: Equatable {
    case idle
    case preparing(String, batch: BatchProgress? = nil)
    case downloadingModel(Double)   // 0...1, реальное скачивание (один раз)
    case loadingModel               // загрузка в память (быстро, каждый запуск)
    case transcribing(String, batch: BatchProgress? = nil)
    case failed(String)
}

/// «msg.ogg» (3 из 12)» для батча, или просто «msg.ogg» для одиночного файла.
func batchLabel(_ name: String, _ b: BatchProgress?) -> String {
    guard let b, b.total > 1 else { return Lf("batch.label.single", name) }
    return Lf("batch.label.multi", name, b.index, b.total)
}

/// Русская плюрализация (1 файл / 2 файла / 5 файлов).
func pluralRu(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let a = abs(n) % 100, b = a % 10
    if a > 10 && a < 20 { return many }
    if b == 1 { return one }
    if b >= 2 && b <= 4 { return few }
    return many
}

/// Хранилище истории в ~/Library/Application Support/Parla/history.json
enum HistoryStore {
    /// Путь к файлу истории в ~/Library/Application Support/Parla/.
    /// `var` (а не `let`) — это тест-шов: тесты подменяют путь на временный, чтобы не трогать
    /// реальную историю пользователя. В продакшене значение никогда не меняется.
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

    /// Одноразовый перенос истории со старого имени приложения (Murmur → Parla).
    private static func migrateLegacyIfNeeded() {
        let legacy = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/history.json")
        migrate(target: fileURL, legacy: legacy)
    }

    /// Чистая тестируемая логика: скопировать legacy → target, если у target ещё нет файла.
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

// MARK: - Слежение за папкой (фича 04)

/// Снимок файла: для проверки «дописался ли» (size+mtime стабильны) и для ключа дедупликации.
struct WatchedFileStat: Equatable {
    let url: URL
    let size: Int64
    let mtime: Date
    /// Стабильная дешёвая идентичность: путь + размер + mtime. Меняется при смене содержимого
    /// (тот же файл, новые байты → новый ключ → распознаём заново).
    var dedupKey: String { "\(url.path)|\(size)|\(Int(mtime.timeIntervalSince1970))" }
}

/// Чистое ядро слежения: всё тестируемое, без файловой системы внутри.
/// FSEvents/таймер только ВЫЗЫВАЮТ эти функции — сами решений не принимают.
enum FolderScan {
    /// Из снимка папки выбрать файлы, которые: (а) ещё не обработаны (нет dedupKey в `processed`),
    /// (б) «устаканились» — size+mtime совпали с прошлым наблюдением (`lastSeen`).
    /// Возвращает (готовые к работе, новый lastSeen для следующего прохода).
    static func newStableFiles(
        current: [WatchedFileStat],
        lastSeen: [String: WatchedFileStat],   // ключ = path
        processed: Set<String>                 // dedupKey уже обработанных
    ) -> (ready: [WatchedFileStat], nextLastSeen: [String: WatchedFileStat]) {
        var ready: [WatchedFileStat] = []
        var next: [String: WatchedFileStat] = [:]
        for stat in current {
            next[stat.url.path] = stat
            if processed.contains(stat.dedupKey) { continue }     // уже сделали
            if let prev = lastSeen[stat.url.path], prev == stat {
                ready.append(stat)                                // не менялся с прошлого раза → дописался
            }
            // новый ИЛИ изменился → только запоминаем в next, ждём следующего прохода
        }
        return (ready.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }, next)
    }

    /// FIFO-обрезка множества обработанных, чтобы не росло бесконечно (старые ключи отбрасываются).
    static func capProcessed(_ ordered: [String], max: Int) -> [String] {
        guard max >= 0, ordered.count > max else { return ordered }
        return Array(ordered.suffix(max))
    }
}

/// Хранилище множества обработанных ключей в ~/Library/Application Support/Parla/processed.json.
/// Зеркалит HistoryStore (включая `var fileURL` тест-шов).
enum ProcessedStore {
    static var fileURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parla", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("processed.json")
    }()

    static func load() -> [String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }   // нет файла → пусто, без краша
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func save(_ keys: [String]) {
        guard let data = try? JSONEncoder().encode(keys) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Хранилище аудио для плеера (фича 06)

/// Копии исходного аудио рядом с историей: ~/Library/Application Support/Parla/audio/.
/// Папка выводится из `HistoryStore.fileURL` → автоматически уезжает на временный путь в тестах.
enum AudioStore {
    /// Форматы, которые AVAudioPlayer открывает напрямую — рендишен .m4a им не нужен.
    static let directlyPlayable: Set<String> = ["m4a", "mp3", "wav", "aac", "caf", "aiff", "aif"]

    static var folder: URL {
        HistoryStore.fileURL.deletingLastPathComponent().appendingPathComponent("audio", isDirectory: true)
    }
    private static func ensureFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Имя файла копии: "<uuid>.<ext>" (ext нижним регистром, или "bin"). Чистая функция.
    static func fileName(for id: UUID, sourceExtension ext: String) -> String {
        let e = ext.lowercased()
        return e.isEmpty ? "\(id.uuidString).bin" : "\(id.uuidString).\(e)"
    }

    /// Лучший URL для проигрывания: сначала m4a-рендишен, затем копия оригинала (если файл на месте).
    static func playableURL(for item: TranscriptItem) -> URL? {
        for name in [item.audioPlayable, item.audioFile].compactMap({ $0 }) {
            let u = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// Копирует исходник в хранилище. Возвращает имя файла или nil (на ошибке не валим транскрибацию).
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

    /// Делает m4a-рендишен исходника для проигрывания. Возвращает имя или nil. Best-effort.
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

    /// Удалить аудио записи (копию и рендишен).
    static func remove(_ item: TranscriptItem) {
        for name in [item.audioFile, item.audioPlayable].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Снести весь кэш аудио (для кнопки «Очистить аудио-кэш» в настройках).
    static func clearAll() {
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return }
        for u in items { try? FileManager.default.removeItem(at: u) }
    }

    static func totalBytes() -> Int64 { TranscriptionEngine.folderSize(at: folder) }

    /// Размер аудио-файлов одной записи (копия + рендишен). 0, если файлов нет.
    static func bytes(of item: TranscriptItem) -> Int64 {
        [item.audioFile, item.audioPlayable].compactMap { $0 }.reduce(Int64(0)) { $0 + fileSize($1) }
    }
    private static func fileSize(_ name: String) -> Int64 {
        let u = folder.appendingPathComponent(name)
        return Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Снести файлы-сироты: всё в audio/, что не упомянуто ни в одной записи (ловит обрывки от краша
    /// между copy и save, недописанный ffmpeg .m4a). Текст не трогает — только файлы.
    static func pruneOrphans(keeping history: [TranscriptItem]) {
        let referenced = Set(history.flatMap { [$0.audioFile, $0.audioPlayable].compactMap { $0 } })
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return }
        for f in files where !referenced.contains(f.lastPathComponent) {
            try? FileManager.default.removeItem(at: f)
        }
    }

    /// ЧИСТОЕ ядро LRU-выселения: какие записи лишить аудио, чтобы влезть в кэп.
    /// ТЕКСТ НЕ ТРОГАЕТСЯ — вызывающий лишь обнуляет audioFile/audioPlayable и удаляет эти файлы.
    /// `history[0]` — новейшая (insert at:0), поэтому «старое» = бóльший индекс → идём с хвоста.
    /// `sizeOf` инжектируется (нет ФС в ядре → детерминированно и тестируемо). `protected`
    /// (выделенная/играющая + только что добавленная) НИКОГДА не выселяется — даже если из-за этого
    /// кэп чуть превышен (частичное соответствие корректно, не дёргаем аудио из-под плеера).
    static func enforceAudioCap(_ history: [TranscriptItem], capBytes: Int64,
                                sizeOf: (TranscriptItem) -> Int64,
                                protected: Set<UUID>) -> [UUID] {
        var total = history.reduce(Int64(0)) { $0 + sizeOf($1) }
        guard total > capBytes else { return [] }
        var evict: [UUID] = []
        for item in history.reversed() {                 // с хвоста (старое) к голове (новое)
            if total <= capBytes { break }
            let bytes = sizeOf(item)
            guard bytes > 0, !protected.contains(item.id) else { continue }   // нет аудио или защищён
            evict.append(item.id)
            total -= bytes
        }
        return evict
    }
}

/// Индекс сегмента, чей [start, …) содержит t (для подсветки активного сегмента при проигрывании).
/// Берём последний сегмент со `start <= t` — устойчиво к зазорам/перекрытиям в выводе Whisper.
/// nil, если t раньше первого сегмента или сегментов нет.
func activeSegmentIndex(_ segments: [Segment], at t: Double) -> Int? {
    guard !segments.isEmpty else { return nil }
    var idx: Int? = nil
    for (i, s) in segments.enumerated() where s.start <= t + 0.0001 { idx = i }
    return idx
}
