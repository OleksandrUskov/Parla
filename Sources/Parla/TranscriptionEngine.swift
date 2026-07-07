import Foundation
import ParlaCore
// @preconcurrency: WhisperKit isn't Sendable-annotated yet. Treating its API as pre-concurrency
// suppresses the dependency's missing-Sendable noise so v6 only flags OUR genuine isolation issues.
@preconcurrency import WhisperKit

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
    /// Streaming seam (MIC_DICTATION P3): decode an in-memory 16 kHz mono Float buffer — no file round-trip.
    /// The caller owns windowing + absolute-time bookkeeping; returned segment times are buffer-relative.
    func transcribe(samples: [Float], language: String?, model: String) async throws -> EngineResult
    func deleteModel(_ name: String) async throws
}

/// Thin wrapper around WhisperKit. Keeps the loaded model and reuses it.
actor TranscriptionEngine {
    private var whisperKit: WhisperKit?
    private var loadedModel: String?
    private var loadInFlight: (model: String, task: Task<Void, Error>)?   // coalesce concurrent same-model loads

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
        // Coalesce concurrent loads of the SAME model (e.g. the streaming pre-warm racing the final
        // finishDictation decode): join the in-flight load instead of nil-ing `whisperKit` and starting a
        // second download/load. The actor serializes everything up to the first await, so the check + set
        // is atomic.
        if let inFlight = loadInFlight, inFlight.model == model {
            try await inFlight.task.value
            return
        }
        let task = Task { try await self.performLoad(model: model, progress: progress) }
        loadInFlight = (model, task)
        defer { loadInFlight = nil }
        try await task.value
    }

    /// The actual load (always run behind `loadInFlight` so only one runs per model at a time): load locally
    /// if on disk (offline, no re-download), else download with progress. Local-load failure (corrupt cache)
    /// falls back to re-downloading.
    private func performLoad(model: String, progress: @Sendable @escaping (ModelLoad) -> Void) async throws {
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
        // `@Sendable` is LOAD-BEARING, not cosmetic: WhisperKit's `progressCallback` is `((Progress) -> Void)?`
        // (NOT @Sendable), so without it this closure inherits THIS actor's isolation — and WhisperKit invokes
        // it off-actor on the cooperative pool (Hub download thread), which traps (`swift_task_isCurrentExecutor`,
        // the same crash class as the MicRecorder tap). `@Sendable` strips the isolation (it only reads `p` and
        // calls the already-@Sendable `progress`). The sibling call site in `AppModel+Models.swift` is @Sendable
        // for the same reason — keep BOTH that way.
        let folder = try await WhisperKit.download(variant: model, progressCallback: { @Sendable p in
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
        // `kit` never escapes this actor's isolation — the call runs ON the actor; @preconcurrency on
        // the import lets v6 accept passing the not-yet-Sendable `kit` into its own method.
        let results: [TranscriptionResult] = try await kit.transcribe(audioPath: wavPath, decodeOptions: options)
        let elapsed = Date().timeIntervalSince(start)

        let mapped = mapResults(results, language: language)
        // duration = the ACTUAL audio length, not the processing time (`elapsed`). Fall back to the
        // last segment end, then to elapsed, if the file can't be probed.
        let audioLen = AudioDuration.seconds(ofFileAt: wavPath) ?? mapped.segments.map(\.end).max() ?? elapsed
        return EngineResult(text: mapped.text, language: mapped.language,
                            segments: mapped.segments, duration: audioLen)
    }

    /// Streaming seam (MIC_DICTATION P3): transcribe an in-memory 16 kHz mono Float buffer — the live
    /// dictation loop feeds sliding windows straight from the mic tap, no file round-trip. Always
    /// `.transcribe` (dictation never translates); pass `language` explicitly for RU/UK (auto-detect
    /// degrades and misclassifies UK as RU). Returned segment times are buffer-relative — the caller
    /// owns the windowing and the absolute-time offset.
    func transcribe(samples: [Float], language: String?, model: String) async throws -> EngineResult {
        if loadedModel != model || whisperKit == nil {
            try await ensureLoaded(model: model, progress: { _ in })
        }
        guard let kit = whisperKit else { throw EngineError.notLoaded }

        let options = DecodingOptions(task: .transcribe, language: language, detectLanguage: language == nil)
        let results: [TranscriptionResult] = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        let mapped = mapResults(results, language: language)
        let duration = Double(samples.count) / 16_000.0   // 16 kHz mono → exact length, no file to probe
        return EngineResult(text: mapped.text, language: mapped.language,
                            segments: mapped.segments, duration: duration)
    }

    /// Map WhisperKit results into our domain shape (minus duration). Strips special tokens at the source —
    /// the per-segment `.text` carries `<|startoftranscript|>`, `<|ru|>`, `<|8.52|>`… that the overall
    /// `.text` doesn't — and normalizes the language fallback. The file-path and streaming seams share this
    /// so they can never drift.
    private func mapResults(_ results: [TranscriptionResult], language: String?)
        -> (text: String, language: String, segments: [Segment]) {
        let fullText = results.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let segs = results.flatMap { $0.segments }.map {
            Segment(start: Double($0.start), end: Double($0.end), text: stripWhisperTokens($0.text))
        }
        return (fullText, results.first?.language ?? (language ?? ""), segs)
    }
}

extension TranscriptionEngine: TranscribingEngine {}
