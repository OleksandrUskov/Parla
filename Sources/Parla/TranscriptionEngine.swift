import Foundation
import WhisperKit

enum EngineError: LocalizedError {
    case notLoaded
    var errorDescription: String? {
        switch self {
        case .notLoaded: return "Модель не загрузилась"
        }
    }
}

struct EngineResult {
    var text: String
    var language: String
    var segments: [Segment]
    var duration: Double
}

/// Тонкая обёртка над WhisperKit. Держит загруженную модель и переиспользует её.
actor TranscriptionEngine {
    private var whisperKit: WhisperKit?
    private var loadedModel: String?

    /// Грузит модель (скачивает при первом использовании). No-op, если уже загружена.
    func ensureLoaded(model: String) async throws {
        if loadedModel == model, whisperKit != nil { return }
        whisperKit = nil
        let kit = try await WhisperKit(WhisperKitConfig(model: model))
        whisperKit = kit
        loadedModel = model
    }

    func transcribe(wavPath: String, language: String?, model: String) async throws -> EngineResult {
        try await ensureLoaded(model: model)
        guard let kit = whisperKit else { throw EngineError.notLoaded }

        let options = DecodingOptions(
            task: .transcribe,
            language: language,                 // nil → авто-определение
            detectLanguage: language == nil
        )

        let start = Date()
        // Берём массивную перегрузку и сливаем чанки (длинное аудио WhisperKit может бить).
        let results: [TranscriptionResult] = try await kit.transcribe(audioPath: wavPath, decodeOptions: options)
        let elapsed = Date().timeIntervalSince(start)

        let fullText = results
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let segs = results.flatMap { $0.segments }.map {
            Segment(start: Double($0.start),
                    end: Double($0.end),
                    text: $0.text.trimmingCharacters(in: .whitespaces))
        }
        return EngineResult(
            text: fullText,
            language: results.first?.language ?? (language ?? ""),
            segments: segs,
            duration: elapsed
        )
    }
}
