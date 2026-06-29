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
// Build note: MLX ships Metal shaders → the .app must be built via xcodebuild (see build_app.sh). See
// `LOCAL_AI_LAYER_P3.md` ("## SPIKE RESULTS").

// MARK: Model spec + on-disk location (§6: in-app non-gated download, cache under Application Support)

enum MLXModelSpec {
    /// The non-thinking Instruct-2507 4-bit build (no `<think>` preamble before the JSON). Apache-2.0, public/non-gated.
    static let repoId = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    static let revision = "main"
    /// What to fetch: weights + tokenizer/config (skip the rest of the repo).
    static let downloadPatterns = ["*.safetensors", "*.json", "*.txt", "*.jinja", "tokenizer.model"]

    /// HubApi download base under Parla's Application Support (clean delete + one "disk used" number, NOT the hidden
    /// default HF cache). HubApi lays the snapshot at `<base>/models/<repoId>`. A settable `var` (not a func) so tests
    /// can redirect it to a temp dir — otherwise `isDownloaded()` reads the user's REAL model and availability tests
    /// go non-deterministic (mirrors `HistoryStore.fileURL`). `nonisolated(unsafe)`: a test seam, set only in `setUp`.
    nonisolated(unsafe) static var downloadBase: URL = defaultDownloadBase()

    private static func defaultDownloadBase() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("Parla/mlx", isDirectory: true)
    }

    /// Where `HubApi.snapshot` materializes the model.
    static func modelDirectory() -> URL {
        downloadBase.appendingPathComponent("models/\(repoId)", isDirectory: true)
    }

    /// "Downloaded" = a COMPLETE-enough snapshot: the model config, the tokenizer files `AutoTokenizer` needs, AND
    /// a weight shard. Stricter than "config + any shard" so an INTERRUPTED download (which lands files one by one)
    /// isn't reported `.ready` with a green check while generation would fail. Cheap, synchronous — drives availability.
    static func isDownloaded() -> Bool {
        let dir = modelDirectory()
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }
        guard has("config.json"), has("tokenizer_config.json"),
              has("tokenizer.json") || has("tokenizer.model") else { return false }
        let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return contents.contains { $0.hasSuffix(".safetensors") }
    }

    /// Bytes on disk for the model (for the Settings "disk used" line / delete recompute). 0 if absent.
    static func bytesOnDisk() -> Int64 {
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

struct MLXHubDownloader: Downloader {
    let downloadBase: URL

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let hub = HubApi(downloadBase: downloadBase)
        return try await hub.snapshot(
            from: id, revision: revision ?? "main", matching: patterns, progressHandler: progressHandler)
    }
}

// MARK: TokenizerLoader + bridge — MLXLMCommon.Tokenizer over swift-transformers AutoTokenizer
// (Translation of mlx-swift-lm's #huggingFaceTokenizerLoader / #adaptHuggingFaceTokenizer macros. Verified the
//  bridged methods + `Message`/`ToolSpec` types match swift-transformers 1.1.9 exactly — no signature drift.)

struct MLXTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return MLXTokenizerBridge(upstream)
    }
}

struct MLXTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    // swift-transformers names it `decode(tokens:)`, MLXLMCommon's protocol `decode(tokenIds:)`.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
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

actor MLXEngine {
    static let shared = MLXEngine()

    /// Bound the model's output so one note can't run away (mirror Backend A's 500-token cap).
    static let maxOutputTokens = 500

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
    func loadContainer(progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }) async throws -> ModelContainer {
        if let container { return container }
        if let loadTask { return try await loadTask.value }   // join the in-flight load
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
        defer { loadTask = nil }
        let c = try await task.value
        guard gen == generation else { throw AIError.unavailable }   // unloaded/deleted mid-load → don't cache
        container = c
        return c
    }

    /// One generation pass: a fresh session (stateless per note) with a bounded output, return the raw model text.
    /// `maxTokens` defaults to the terse insight cap; the comprehensive `summarize` passes a higher budget.
    func generate(prompt: String, instructions: String, maxTokens: Int = maxOutputTokens) async throws -> String {
        let container = try await loadContainer()
        var params = GenerateParameters()
        params.maxTokens = maxTokens
        let session = ChatSession(container, instructions: instructions, generateParameters: params)
        return try await session.respond(to: prompt)
    }

    /// Download (or refresh from cache) the model files WITHOUT loading them into memory — the explicit opt-in
    /// "Download" action. Generation later loads lazily from this cache via `loadContainer`.
    func downloadModel(progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }) async throws {
        _ = try await MLXHubDownloader(downloadBase: MLXModelSpec.downloadBase)
            .download(
                id: MLXModelSpec.repoId, revision: MLXModelSpec.revision,
                matching: MLXModelSpec.downloadPatterns, useLatest: false, progressHandler: progressHandler)
    }

    /// Drop the in-memory model (after a delete, or to free RAM after an enrich batch) + invalidate any in-flight
    /// load so it won't cache a now-stale container. A later `loadContainer` re-reads from disk.
    func unload() {
        container = nil
        loadTask?.cancel()
        loadTask = nil
        generation &+= 1
    }
}

// MARK: Service — the LocalLLMService seam (Backend B)

struct MLXLLMService: LocalLLMService {
    /// MLX covers the languages Backend A (FoundationModels) can't: Russian + Ukrainian — PLUS English as a FALLBACK.
    /// Qwen3 handles English fine, so when FoundationModels isn't usable for EN (Apple Intelligence off — notably when
    /// the Mac's system language is Russian), MLX serves it. `DefaultAIService` always tries FoundationModels FIRST, so
    /// an English Mac with Apple Intelligence still uses the free zero-download backend; MLX is consulted only as fallback.
    static let supportedLanguages: Set<String> = ["ru", "uk", "en"]

    /// Chars fed to the model in one pass (mirror FoundationModels' budget). Long/chunked notes = P4 map-reduce.
    static let maxInputChars = 8000

    static let instructions = """
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
    static var isSupportedHardware: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    func availability(forLanguage language: String) -> AIAvailability {
        guard Self.isSupportedHardware else { return .noAppleSilicon }
        guard Self.supportedLanguages.contains(languagePrimarySubtag(language)) else { return .languageUnsupported }
        // Downloading the model IS the opt-in (a row in ModelManagerView). Until then: dormant, never .ready.
        guard MLXModelSpec.isDownloaded() else { return .needsModelDownload }
        return .ready
    }

    func insights(forTranscript text: String, language: String) async throws -> AIInsights {
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
    static let summaryInstructions = """
    You write a thorough, well-structured summary of a long transcript or of a set of chapter summaries. Cover ALL the \
    major topics, arguments and key points — be comprehensive, not terse (several sentences to a few short paragraphs, \
    scaled to the content). Write in the SAME language as the input. Output ONLY the summary text — no preamble, no \
    headings, no JSON.
    """

    /// Comprehensive free-form summary (long-note map-reduce) — a longer prompt + a higher output-token budget than
    /// the terse `insights` summary. Returns the raw model text (no JSON parse).
    func summarize(_ text: String, language: String) async throws -> String {
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
    static func parseInsights(from raw: String) -> AIInsights? {
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
    static func balancedJSONObjects(in text: String) -> [String] {
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
