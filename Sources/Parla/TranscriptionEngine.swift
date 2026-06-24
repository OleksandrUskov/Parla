import Foundation
import WhisperKit

enum EngineError: LocalizedError {
    case notLoaded
    var errorDescription: String? {
        switch self {
        case .notLoaded: return L("error.model.notloaded")
        }
    }
}

struct EngineResult {
    var text: String
    var language: String
    var segments: [Segment]
    var duration: Double
}

/// Этап загрузки модели — наружу для прогресс-бара.
enum ModelLoad: Sendable, Equatable {
    case downloading(Double)   // 0...1
    case loading
}

/// Тонкая обёртка над WhisperKit. Держит загруженную модель и переиспользует её.
actor TranscriptionEngine {
    private var whisperKit: WhisperKit?
    private var loadedModel: String?

    /// Куда WhisperKit складывает модели: ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml
    static func modelsRoot() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }
    static func localFolder(_ model: String) -> URL {
        modelsRoot().appendingPathComponent(model, isDirectory: true)
    }
    /// Модель уже скачана на диск?
    static func isDownloaded(_ model: String) -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: localFolder(model).path)) ?? []
        return !items.isEmpty
    }

    /// Суммарный размер файлов в папке (рекурсивно).
    static func folderSize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
    static func modelSize(_ model: String) -> Int64 { folderSize(at: localFolder(model)) }

    /// Если модель на диске — грузим ЛОКАЛЬНО (download:false, офлайн, без повторного скачивания).
    /// Иначе — качаем с прогрессом. На любой сбой локальной загрузки — фолбэк на докачку.
    func ensureLoaded(model: String, progress: @Sendable @escaping (ModelLoad) -> Void) async throws {
        if loadedModel == model, whisperKit != nil { return }
        whisperKit = nil

        if Self.isDownloaded(model) {
            progress(.loading)
            do {
                whisperKit = try await WhisperKit(
                    WhisperKitConfig(model: model, modelFolder: Self.localFolder(model).path, download: false))
                loadedModel = model
                return
            } catch {
                // повреждённый/неполный кэш → перекачаем ниже
            }
        }

        progress(.downloading(0))
        let folder = try await WhisperKit.download(variant: model, progressCallback: { p in
            progress(.downloading(p.fractionCompleted))
        })
        progress(.loading)
        whisperKit = try await WhisperKit(
            WhisperKitConfig(model: model, modelFolder: folder.path, download: false))
        loadedModel = model
    }

    /// Удалить модель с диска. Если она сейчас загружена — выгружаем из памяти.
    func deleteModel(_ name: String) throws {
        let folder = Self.localFolder(name)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        if loadedModel == name { whisperKit = nil; loadedModel = nil }
    }

    func transcribe(wavPath: String, language: String?, model: String, translate: Bool = false) async throws -> EngineResult {
        if loadedModel != model || whisperKit == nil {
            try await ensureLoaded(model: model, progress: { _ in })
        }
        guard let kit = whisperKit else { throw EngineError.notLoaded }

        // task: .translate → Whisper переводит речь любого языка в английский текст.
        let options = DecodingOptions(task: translate ? .translate : .transcribe,
                                      language: language, detectLanguage: language == nil)
        let start = Date()
        // Массивная перегрузка + слияние чанков (длинное аудио WhisperKit может бить).
        let results: [TranscriptionResult] = try await kit.transcribe(audioPath: wavPath, decodeOptions: options)
        let elapsed = Date().timeIntervalSince(start)

        let fullText = results.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let segs = results.flatMap { $0.segments }.map {
            Segment(start: Double($0.start), end: Double($0.end),
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
