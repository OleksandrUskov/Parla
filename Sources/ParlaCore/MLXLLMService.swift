#if os(macOS)  // MLX generative backend = macOS-only. iOS gets an inert stub in MLXStubs.swift.
import Foundation
import Hub          // swift-transformers (WhisperKit's 1.1.x): HubApi — backs our Downloader
import Tokenizers   // swift-transformers: AutoTokenizer + Tokenizer — backs our TokenizerLoader/bridge
import MLXLMCommon  // loadModelContainer / ChatSession / Downloader / TokenizerLoader / Tokenizer / ModelContainer / GenerateParameters
import MLXLLM        // registers the Qwen3 architecture into the model-factory registry (linked for its side effect)
import MLX           // MLX.GPU.set(cacheLimit:) — bound the Metal buffer cache (memory discipline on a 16GB Mac)

// MARK: - Backend B — MLX (RU/UK GENERATIVE insights, opt-in download, macOS-14 floor)
//
// The real generative path for Parla's core audience: Apple Intelligence (Backend A, FoundationModels) doesn't
// cover RU/UK and is off when the Mac UI language is Russian; MLX has no such gate and runs on the macOS-14 floor.
//
// Integration note (why no convenience macro): mlx-swift-lm's `#huggingFaceLoadModelContainer` macro expands to
// the NEW HF stack (swift-huggingface + swift-transformers ≥1.3), which CONFLICTS with WhisperKit's pinned
// swift-transformers 1.1.x. So we implement MLXLMCommon's two small protocols ourselves over the swift-transformers
// WhisperKit already brings (Hub.HubApi + Tokenizers.AutoTokenizer) and call the non-macro `loadModelContainer`.
// Best-effort: ANY failure throws `AIError`; `enrichInsights` catches it and keeps the extractive insights — the
// transcript is never touched. Model + container stay actor-internal (mirror `NLEmbedder`/`TranscriptionEngine`).
// Build note: MLX ships Metal shaders → the .app must be built via xcodebuild (see build_app.sh).

// MARK: Model spec + on-disk location (in-app non-gated download, cache under Application Support)

public enum MLXModelSpec {
    /// The non-thinking Instruct-2507 4-bit build (no `<think>` preamble before the JSON). Apache-2.0, public/non-gated.
    public static let repoId = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    /// PINNED to a commit, not a branch. `main` meant a new user got whatever `mlx-community` had re-uploaded
    /// that day — silently different weights from the ones this project measured its quality on, and nothing in a
    /// bug report would ever reveal it. Re-quantising and re-pushing is normal practice for community model repos
    /// and unacceptable as a dependency. Bump DELIBERATELY, and re-measure when you do.
    ///
    /// Note the asymmetry: `WhisperKit.download(variant:downloadBase:from:token:endpoint:)` takes NO revision
    /// parameter at all, so the SPEECH model — the one the whole product depends on — cannot be pinned this way.
    /// What it does take is `endpoint:`, which is the built-in escape hatch to a mirror if that ever becomes
    /// necessary. Recorded in STATE under the Hugging Face dependency.
    public static let revision = "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b"
    /// What to fetch: weights + tokenizer/config (skip the rest of the repo).
    public static let downloadPatterns = ["*.safetensors", "*.json", "*.txt", "*.jinja", "tokenizer.model"]

    /// HubApi download base under Parla's Application Support (clean delete + one "disk used" number, NOT the hidden
    /// default HF cache). HubApi lays the snapshot at `<base>/models/<repoId>`. A settable `var` (not a func) so tests
    /// can redirect it to a temp dir — otherwise `isDownloaded()` reads the user's REAL model and availability tests
    /// go non-deterministic (mirrors `HistoryStore.fileURL`). `nonisolated(unsafe)`: a test seam, set only in `setUp`.
    nonisolated(unsafe) static var downloadBase: URL = defaultDownloadBase()

    /// `internal` (not private) so tests can assert the PRODUCTION location even while
    /// `downloadBase` itself is redirected to a temp dir for isolation.
    static func defaultDownloadBase() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return StorageRoot.defaultURL().appendingPathComponent("mlx", isDirectory: true)
    }

    /// Where `HubApi.snapshot` materializes the model.
    public static func modelDirectory() -> URL {
        downloadBase.appendingPathComponent("models/\(repoId)", isDirectory: true)
    }

    /// "Downloaded" = a COMPLETE snapshot, so an INTERRUPTED download (which lands files one by one) is never
    /// reported `.ready` with a green check while generation would fail. Cheap, synchronous — drives availability.
    /// Shares its definition with the downloader's local-copy short-circuit ON PURPOSE: if the two could drift,
    /// the app could believe a model is loadable while the downloader disagrees, or phone home for a model it
    /// already has. See `MLXHubDownloader.isSnapshotComplete`.
    public static func isDownloaded() -> Bool {
        MLXHubDownloader.isSnapshotComplete(at: modelDirectory())
    }

    /// Bytes on disk for the model (for the Settings "disk used" line / delete recompute). 0 if absent.
    public static func bytesOnDisk() -> Int64 {
        let dir = modelDirectory()
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}

// MARK: Downloader — MLXLMCommon.Downloader over swift-transformers Hub.HubApi
// (Translation of mlx-swift-lm's #hubDownloader macro from swift-huggingface's HubClient to 1.1.x's HubApi.)

public struct MLXHubDownloader: Downloader {
    public let downloadBase: URL

    public func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        // The single choke point for BOTH MLX model stores (the generative model and the embedder both download
        // through this type) — so the backup-exclusion rule is applied here once, before any bytes land. Without it
        // a ~2.3 GB re-downloadable model went straight into the user's backup (App Store 2.5 on iOS, Time Machine
        // on macOS); only the WhisperKit tree was ever excluded.
        ModelStorage.prepareExcludedFromBackup(downloadBase)
        let local = downloadBase.appendingPathComponent("models/\(id)", isDirectory: true)
        // Honour `useLatest` — we used to drop it, and that broke the app's central promise. `container` is nil
        // after every launch AND after every `unload()`, which `refreshSemanticIndex` calls at the end of EVERY
        // pass, so the next insight always reloads; `resolve` then calls this unconditionally. HubApi.snapshot
        // is not a local no-op: online it GETs the repo's file list plus per-file metadata BEFORE returning an
        // already-complete snapshot, and offline it SHA-256s every LFS shard (~2.3 GB) instead. So a fully
        // downloaded model phoned home before generating a single token, while the app's own strings say
        // "Downloaded once, runs fully offline". `useLatest == false` means exactly "the local copy is fine".
        if !useLatest, Self.isSnapshotComplete(at: local) {
            let done = Progress(totalUnitCount: 1)
            done.completedUnitCount = 1
            progressHandler(done)
            return local
        }
        let hub = HubApi(downloadBase: downloadBase)
        return try await hub.snapshot(
            from: id, revision: revision ?? "main", matching: patterns, progressHandler: progressHandler)
    }

    /// Is the snapshot at `dir` complete enough to load WITHOUT contacting the Hub?
    /// Config + the tokenizer files `AutoTokenizer` needs + all the weights. When a shard index is present,
    /// EVERY shard it names must exist: checking for "any .safetensors" would call an interrupted multi-shard
    /// download complete — which also silently reported `.ready` in the UI before this.
    public static func isSnapshotComplete(at dir: URL) -> Bool {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }
        guard has("config.json"), has("tokenizer_config.json"),
              has("tokenizer.json") || has("tokenizer.model") else { return false }
        let indexURL = dir.appendingPathComponent("model.safetensors.index.json")
        if let data = try? Data(contentsOf: indexURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let weightMap = root["weight_map"] as? [String: String] {
            let shards = Set(weightMap.values)
            return !shards.isEmpty && shards.allSatisfy { has($0) }
        }
        let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return contents.contains { $0.hasSuffix(".safetensors") }
    }
}

// MARK: TokenizerLoader + bridge — MLXLMCommon.Tokenizer over swift-transformers AutoTokenizer
// (Translation of mlx-swift-lm's #huggingFaceTokenizerLoader / #adaptHuggingFaceTokenizer macros. Verified the
//  bridged methods + `Message`/`ToolSpec` types match swift-transformers 1.1.9 exactly — no signature drift.)

public struct MLXTokenizerLoader: TokenizerLoader {
    public func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return MLXTokenizerBridge(upstream)
    }
}

public struct MLXTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    public init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    public func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    // swift-transformers names it `decode(tokens:)`, MLXLMCommon's protocol `decode(tokenIds:)`.
    public func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    public func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    public func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    public var bosToken: String? { upstream.bosToken }
    public var eosToken: String? { upstream.eosToken }
    public var unknownToken: String? { upstream.unknownToken }

    public func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

// MARK: Engine — owns the loaded model (actor-internal), downloads + generates

public actor MLXEngine {
    public static let shared = MLXEngine()

    /// Bound the model's output so one note can't run away (mirror Backend A's 500-token cap).
    public static let maxOutputTokens = 500

    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?   // single-flight: concurrent callers join one load
    private var generation = 0                            // bumped by unload() to invalidate an in-flight load
    private var didCapGPUCache = false

    /// Cap the Metal buffer cache ONCE so freed buffers return to the OS instead of growing unbounded — essential
    /// alongside a resident ~2.3GB model + WhisperKit (~1.5GB) on a 16GB Mac. (mlx-swift defaults to ~1.5× working set.)
    private func capGPUCacheOnce() {
        guard !didCapGPUCache else { return }
        MLX.Memory.cacheLimit = 48 * 1024 * 1024   // 48 MB (non-deprecated property; GPU.set(cacheLimit:) is deprecated)
        didCapGPUCache = true
    }

    /// Download-if-needed + load the model, caching the container. SINGLE-FLIGHT (concurrent callers await one load)
    /// and TOCTOU-safe: if `unload()` (a delete) lands during the load, the result is discarded — never cached stale.
    public func loadContainer(progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }) async throws -> ModelContainer {
        if let container { return container }
        if let loadTask {
            // Joiners must re-check the generation too: a `deleteMLXModel` landing during the join would
            // otherwise hand back a container for weights that are being removed from disk.
            let gen = generation
            let c = try await loadTask.value
            guard gen == generation else { throw AIError.unavailable }
            return c
        }
        capGPUCacheOnce()
        let gen = generation
        let task = Task {
            try await loadModelContainer(
                from: MLXHubDownloader(downloadBase: MLXModelSpec.downloadBase),
                using: MLXTokenizerLoader(),
                id: MLXModelSpec.repoId, revision: MLXModelSpec.revision,
                progressHandler: progressHandler)
        }
        loadTask = task
        // Clear only what we still OWN: an unconditional clear let a finishing load blow away a newer load's
        // slot, so the next caller started a SECOND ~2.3 GB load instead of joining.
        defer { if loadTask == task { loadTask = nil } }
        let c = try await task.value
        guard gen == generation else { throw AIError.unavailable }   // unloaded/deleted mid-load → don't cache
        container = c
        return c
    }

    /// One generation pass: a fresh session (stateless per note) with a bounded output, return the raw model text.
    /// `maxTokens` defaults to the terse insight cap; the comprehensive `summarize` passes a higher budget.
    public func generate(prompt: String, instructions: String, maxTokens: Int = maxOutputTokens) async throws -> String {
        let container = try await loadContainer()
        var params = GenerateParameters()
        params.maxTokens = maxTokens
        let session = ChatSession(container, instructions: instructions, generateParameters: params)
        return try await session.respond(to: prompt)
    }

    /// Download (or refresh from cache) the model files WITHOUT loading them into memory — the explicit opt-in
    /// "Download" action. Generation later loads lazily from this cache via `loadContainer`.
    public func downloadModel(progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }) async throws {
        _ = try await MLXHubDownloader(downloadBase: MLXModelSpec.downloadBase)
            .download(
                id: MLXModelSpec.repoId, revision: MLXModelSpec.revision,
                matching: MLXModelSpec.downloadPatterns, useLatest: false, progressHandler: progressHandler)
    }

    /// Drop the in-memory model + invalidate any in-flight load so it won't cache a now-stale container.
    /// A later `loadContainer` re-reads from disk.
    ///
    /// `force` marks the DELETE case, where the weights are going away and an in-flight load genuinely must be
    /// invalidated. The default (false) is the tail-of-batch memory release, and it deliberately leaves a load in
    /// flight alone: that load belongs to a foreground action the user just triggered, and cancelling it made a
    /// *successful* generative pass throw `AIError.unavailable`, which `enrichFailedIDs` then remembers — the
    /// note lost its generative insights for the rest of the session. This fires from unrelated flows, because
    /// the tail `unload()` runs unconditionally, including on the FoundationModels/English and extractive paths
    /// that never loaded MLX at all. Skipping is safe: `loadContainer` returns early when `container` is set, so
    /// a load in flight means `container` is already nil and there is nothing here to free.
    public func unload(force: Bool = false) {
        if !force, loadTask != nil { return }
        container = nil
        loadTask?.cancel()
        loadTask = nil
        generation &+= 1
    }
}

// MARK: Service — the LocalLLMService seam (Backend B)

public struct MLXLLMService: LocalLLMService {
    /// MLX covers the languages Backend A (FoundationModels) can't: Russian + Ukrainian — PLUS English as a FALLBACK.
    /// Qwen3 handles English fine, so when FoundationModels isn't usable for EN (Apple Intelligence off — notably when
    /// the Mac's system language is Russian), MLX serves it. `DefaultAIService` always tries FoundationModels FIRST, so
    /// an English Mac with Apple Intelligence still uses the free zero-download backend; MLX is consulted only as fallback.
    public static let supportedLanguages: Set<String> = ["ru", "uk", "en"]

    /// Chars fed to the model in one pass (mirror FoundationModels' budget). Long/chunked notes = P4 map-reduce.
    public static let maxInputChars = 8000

    public static let instructions = """
    You extract a title, a short summary, topical keywords, and any action items from a voice-message transcript.
    Respond with ONLY a JSON object and nothing else, in this exact shape:
    {"title": "...", "summary": "...", "keywords": ["...", "..."], "actions": ["...", "..."]}
    ALWAYS write every field in the SAME language as the transcript. Keep the title to a few words; the summary to \
    1–3 sentences. keywords: 3–6 short topical tags (single words or short phrases), no duplicates. actions: ONLY \
    explicit tasks or intentions the speaker says THEY need to do — for a purely narrative, reflective, or \
    descriptive note with no real task, return an EMPTY array; never turn a past action or a general statement \
    into a task. Do not invent information. Output no text outside the JSON object.
    """

    /// MLX runs on Apple Silicon only. The app ships arm64; under Rosetta (x86_64) this is false → the backend
    /// reports `.noAppleSilicon` and the UI hides the download. Also drives whether the MLX model row is shown.
    ///
    /// The simulator clause is NOT redundant: an Apple-Silicon iOS simulator is `arch(arm64)` too, so an
    /// `arch(arm64)`-only test answers "yes, supported" there — and MLX cannot run on the simulator at all.
    /// Inert while this file is macOS-only, deliberately written now so the day MLX enters the iOS build the
    /// simulator does not start offering a ~2.3 GB download and then crash on first generation.
    public static var isSupportedHardware: Bool {
        #if targetEnvironment(simulator)
        return false
        #elseif arch(arm64)
        return true
        #else
        return false
        #endif
    }

    public func availability(forLanguage language: String) -> AIAvailability {
        guard Self.isSupportedHardware else { return .noAppleSilicon }
        guard Self.supportedLanguages.contains(languagePrimarySubtag(language)) else { return .languageUnsupported }
        // Downloading the model IS the opt-in (a row in ModelManagerView). Until then: dormant, never .ready.
        guard MLXModelSpec.isDownloaded() else { return .needsModelDownload }
        return .ready
    }

    public func insights(forTranscript text: String, language: String) async throws -> AIInsights {
        guard case .ready = availability(forLanguage: language) else { throw AIError.unavailable }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIError.unavailable }   // nothing to summarize → don't fabricate
        let raw = try await MLXEngine.shared.generate(
            prompt: String(trimmed.prefix(Self.maxInputChars)), instructions: Self.instructions)
        guard var parsed = Self.parseInsights(from: raw) else { throw AIError.unavailable }
        parsed.backend = .mlx   // provenance: this insight was produced by MLX/Qwen (matters for the EN fallback)
        return parsed
    }

    /// Comprehensive free-form summary prompt (NOT the terse 1–3-sentence `instructions`) — for long-note map-reduce.
    public static let summaryInstructions = """
    You write a thorough, well-structured summary of a long transcript or of a set of chapter summaries. Cover ALL the \
    major topics, arguments and key points — be comprehensive, not terse (several sentences to a few short paragraphs, \
    scaled to the content). Write in the SAME language as the input. Output ONLY the summary text — no preamble, no \
    headings, no JSON.
    """

    /// Comprehensive free-form summary (long-note map-reduce) — a longer prompt + a higher output-token budget than
    /// the terse `insights` summary. Returns the raw model text (no JSON parse).
    public func summarize(_ text: String, language: String) async throws -> String {
        guard case .ready = availability(forLanguage: language) else { throw AIError.unavailable }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIError.unavailable }
        // Generous cap so a long recording's summary FINISHES; completeSentences is the safety net if it's still hit.
        let raw = try await MLXEngine.shared.generate(prompt: String(trimmed.prefix(Self.maxInputChars)),
                                                      instructions: Self.summaryInstructions, maxTokens: 3000)
        return completeSentences(raw)
    }

    // MARK: Tolerant JSON parse (MLX has no guided decoding → prompt-then-parse; pure + unit-tested)

    /// Decode the model's text into `AIInsights` with maximum tolerance (MLX has no guided decoding): scan EACH
    /// top-level balanced `{…}` (the model may fence it or wrap it in prose), parse loosely via JSONSerialization,
    /// and read title/summary/actions INDEPENDENTLY — a malformed `actions` field never discards a good title+summary.
    /// Returns the first object that yields a non-empty title or summary; nil if none → caller keeps extractive.
    public static func parseInsights(from raw: String) -> AIInsights? {
        for json in balancedJSONObjects(in: raw) {
            guard let data = json.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let title = stringField(obj["title"])
            let summary = stringField(obj["summary"])
            let actions = stringArrayField(obj["actions"])
                .map { ActionItem(text: $0.trimmingCharacters(in: .whitespacesAndNewlines).sentenceCased) }
                .filter { !$0.text.isEmpty }
            let keywords = normalizedKeywords(stringArrayField(obj["keywords"]))
            if !title.isEmpty || !summary.isEmpty {
                return AIInsights(title: title, summary: summary, actions: actions, keywords: keywords)
            }
        }
        return nil
    }

    /// A JSON value read leniently as a trimmed String (accepts a String; ignores any other type).
    private static func stringField(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// A JSON value read leniently as `[String]`: an array (keep its string elements) or a lone string → `[string]`;
    /// anything else → `[]`. So a model that emits `"actions":"call Bob"` or `[{…}]` doesn't sink the whole parse.
    private static func stringArrayField(_ value: Any?) -> [String] {
        if let arr = value as? [Any] { return arr.compactMap { $0 as? String } }
        if let s = value as? String { return [s] }
        return []
    }

    /// All top-level balanced `{…}` substrings, in order (braces inside strings + escapes ignored). Lets the parser
    /// skip a stray brace-pair in pre-JSON prose and find the real object. Pure + testable.
    public static func balancedJSONObjects(in text: String) -> [String] {
        let chars = Array(text)
        var objects: [String] = []
        var i = 0
        while i < chars.count {
            guard chars[i] == "{" else { i += 1; continue }
            let start = i
            var depth = 0, inString = false, escaped = false
            var j = i
            scan: while j < chars.count {
                let c = chars[j]
                if inString {
                    if escaped { escaped = false }
                    else if c == "\\" { escaped = true }
                    else if c == "\"" { inString = false }
                } else if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { objects.append(String(chars[start...j])); break scan }
                }
                j += 1
            }
            i = max(j, start) + 1
        }
        return objects
    }

    /// First top-level balanced `{…}` (kept for simple callers + the unit tests).
    static func firstJSONObject(in text: String) -> String? { balancedJSONObjects(in: text).first }
}
#endif  // os(macOS) — MLX generative backend
