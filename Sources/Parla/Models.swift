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
}

func fmtTime(_ s: Double) -> String {
    let t = Int(s.rounded())
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
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([TranscriptItem].self, from: data)) ?? []
    }

    static func save(_ items: [TranscriptItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
