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

    /// Текст с таймкодами или без — для отображения/копирования.
    func display(timestamps: Bool) -> String {
        guard timestamps, !segments.isEmpty else { return text }
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
    let hint: String
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
        out += "_\(it.date.formatted(date: .abbreviated, time: .shortened)) · \(it.language.uppercased()) · \(friendlyModel(it.model))_\n\n"
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

enum EnginePhase: Equatable {
    case idle
    case preparing(String)
    case downloadingModel(Double)   // 0...1, реальное скачивание (один раз)
    case loadingModel               // загрузка в память (быстро, каждый запуск)
    case transcribing(String)
    case failed(String)
}

/// Хранилище истории в ~/Library/Application Support/Parla/history.json
enum HistoryStore {
    static let fileURL: URL = {
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
