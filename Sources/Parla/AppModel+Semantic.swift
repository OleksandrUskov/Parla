import Foundation

// MARK: - Semantic index orchestration (Local-AI Layer P1c)

extension AppModel {
    /// Backfill embeddings for history items that don't have one yet, then persist. Best-effort: an item
    /// the embedder can't vectorize (assets not downloaded, unsupported language, empty text) is skipped
    /// and retried on a later pass. Heavy compute lives in the embedder actor (off the main actor); this
    /// only awaits, so it never blocks the UI — and it never touches the transcript pipeline.
    func backfillEmbeddings() async {
        var store = EmbeddingStore.load()
        let missing = history.filter { store[$0.id] == nil }
        guard !missing.isEmpty else { return }
        for item in missing {
            if let vector = await embedder.embed(embedText(for: item), language: item.language) {
                store[item.id] = vector
            }
        }
        EmbeddingStore.save(store)
    }
}
