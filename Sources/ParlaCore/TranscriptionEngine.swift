import Foundation
// @preconcurrency: WhisperKit isn't Sendable-annotated yet. Treating its API as pre-concurrency
// suppresses the dependency's missing-Sendable noise so v6 only flags OUR genuine isolation issues.
@preconcurrency import WhisperKit

public enum EngineError: LocalizedError {
    case notLoaded
    public var errorDescription: String? {
        switch self {
        case .notLoaded: return L("error.model.notloaded")
        }
    }
}

public struct EngineResult: Sendable {
    public var text: String
    /// The language the decode ran in — i.e. what the model was TOLD, when the user pinned one.
    public var language: String
    public var segments: [Segment]
    public var duration: Double
    /// What the model actually HEARD, filled in only when a language was pinned (with `nil` the model detects
    /// anyway and `language` above already is the answer). The gap between told and heard is the whole point:
    /// a wrong pin measured 49.85% word errors against 5.57% on identical audio, and nothing noticed.
    public var heard: HeardLanguage? = nil
}

/// The model's own read of the audio's language, with its confidence (a probability, 0...1).
public struct HeardLanguage: Sendable, Equatable {
    public var language: String
    public var confidence: Double
    public init(language: String, confidence: Double) { self.language = language; self.confidence = confidence }
}

/// Model load stage — exposed for the progress bar.
public enum ModelLoad: Sendable, Equatable {
    case downloading(Double)   // 0...1
    case loading
}

/// Seam over the transcription backend so the drop→history orchestration is testable with a fake.
/// The real `TranscriptionEngine` (WhisperKit) and test doubles both conform.
public protocol TranscribingEngine: Sendable {
    func ensureLoaded(model: String, progress: @Sendable @escaping (ModelLoad) -> Void) async throws
    func transcribe(wavPath: String, language: String?, model: String, translate: Bool) async throws -> EngineResult
    /// Same, but says whether to ALSO ask the model what language it heard. Opt-in because that costs a second
    /// audio load plus a full encoder pass: worth it once per file, wasteful once per chunk. Default forwards to
    /// the plain version, so test doubles and other conformances are untouched.
    func transcribe(wavPath: String, language: String?, model: String, translate: Bool,
                    detectHeardLanguage: Bool) async throws -> EngineResult
    /// Streaming seam: decode an in-memory 16 kHz mono Float buffer — no file round-trip.
    /// The caller owns windowing + absolute-time bookkeeping; returned segment times are buffer-relative.
    func transcribe(samples: [Float], language: String?, model: String) async throws -> EngineResult
    func deleteModel(_ name: String) async throws
    /// Release the loaded model's weights. The next `transcribe` transparently reloads, so this is a pure
    /// memory/latency trade the CALLER decides — see `AppModel.releaseIdleMemory()`.
    func unload() async
}

extension TranscribingEngine {
    /// Default no-op: an engine that holds nothing has nothing to release (test doubles, future backends).
    public func unload() async {}

    public func transcribe(wavPath: String, language: String?, model: String, translate: Bool,
                           detectHeardLanguage: Bool) async throws -> EngineResult {
        try await transcribe(wavPath: wavPath, language: language, model: model, translate: translate)
    }
}

/// Thin wrapper around WhisperKit. Keeps the loaded model and reuses it.
public actor TranscriptionEngine {
    private var whisperKit: WhisperKit?
    private var loadedModel: String?
    private var loadInFlight: (model: String, task: Task<Void, Error>)?   // coalesce concurrent same-model loads

    public init() {}

    /// The `downloadBase` handed to WhisperKit/HubApi — it appends `models/argmaxinc/whisperkit-coreml`. Matches
    /// HubApi's own default (`<base>/huggingface`), so passing it explicitly on macOS is a no-op (still ~/Documents).
    /// On iOS the weights are large + re-downloadable and MUST stay OUT of Documents (user-visible + iCloud-backed
    /// → App Store 2.5 rejection): use Application Support (also excluded from backup — see `prepareModelStorage`).
    public static func downloadBase() -> URL {
        #if os(iOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        return base.appendingPathComponent("huggingface", isDirectory: true)   // == HubApi's default component
    }

    /// Where WhisperKit stores models: `<downloadBase>/models/argmaxinc/whisperkit-coreml`
    /// (macOS: ~/Documents/huggingface/… unchanged; iOS: Application Support/huggingface/…).
    public static func modelsRoot() -> URL {
        downloadBase().appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    #if os(iOS)
    /// Create the model-download tree and mark it excluded-from-backup, so the large re-downloadable weights never
    /// inflate the user's iCloud backup (App Store 2.5). Idempotent; only the `huggingface` subtree is touched —
    /// history/audio under Application Support/Parla stay backed up. Call before any download.
    public static func prepareModelStorage() {
        ModelStorage.prepareExcludedFromBackup(downloadBase())   // Application Support/huggingface
    }
    #endif
    public static func localFolder(_ model: String) -> URL {
        modelsRoot().appendingPathComponent(model, isDirectory: true)
    }
    /// Is the model already downloaded to disk?
    public static func isDownloaded(_ model: String) -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: localFolder(model).path)) ?? []
        return !items.isEmpty
    }

    /// Total size of files in the folder (recursively).
    public static func folderSize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
    public static func modelSize(_ model: String) -> Int64 { folderSize(at: localFolder(model)) }

    /// If the model is on disk — load it LOCALLY (download:false, offline, no re-download).
    /// Otherwise — download with progress. On any local-load failure — fall back to re-downloading.
    public func ensureLoaded(model: String, progress: @Sendable @escaping (ModelLoad) -> Void) async throws {
        if loadedModel == model, whisperKit != nil { return }
        // Coalesce concurrent loads of the SAME model (e.g. the streaming pre-warm racing the final
        // finishDictation decode) — and NEVER let two loads overlap, even for different models. Each is 626 MB–1.5 GB of CoreML weights;
        // two at once is the sum, which on iOS is a jetsam kill mid-dictation. It is reachable: the launch
        // pre-warm (`prewarmDictationModel`) is fire-and-forget and holds no lane, so `isBusy` stays false for
        // its whole duration, while the model-manager row has no `isBusy` gate at all — the user can switch tier
        // and drop a file straight into that window. Worse than memory: `performLoad` nils `whisperKit` and
        // writes `loadedModel` around its own await, so whichever loser resumed last decided which model
        // `transcribe` actually used, while the saved record was stamped with the model the caller ASKED for.
        while let inFlight = loadInFlight {
            if inFlight.model == model {
                try await inFlight.task.value   // same model → join it, don't start a second download/load
                return
            }
            _ = try? await inFlight.task.value  // different model → wait it out (its failure is not ours to throw)
            if loadedModel == model, whisperKit != nil { return }   // it may have become what we wanted meanwhile
        }
        let task = Task { try await self.performLoad(model: model, progress: progress) }
        loadInFlight = (model, task)
        // Clear only what we still OWN. Unconditional clearing let a finishing load blow away a newer load's
        // slot, which re-opened the overlap above and also defeated `unload()`'s `guard loadInFlight == nil`,
        // so a memory-pressure release could tear down weights under an in-flight load.
        defer { if loadInFlight?.task == task { loadInFlight = nil } }
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
        #if os(iOS)
        Self.prepareModelStorage()   // weights out of iCloud backup before the auto-download (App Store 2.5)
        #endif
        // `@Sendable` is LOAD-BEARING, not cosmetic: WhisperKit's `progressCallback` is `((Progress) -> Void)?`
        // (NOT @Sendable), so without it this closure inherits THIS actor's isolation — and WhisperKit invokes
        // it off-actor on the cooperative pool (Hub download thread), which traps (`swift_task_isCurrentExecutor`,
        // the same crash class as the MicRecorder tap). `@Sendable` strips the isolation (it only reads `p` and
        // calls the already-@Sendable `progress`). The sibling call site in `AppModel+Models.swift` is @Sendable
        // for the same reason — keep BOTH that way.
        // downloadBase keeps the auto-download in lockstep with `modelsRoot()`/`isDownloaded()` (esp. iOS's
        // Application Support relocation) — matches HubApi's default on macOS, so it's a no-op there.
        let folder = try await WhisperKit.download(variant: model, downloadBase: Self.downloadBase(),
                                                   progressCallback: { @Sendable p in
            progress(.downloading(p.fractionCompleted))
        })
        progress(.loading)
        whisperKit = try await WhisperKit(
            WhisperKitConfig(model: model, modelFolder: folder.path, download: false))
        loadedModel = model
    }

    /// Delete the model from disk. If it's currently loaded — unload it from memory.
    public func deleteModel(_ name: String) throws {
        let folder = Self.localFolder(name)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        if loadedModel == name { whisperKit = nil; loadedModel = nil }
    }

    /// Release the loaded weights. `WhisperKit.unloadModels()` has existed since day one and this app never
    /// called it — once loaded, ~600 MB–1.5 GB of CoreML weights stayed resident for the life of the process.
    /// On a Mac that is merely rude; on an iPhone, where the process has a hard memory budget and jetsam kills
    /// without warning, it is the difference between surviving a summary and being killed mid-note.
    ///
    /// Dropping the reference alone is NOT enough — `unloadModels()` is what tears down the CoreML models
    /// themselves. A load in flight is left alone: cancelling it would only make the caller reload immediately.
    public func unload() async {
        guard loadInFlight == nil else { return }
        guard let wk = whisperKit else { return }
        // STOP ADVERTISING IT FIRST. `wk.unloadModels()` is a nonisolated async method on a plain class, so
        // awaiting it RELEASES this actor and tears the models down on the cooperative pool. Clearing our state
        // afterwards meant that for the whole teardown `ensureLoaded` (`loadedModel == model, whisperKit != nil`)
        // and `transcribe` both still reported the model as loaded — and handed the very instance being
        // destroyed to `kit.transcribe`, which reloads it internally when `modelState != .loaded`. WhisperKit's
        // `loadModels()` and `unloadModels()` then ran in parallel over the same unguarded `MLModel?` fields;
        // our actor had been the only serialization and the await gave it up. Outcomes ranged from an invisible
        // full reload stuck on "Preparing…", through `modelsUnavailable` on a file the user had just dropped, to
        // an over-release. The caller is `releaseIdleMemory()` on a memory-pressure event, i.e. exactly when a
        // second resident copy of the weights is least affordable.
        whisperKit = nil
        loadedModel = nil
        await wk.unloadModels()
    }

    public func transcribe(wavPath: String, language: String?, model: String, translate: Bool = false) async throws -> EngineResult {
        try await transcribe(wavPath: wavPath, language: language, model: model,
                             translate: translate, detectHeardLanguage: true)
    }

    public func transcribe(wavPath: String, language: String?, model: String,
                           translate: Bool, detectHeardLanguage: Bool) async throws -> EngineResult {
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

        // Ask what the model HEARD whenever the caller pinned a language — pinning turns detection off above
        // (`detectLanguage: language == nil`), so without this the app can never notice a wrong pin. One encoder
        // pass over the first 30 s; negligible next to the decode that just ran.
        var heard: HeardLanguage? = nil
        if detectHeardLanguage, language != nil, let d = try? await kit.detectLanguage(audioPath: wavPath) {
            // `langProbs` are LOG probabilities — exponentiate to get something a threshold can be reasoned about.
            heard = HeardLanguage(language: d.language, confidence: Foundation.exp(Double(d.langProbs[d.language] ?? -.infinity)))
        }

        let mapped = mapResults(results, language: language)
        // duration = the ACTUAL audio length, not the processing time (`elapsed`). Fall back to the
        // last segment end, then to elapsed, if the file can't be probed.
        let audioLen = AudioDuration.seconds(ofFileAt: wavPath) ?? mapped.segments.map(\.end).max() ?? elapsed
        return EngineResult(text: mapped.text, language: mapped.language,
                            segments: mapped.segments, duration: audioLen, heard: heard)
    }

    /// Streaming seam: transcribe an in-memory 16 kHz mono Float buffer — the live
    /// dictation loop feeds sliding windows straight from the mic tap, no file round-trip. Always
    /// `.transcribe` (dictation never translates); pass `language` explicitly for RU/UK (auto-detect
    /// degrades and misclassifies UK as RU). Returned segment times are buffer-relative — the caller
    /// owns the windowing and the absolute-time offset.
    public func transcribe(samples: [Float], language: String?, model: String) async throws -> EngineResult {
        if loadedModel != model || whisperKit == nil {
            try await ensureLoaded(model: model, progress: { _ in })
        }
        guard let kit = whisperKit else { throw EngineError.notLoaded }

        let options = DecodingOptions(task: .transcribe, language: language, detectLanguage: language == nil)
        let results: [TranscriptionResult] = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        // No detection on the streaming path: dictation windows are ~1-2 s of a live mic, far too little for a
        // reliable read, and the user is speaking right now — the moment to question the language is a file import.
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
