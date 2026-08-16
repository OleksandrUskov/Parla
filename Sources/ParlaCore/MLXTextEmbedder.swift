#if os(macOS)  // MLX download-tier embedder = macOS-only. iOS gets an inert stub in MLXStubs.swift.
import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon

// MARK: - Download-tier embedder (real query→note semantic search)
//
// A proper multilingual SENTENCE-EMBEDDING model (default Qwen3-Embedding-0.6B) for query→note retrieval — the
// thing NLContextualEmbedding can't do (short queries collapse; see the embedder-retrieval lesson). Validated
// empirically by the probe: RU/UK/EN query↔query separation 0.13–0.26 (no collapse), every query ranks its
// topic note #1, cross-lingual EN→RU / UK→RU works.
//
// SWAPPABLE BY DESIGN: the active model is a single `EmbeddingModelSpec.active`. If Qwen ever underperforms on
// RU/UK with real notes, swap `active` to BGE-M3 (`bgeM3Fallback` below) — the RU-champion (MIRACL ru 70.1) and
// STILL multilingual, so we keep ONE unified embedding space + cross-lingual search. The store's provenance tag
// (`EmbeddingModelSpec.active.tag`) then triggers a one-time re-embed of history into the new space; no rebuild.
// Two PARALLEL models would fragment the space and kill cross-lingual query→note, so we SWAP, never add a second.
//
// Reuses the `MLXHubDownloader` / `MLXTokenizerLoader` (same module). Best-effort: any failure → nil (graceful,
// mirrors `NLEmbedder`); the model + container stay actor-internal. MLX → the .app must be built via xcodebuild.

/// How a model decorates query vs document text, and whether it's an XLM-R encoder (needs explicit positionIds).
public enum EmbedderProfile: Sendable {
    /// Qwen3-Embedding: an instruction prefix on the QUERY only; documents are bare. (Decoder + RoPE → no positionIds fix.)
    case instruct(task: String)
    /// multilingual-e5: `query: ` on queries, `passage: ` on documents. (XLM-R → needs positionIds when batching.)
    case e5
    /// BGE-M3 etc.: no prefixes. (XLM-R → needs positionIds when batching.)
    case plain

    public func decorate(_ text: String, kind: EmbedKind) -> String {
        switch self {
        case .instruct(let task): return kind == .query ? "Instruct: \(task)\nQuery: \(text)" : text
        case .e5:                 return (kind == .query ? "query: " : "passage: ") + text
        case .plain:              return text
        }
    }
}

/// The active download-tier model + its on-disk location (cache under Application Support, like `MLXModelSpec`).
public struct EmbeddingModelSpec: Sendable {
    public let repoId: String
    public let revision: String
    public let profile: EmbedderProfile
    /// XLM-R encoders (BGE-M3 / e5) need explicit position IDs offset by padding_idx+1; Qwen3 (RoPE) does not.
    /// Unused while embedding one text at a time (no padding), but kept so a swap to an XLM-R model is localized.
    public let needsXLMPositionIds: Bool
    /// What to fetch from the repo (weights + tokenizer/config), like `MLXModelSpec.downloadPatterns`.
    public let downloadPatterns: [String]

    /// Provenance tag stamped onto stored vectors. A change here ≠ the vectors' tag → `backfillEmbeddings` re-embeds.
    public var tag: String { "emb:" + repoId }

    /// ACTIVE model — Qwen3-Embedding-0.6B (4-bit), Apache-2.0, non-gated, SOTA RU/UK/EN, validated by the probe.
    /// To swap (e.g. RU/UK underperforms): set `active = .bgeM3Fallback`. That's the whole change — history re-embeds.
    public static let active = EmbeddingModelSpec(
        repoId: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
        revision: "6c3ae70858513f1a78e9cdca3cae330d9075cd2a",   // pinned: see MLXModelSpec.revision for why a branch is not acceptable here
        profile: .instruct(task: "Given a search query, retrieve notes relevant to the query"),
        needsXLMPositionIds: false,
        downloadPatterns: ["*.safetensors", "*.json", "*.txt"])

    /// Designated RU/UK FALLBACK (not active) — BGE-M3, the RU-champion, MIT, non-gated, prefix-free, multilingual.
    /// A drop-in swap target kept here so `active = .bgeM3Fallback` is the only change needed. (XLM-R → the embed
    /// forward's positionIds branch must be wired + probe-validated when this becomes active; tracked in STATE.)
    public static let bgeM3Fallback = EmbeddingModelSpec(
        repoId: "mlx-community/bge-m3-mlx-fp16",
        revision: "a37eddded9a6a1273a87fb8b0da0d1cdbd98aeec",   // pinned, same reason
        profile: .plain,
        needsXLMPositionIds: true,
        downloadPatterns: ["*.safetensors", "*.json", "*.txt"])

    /// HubApi download base under Parla's Application Support. A settable `var` so tests redirect it to a temp dir
    /// (mirror of `MLXModelSpec.downloadBase` / `HistoryStore.fileURL`) — else `isDownloaded()` reads the real model.
    nonisolated(unsafe) static var downloadBase: URL = defaultDownloadBase()
    /// `internal` (not private) so tests can assert the PRODUCTION location even while
    /// `downloadBase` itself is redirected to a temp dir for isolation.
    static func defaultDownloadBase() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return StorageRoot.defaultURL().appendingPathComponent("embed", isDirectory: true)
    }

    /// Where `HubApi.snapshot` materializes the active model.
    public static func modelDirectory() -> URL {
        downloadBase.appendingPathComponent("models/\(active.repoId)", isDirectory: true)
    }

    /// "Downloaded" = a COMPLETE-enough snapshot (config + tokenizer files + a weight shard), so an interrupted
    /// download isn't reported ready. Cheap, synchronous — drives availability + the embed gate. Mirrors `MLXModelSpec`.
    public static func isDownloaded() -> Bool {
        MLXHubDownloader.isSnapshotComplete(at: modelDirectory())
    }

    /// Bytes on disk for the "disk used" line / delete recompute. 0 if absent.
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

/// Loads the active embedding model (actor-internal, single-flight) and produces pooled, L2-normalized vectors.
/// Returns nil until the model is downloaded (graceful — callers degrade to lexical search / NL "Related").
public actor MLXTextEmbedder: TextEmbedder {
    public static let shared = MLXTextEmbedder()

    private var container: EmbedderModelContainer?
    private var loadTask: Task<EmbedderModelContainer?, Never>?
    private var generation = 0   // bumped by unload()/delete → a load in flight won't cache a now-stale model

    /// Get-or-load the container, single-flight. nil if the model isn't downloaded or the load fails.
    private func loaded() async -> EmbedderModelContainer? {
        if let container { return container }
        if let loadTask { return await loadTask.value }
        guard EmbeddingModelSpec.isDownloaded() else { return nil }
        let gen = generation
        let task = Task { () -> EmbedderModelContainer? in
            try? await EmbedderModelFactory.shared.loadContainer(
                from: MLXHubDownloader(downloadBase: EmbeddingModelSpec.downloadBase),
                using: MLXTokenizerLoader(),
                configuration: ModelConfiguration(id: EmbeddingModelSpec.active.repoId))
        }
        loadTask = task
        let c = await task.value
        // TOCTOU: if unload()/delete landed during the load, `generation` moved — don't cache a just-deleted model
        // in RAM (mirrors MLXLLMService.loadContainer's guard; a background semantic refresh racing deleteEmbedModel
        // could otherwise resurrect ~0.4GB the delete was meant to free). The retrievalEmbedder routes by disk
        // presence, so ranking is unaffected either way. Clear loadTask ONLY when it's still ours (past the guard) —
        // if unload cancelled + a concurrent loaded() installed a fresh task, nil-ing here would orphan it → a
        // duplicate model load. (and the clobber it opened.)
        guard gen == generation else { return nil }
        loadTask = nil
        container = c
        return c
    }

    /// Drop the model from RAM (after a re-embed batch, or on delete). The next embed re-loads on demand. Bumps
    /// `generation` + cancels any in-flight load so a delete-during-load can't cache the deleted model afterward.
    public func unload() {
        container = nil
        loadTask?.cancel()
        loadTask = nil
        generation &+= 1
    }

    /// Download (or refresh from cache) the model files WITHOUT loading them into memory — the explicit "Download"
    /// action. A later `embed()` loads lazily from this cache.
    public func downloadModel(progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }) async throws {
        _ = try await MLXHubDownloader(downloadBase: EmbeddingModelSpec.downloadBase)
            .download(id: EmbeddingModelSpec.active.repoId, revision: EmbeddingModelSpec.active.revision,
                      matching: EmbeddingModelSpec.active.downloadPatterns, useLatest: false, progressHandler: progressHandler)
    }

    public func embed(_ text: String, language: String, kind: EmbedKind) async -> Embedding? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let c = await loaded() else { return nil }
        let input = EmbeddingModelSpec.active.profile.decorate(clean, kind: kind)
        return await c.perform { ctx -> Embedding? in
            let ids = ctx.tokenizer.encode(text: input, addSpecialTokens: true)
            guard !ids.isEmpty else { return nil }
            // One text at a time → no padding, so last-token pooling (Qwen3) is exact and we avoid the
            // pad==eos masking footgun. positionIds nil is correct for Qwen3 (RoPE); an XLM-R swap (BGE-M3/e5)
            // would compute explicit positionIds here, gated on `EmbeddingModelSpec.active.needsXLMPositionIds`.
            let arr = MLXArray(ids).reshaped([1, ids.count])
            let mask = MLXArray.ones([1, ids.count])
            let tokenTypes = MLXArray.zeros(like: arr)
            let out = ctx.model(arr, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: mask)
            let pooled = ctx.pooling(out, mask: mask, normalize: true, applyLayerNorm: false)
            pooled.eval()
            return pooled.map { $0.asArray(Float.self) }[0].map(Double.init)
        }
    }

    /// Not used by retrieval — the per-token (extractive/keyword) path stays on `NLEmbedder`. nil here.
    public func tokenVectors(_ text: String, language: String) async -> [(range: Range<String.Index>, vector: Embedding)]? { nil }
}
#endif  // os(macOS) — MLX download-tier embedder
