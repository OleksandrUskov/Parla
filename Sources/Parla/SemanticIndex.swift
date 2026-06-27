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

/// Persisted per-item embedding vectors in ~/Library/Application Support/Parla/embeddings.json, keyed by
/// item id. Derived from `HistoryStore.fileURL`'s directory (like `AudioStore`) → moves to a temp path in
/// tests for free (no separate seam). Stored as `[uuidString: [Double]]` for a clean JSON object.
enum EmbeddingStore {
    static var fileURL: URL {
        HistoryStore.fileURL.deletingLastPathComponent().appendingPathComponent("embeddings.json")
    }

    static func load() -> [UUID: Embedding] {
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? JSONDecoder().decode([String: Embedding].self, from: data) else { return [:] }
        var out: [UUID: Embedding] = [:]
        for (key, vector) in raw { if let id = UUID(uuidString: key) { out[id] = vector } }
        return out
    }

    static func save(_ map: [UUID: Embedding]) {
        let raw = Dictionary(uniqueKeysWithValues: map.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Drop vectors for the given ids (on delete/clear), mirroring `AudioStore.remove`. No-op if none present.
    static func remove(_ ids: Set<UUID>) {
        var map = load()
        let before = map.count
        for id in ids { map[id] = nil }
        if map.count != before { save(map) }
    }

    /// Drop vectors not referenced by any live item (mirrors `AudioStore.pruneOrphans`) — reclaims orphans
    /// from deletes and neutralizes a vector re-created for an item deleted mid-embed. Saves only on change.
    static func pruneOrphans(keeping live: Set<UUID>) {
        let map = load()
        let kept = map.filter { live.contains($0.key) }
        if kept.count != map.count { save(kept) }
    }
}

/// Text to embed for an item: the transcript body prefix (caps cost on long notes), prefixed with the
/// title only when there's a real one (a raw filename like `msg123.ogg` would just be noise). Pure.
func embedText(for item: TranscriptItem, maxChars: Int = 1000) -> String {
    let body = String(item.text.prefix(maxChars))
    return item.displayTitle == item.sourceName ? body : item.displayTitle + ". " + body
}

/// Cap a sentence into a short, clean title: trim, collapse runs of whitespace, cut at a word boundary
/// near `maxChars` with an ellipsis. Pure. (The "central sentence" title style.)
func conciseTitle(from sentence: String, maxChars: Int = 60) -> String {
    let clean = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    guard clean.count > maxChars else { return clean }
    let cut = clean.prefix(maxChars)
    if let lastSpace = cut.lastIndex(of: " ") {
        return cut[..<lastSpace].trimmingCharacters(in: .whitespaces) + "…"
    }
    return cut + "…"
}

/// Rank candidate terms by frequency (case-insensitive), keeping the first-seen casing, top `max`.
/// Stable on ties (first-seen order). Pure — the lexical extractor (NLTagger) feeds this for the
/// keyword-phrase title style.
func topTerms(_ terms: [String], max k: Int) -> [String] {
    var count: [String: Int] = [:]
    var firstSeen: [String: String] = [:]
    var order: [String] = []
    for term in terms {
        let key = term.lowercased()
        if count[key] == nil { firstSeen[key] = term; order.append(key) }
        count[key, default: 0] += 1
    }
    let ranked = order.enumerated().sorted { a, b in
        count[a.element]! != count[b.element]! ? count[a.element]! > count[b.element]! : a.offset < b.offset
    }
    return ranked.prefix(k).compactMap { firstSeen[$0.element] }
}

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

    /// From per-sentence vectors, pick the most-central sentence (the title) and the top-`summaryCount`
    /// central sentences (the summary, returned in original document order for readability). Builds the
    /// cosine-similarity matrix and ranks by TextRank centrality. nil for empty; n==1 → (0, [0]). Pure.
    static func extractiveSelection(_ vectors: [Embedding], summaryCount: Int) -> (title: Int, summary: [Int])? {
        let n = vectors.count
        guard n > 0 else { return nil }
        guard n > 1 else { return (0, [0]) }
        var sim = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let c = cosine(vectors[i], vectors[j])
                sim[i][j] = c; sim[j][i] = c
            }
        }
        let byScore = textRank(similarity: sim).enumerated()
            .sorted { $0.element > $1.element }.map { $0.offset }
        let title = byScore[0]
        let summary = Array(byScore.prefix(max(1, summaryCount))).sorted()   // document order, not score order
        return (title, summary)
    }

    /// How many keywords to keep from descending cosine scores — instead of a hardcoded count. Aims for a
    /// MEANINGFUL band: at least `minKeywords` whenever that many candidates exist (so a note never shows a
    /// single lonely tag), up to `hardCap`, with the relative-to-top band + elbow choosing WITHIN that range
    /// (more tags only when several are genuinely on-topic). Returns 0 only when there are no candidates. Pure.
    static func dynamicKeywordCount(scores: [Double], minKeywords: Int = 3, hardCap: Int = 6,
                                    relBand: Double = 0.80, elbowGap: Double = 0.06) -> Int {
        guard let top = scores.first else { return 0 }
        var k = 1
        while k < scores.count, k < hardCap {
            let score = scores[k]
            if score < relBand * top { break }            // outside the relative-to-top band
            if scores[k - 1] - score > elbowGap { break } // sharp drop from the previous (elbow)
            k += 1
        }
        let lower = Swift.min(minKeywords, scores.count)   // at least minKeywords, but not more than we have
        let upper = Swift.min(hardCap, scores.count)
        return Swift.min(Swift.max(k, lower), upper)
    }

    /// Maximal Marginal Relevance: greedily pick `count` items balancing relevance (`scores`, descending)
    /// against diversity (cosine to already-picked) so tags aren't near-duplicates. `lambda` leans
    /// relevance. Returns indices into the input, best first. Pure. Validated by research (EmbedRank/KeyBERT).
    static func mmr(scores: [Double], vectors: [Embedding], count: Int, lambda: Double = 0.6) -> [Int] {
        guard count > 0, !scores.isEmpty else { return [] }
        var selected: [Int] = []
        var remaining = Array(scores.indices)
        while selected.count < Swift.min(count, scores.count), !remaining.isEmpty {
            var best = remaining[0], bestValue = -Double.infinity
            for i in remaining {
                let diversity = selected.map { cosine(vectors[i], vectors[$0]) }.max() ?? 0
                let value = lambda * scores[i] - (1 - lambda) * diversity
                if value > bestValue { bestValue = value; best = i }
            }
            selected.append(best)
            remaining.removeAll { $0 == best }
        }
        return selected
    }

    /// The centroid (mean) of a set of vectors, or nil if empty / dim-0. Used to mean-center embeddings
    /// before cosine — the standard fix for NLContextualEmbedding's anisotropy (raw same-script cosines all
    /// cluster ~0.6–0.96, so an absolute threshold can't discriminate; centering opens the dynamic range).
    static func centroid(_ vectors: [Embedding]) -> Embedding? {
        guard let dim = vectors.first?.count, dim > 0 else { return nil }
        var sum = [Double](repeating: 0, count: dim)
        var n = 0
        for v in vectors where v.count == dim { for i in 0..<dim { sum[i] += v[i] }; n += 1 }
        guard n > 0 else { return nil }
        return sum.map { $0 / Double(n) }
    }

    /// Element-wise `a − b` (mean-centering). Returns `a` unchanged on a dim mismatch.
    static func centered(_ a: Embedding, by mean: Embedding) -> Embedding {
        guard a.count == mean.count else { return a }
        return zip(a, mean).map(-)
    }

    /// Mean-pool per-token vectors into one document vector (the standard way to turn `NLContextualEmbedding`'s
    /// per-token output into a single sentence/item embedding). nil for no tokens or zero-dim. Pure.
    static func meanPool(_ vectors: [[Double]]) -> Embedding? {
        guard let dim = vectors.first?.count, dim > 0 else { return nil }
        var sum = [Double](repeating: 0, count: dim)
        var n = 0
        for v in vectors where v.count == dim {
            for i in 0..<dim { sum[i] += v[i] }
            n += 1
        }
        guard n > 0 else { return nil }
        return sum.map { $0 / Double(n) }
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
