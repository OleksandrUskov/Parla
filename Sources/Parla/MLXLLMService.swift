import Foundation
import Hub          // swift-transformers (WhisperKit's 1.1.x): HubApi — backs our Downloader
import Tokenizers   // swift-transformers: AutoTokenizer + Tokenizer — backs our TokenizerLoader/bridge
import MLXLMCommon  // loadModelContainer / ChatSession / Downloader / TokenizerLoader / Tokenizer / ModelContainer
import MLXLLM        // registers the Qwen3 architecture into the model-factory registry (linked for its side effect)

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

    /// HubApi download base under Parla's Application Support (clean delete + one "disk used" number), NOT the
    /// hidden default HF cache. HubApi lays the snapshot down at `<base>/models/<repoId>`.
    static func downloadBase() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("Parla/mlx", isDirectory: true)
    }

    /// Where `HubApi.snapshot` materializes the model.
    static func modelDirectory() -> URL {
        downloadBase().appendingPathComponent("models/\(repoId)", isDirectory: true)
    }

    /// "Downloaded" = the config + at least one weight shard are present. Cheap, synchronous — drives availability.
    static func isDownloaded() -> Bool {
        let dir = modelDirectory()
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) else { return false }
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

    private var container: ModelContainer?

    /// Download (if missing) + load the model, caching the container. Used both by the explicit "Download" action
    /// (with a real progress handler) and lazily by the first generation (cache hit → instant).
    func loadContainer(progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }) async throws -> ModelContainer {
        if let container { return container }
        let c = try await loadModelContainer(
            from: MLXHubDownloader(downloadBase: MLXModelSpec.downloadBase()),
            using: MLXTokenizerLoader(),
            id: MLXModelSpec.repoId,
            revision: MLXModelSpec.revision,
            progressHandler: progressHandler)
        container = c
        return c
    }

    /// One generation pass: build a fresh session (stateless per note), return the raw model text.
    func generate(prompt: String, instructions: String) async throws -> String {
        let container = try await loadContainer()
        let session = ChatSession(container, instructions: instructions)
        return try await session.respond(to: prompt)
    }

    /// Download (or refresh from cache) the model files WITHOUT loading them into memory — the explicit opt-in
    /// "Download" action. Generation later loads lazily from this cache via `loadContainer`.
    func downloadModel(progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }) async throws {
        _ = try await MLXHubDownloader(downloadBase: MLXModelSpec.downloadBase())
            .download(
                id: MLXModelSpec.repoId, revision: MLXModelSpec.revision,
                matching: MLXModelSpec.downloadPatterns, useLatest: false, progressHandler: progressHandler)
    }

    /// Drop the in-memory model (e.g. after the user deletes the download) so a later load re-reads from disk.
    func unload() { container = nil }
}

// MARK: Service — the LocalLLMService seam (Backend B)

struct MLXLLMService: LocalLLMService {
    /// MLX covers the languages Backend A (FoundationModels) can't: Russian + Ukrainian. English stays Backend A's
    /// job (keeps the per-OS floor semantics intact). Qwen3 is multilingual — this set can widen later if needed.
    static let supportedLanguages: Set<String> = ["ru", "uk"]

    /// Chars fed to the model in one pass (mirror FoundationModels' budget). Long/chunked notes = P4 map-reduce.
    static let maxInputChars = 8000

    static let instructions = """
    You extract a title, a short summary, and any action items from a voice-message transcript.
    Respond with ONLY a JSON object and nothing else, in this exact shape:
    {"title": "...", "summary": "...", "actions": ["...", "..."]}
    ALWAYS write the title, summary and actions in the SAME language as the transcript. Keep the title to a few \
    words. Keep the summary to 1–3 sentences. List only action items explicitly stated as tasks/intentions; if \
    there are none, return an empty array. Do not invent information. Output no text outside the JSON object.
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
        guard let parsed = Self.parseInsights(from: raw) else { throw AIError.unavailable }
        return parsed
    }

    // MARK: Tolerant JSON parse (MLX has no guided decoding → prompt-then-parse; pure + unit-tested)

    /// Decode the model's text into `AIInsights`: strip ``` fences, take the first balanced `{…}`, JSON-decode.
    /// Returns nil on any failure → caller throws → extractive fallback kept. Empty title AND summary → nil.
    static func parseInsights(from raw: String) -> AIInsights? {
        guard let json = firstJSONObject(in: raw), let data = json.data(using: .utf8) else { return nil }
        struct Raw: Decodable { var title: String?; var summary: String?; var actions: [String]? }
        guard let decoded = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        let title = (decoded.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = (decoded.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let actions = (decoded.actions ?? [])
            .map { ActionItem(text: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
        guard !title.isEmpty || !summary.isEmpty else { return nil }
        return AIInsights(title: title, summary: summary, actions: actions)
    }

    /// First top-level balanced `{…}` substring (ignores braces inside strings + escapes). Handles ```json fences
    /// implicitly by scanning for the first `{`. Pure + testable.
    static func firstJSONObject(in text: String) -> String? {
        let chars = Array(text)
        guard let start = chars.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { return String(chars[start...i]) }
                }
            }
            i += 1
        }
        return nil
    }
}
