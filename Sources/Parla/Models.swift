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
    var out = "# Parla — история расшифровок\n\n"
    for it in items {
        out += "## \(it.sourceName)\n"
        let editedMark = it.isEdited ? " · изменено" : ""
        out += "_\(it.date.formatted(date: .abbreviated, time: .shortened)) · \(it.language.uppercased()) · \(friendlyModel(it.model))\(editedMark)_\n\n"
        out += it.text + "\n\n---\n\n"
    }
    return out
}

func formatBytes(_ bytes: Int64) -> String {
    if bytes <= 0 { return "—" }
    let mb = Double(bytes) / 1_048_576
    if mb >= 1024 { return String(format: "%.1f ГБ", mb / 1024) }
    return String(format: "%.0f МБ", mb)
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
    guard let b, b.total > 1 else { return "«\(name)»" }
    return "«\(name)» (\(b.index) из \(b.total))"
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
