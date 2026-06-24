import Foundation
import WhisperKit
import AVFoundation

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

/// Model load stage — exposed for the progress bar.
enum ModelLoad: Sendable, Equatable {
    case downloading(Double)   // 0...1
    case loading
}

/// Seam over the transcription backend so the drop→history orchestration is testable with a fake.
/// The real `TranscriptionEngine` (WhisperKit) and test doubles both conform.
protocol TranscribingEngine: Sendable {
    func ensureLoaded(model: String, progress: @Sendable @escaping (ModelLoad) -> Void) async throws
    func transcribe(wavPath: String, language: String?, model: String, translate: Bool) async throws -> EngineResult
    func deleteModel(_ name: String) async throws
}

/// Thin wrapper around WhisperKit. Keeps the loaded model and reuses it.
actor TranscriptionEngine {
    private var whisperKit: WhisperKit?
    private var loadedModel: String?

    /// Where WhisperKit stores models: ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml
    static func modelsRoot() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }
    static func localFolder(_ model: String) -> URL {
        modelsRoot().appendingPathComponent(model, isDirectory: true)
    }
    /// Is the model already downloaded to disk?
    static func isDownloaded(_ model: String) -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: localFolder(model).path)) ?? []
        return !items.isEmpty
    }

    /// Total size of files in the folder (recursively).
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

    /// If the model is on disk — load it LOCALLY (download:false, offline, no re-download).
    /// Otherwise — download with progress. On any local-load failure — fall back to re-downloading.
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
                // corrupted/incomplete cache → re-download below
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

    /// Delete the model from disk. If it's currently loaded — unload it from memory.
    func deleteModel(_ name: String) throws {
        let folder = Self.localFolder(name)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        if loadedModel == name { whisperKit = nil; loadedModel = nil }
    }

    /// Actual audio length in seconds (AVFoundation) — for the record's duration metadata.
    /// nil if the file can't be opened (caller falls back to the last segment end).
    private static func audioDuration(ofFileAt path: String) -> Double? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let sr = file.fileFormat.sampleRate
        return sr > 0 ? Double(file.length) / sr : nil
    }

    func transcribe(wavPath: String, language: String?, model: String, translate: Bool = false) async throws -> EngineResult {
        if loadedModel != model || whisperKit == nil {
            try await ensureLoaded(model: model, progress: { _ in })
        }
        guard let kit = whisperKit else { throw EngineError.notLoaded }

        // task: .translate → Whisper translates speech in any language into English text.
        let options = DecodingOptions(task: translate ? .translate : .transcribe,
                                      language: language, detectLanguage: language == nil)
        let start = Date()
        // Array overload + chunk merging (WhisperKit may split long audio).
        let results: [TranscriptionResult] = try await kit.transcribe(audioPath: wavPath, decodeOptions: options)
        let elapsed = Date().timeIntervalSince(start)

        let fullText = results.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // WhisperKit's per-segment `.text` carries raw special tokens (<|startoftranscript|>, <|ru|>,
        // <|8.52|>, …) that the overall `.text` doesn't — strip them at the source so storage, UI and
        // every export are clean.
        let segs = results.flatMap { $0.segments }.map {
            Segment(start: Double($0.start), end: Double($0.end), text: stripWhisperTokens($0.text))
        }
        // duration = the ACTUAL audio length, not the processing time (`elapsed`). Fall back to the
        // last segment end, then to elapsed, if the file can't be probed.
        let audioLen = Self.audioDuration(ofFileAt: wavPath) ?? segs.map(\.end).max() ?? elapsed
        return EngineResult(
            text: fullText,
            language: results.first?.language ?? (language ?? ""),
            segments: segs,
            duration: audioLen
        )
    }
}

extension TranscriptionEngine: TranscribingEngine {}
