import Foundation

// MARK: - Semantic core (Local-AI Layer P1a)
//
// The pure ranking math behind semantic search + extractive title/summary: cosine similarity, top-K
// nearest, and TextRank centrality over a sentence-similarity matrix. No framework, no I/O —
// deterministic and unit-tested. The `NLContextualEmbedding` vector producer (P1b), the persisted
// `EmbeddingStore` (P1c), and the UI (P1d+) build on top. RU/UK-capable on the macOS-14 floor with no
// model download (the whole reason this lands before the LLM tiers). See
// `LOCAL_AI_LAYER.md` §2c.

/// An embedding vector. `Double` matches `NLContextualEmbedding`'s output; the math stays exact.
typealias Embedding = [Double]

enum SemanticIndex {
    /// Cosine similarity in [-1, 1]. Returns 0 for a length mismatch, an empty vector, or a zero-norm
    /// vector (all degenerate → treated as "unrelated" rather than trapping).
    static func cosine(_ a: Embedding, _ b: Embedding) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na  += a[i] * a[i]
            nb  += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// The `k` vectors most similar to `query`, score ≥ `minScore`, best first (index + score). Ties
    /// keep input order (stable). k ≤ 0 or empty input → []. Used by search to rank history items.
    static func topK(_ query: Embedding, in vectors: [Embedding],
                     k: Int, minScore: Double = 0) -> [(index: Int, score: Double)] {
        guard k > 0, !vectors.isEmpty else { return [] }
        let scored = vectors.enumerated()
            .map { (index: $0.offset, score: cosine(query, $0.element)) }
            .filter { $0.score >= minScore }
            .sorted { $0.score > $1.score }
        return Array(scored.prefix(k))
    }

    /// TextRank centrality over a symmetric sentence-similarity matrix → a salience score per sentence
    /// (PageRank-style power iteration on the row-normalized graph with damping). Higher = more central
    /// to the document → the sentences an extractive title/summary should pick. Pure; converges fast.
    /// `n == 0 → []`, `n == 1 → [1.0]`. Negative similarities are clamped to 0 (cosine can go negative).
    static func textRank(similarity: [[Double]], damping: Double = 0.85, iterations: Int = 30) -> [Double] {
        let n = similarity.count
        guard n > 1 else { return n == 1 ? [1.0] : [] }
        // Row-normalize outgoing weights (each sentence distributes a unit of vote); an isolated row
        // (no positive links) votes uniformly so it can't sink the iteration.
        var weight = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            var rowSum = 0.0
            for j in 0..<n where j != i { rowSum += max(0, similarity[i][j]) }
            for j in 0..<n where j != i {
                weight[i][j] = rowSum > 0 ? max(0, similarity[i][j]) / rowSum : 1.0 / Double(n - 1)
            }
        }
        var score = [Double](repeating: 1.0 / Double(n), count: n)
        for _ in 0..<iterations {
            var next = [Double](repeating: (1 - damping) / Double(n), count: n)
            for i in 0..<n {
                for j in 0..<n where j != i {
                    next[i] += damping * weight[j][i] * score[j]   // incoming votes from j → i
                }
            }
            score = next
        }
        return score
    }
}
