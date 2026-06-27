import Foundation

// MARK: - Semantic index orchestration (Local-AI Layer P1c/P1d)

extension AppModel {
    /// The sidebar label for an item: the title (AI/extractive or hand-edited, falling back to sourceName)
    /// when titles are on, else the raw file name (the feature fully off).
    func sidebarTitle(for item: TranscriptItem) -> String {
        showTitles ? item.displayTitle : item.sourceName
    }

    /// Rename an item's title by hand (the 5% who want a different label). Sets `titleEdited` so a later
    /// regeneration never overwrites it; an empty title reverts to the generated/sourceName fallback.
    /// Returns whether anything changed.
    @discardableResult
    func setTitle(_ raw: String, for id: TranscriptItem.ID) -> Bool {
        guard let idx = history.firstIndex(where: { $0.id == id }) else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle: String? = trimmed.isEmpty ? nil : trimmed
        guard newTitle != history[idx].title else { return false }
        history[idx].title = newTitle
        history[idx].titleEdited = newTitle == nil ? nil : true   // empty → back to auto; else pinned
        if newTitle == nil { history[idx].aiModel = nil }         // cleared → re-eligible for regeneration next pass
        HistoryStore.save(history)
        return true
    }

    /// "Related notes" to the currently open item, in relevance order — shown in its card. These are whole
    /// notes close BY MEANING to the open one (doc↔doc), NOT search results.
    var relatedHistory: [TranscriptItem] {
        relatedIDs.compactMap { id in history.first { $0.id == id } }
    }

    /// Recompute "Related notes" for the OPEN item: rank other notes by doc↔doc meaning-similarity.
    ///
    /// IMPORTANT — why doc↔doc and not query→doc: `NLContextualEmbedding` is a *contextual* model; a short
    /// search string embeds to a near-degenerate vector dominated by a constant background direction, so ALL
    /// short queries collapse together and query→note ranking is no better than noise (empirically verified —
    /// see LOCAL_AI_LAYER.md §5). Whole-note↔whole-note comparison DOES separate topics, so "Related" attaches
    /// to the open note rather than the search box. Real query→note semantic search is a download-tier job (P3).
    ///
    /// Robust to the embedding's anisotropy by mean-centering on the same-script corpus (cross-script vectors
    /// live in a different space). Pure in-memory (`embeddingIndex`); best-effort — no vector / no peers → none.
    func refreshRelatedNotes() {
        guard let item = selectedItem, let selfVec = embeddingIndex[item.id] else { relatedIDs = []; return }
        let script = dominantScript(item.text)
        let pool = history.filter { $0.id != item.id && embeddingIndex[$0.id] != nil && dominantScript($0.text) == script }
        // Need ≥2 peers: mean-centering over a 2-element set {peer, self} puts them at EXACTLY opposite
        // directions (cosine −1) regardless of content, so a single peer could never clear the floor. Below
        // that the corpus is too small for the anisotropy estimate to mean anything — suppress deliberately.
        guard pool.count >= 2 else { relatedIDs = []; return }
        let vectors = pool.map { embeddingIndex[$0.id]! }
        guard let mean = SemanticIndex.centroid(vectors + [selfVec]) else { relatedIDs = []; return }
        let q = SemanticIndex.centered(selfVec, by: mean)
        let scored = vectors.enumerated()
            .map { (index: $0.offset, score: SemanticIndex.cosine(q, SemanticIndex.centered($0.element, by: mean))) }
            .sorted { $0.score > $1.score }
        guard let top = scored.first?.score, top > Self.relatedFloor else { relatedIDs = []; return }
        // Absolute floor (genuinely related, not "least unrelated") + relative gate (drop a weak tail when one
        // note is clearly closer). Empty when nothing is close — never pads. Capped small; this is a suggestion.
        relatedIDs = scored.filter { $0.score >= Swift.max(Self.relatedFloor, 0.6 * top) }
            .prefix(3).map { pool[$0.index].id }
    }

    /// Min centered doc↔doc cosine to count as "related". Calibrated on real data (LOCAL_AI_LAYER.md §5):
    /// true topic pairs land ≈0.4–0.7, unrelated/noise notes go negative; 0.30 keeps the former, drops the latter.
    static var relatedFloor: Double { 0.30 }

    /// Refresh the whole semantic layer: extractive title/summary, then search embeddings. Single-flight
    /// — a change that arrives mid-run schedules exactly one more pass after (so the new item is picked up
    /// without overlapping writes to history.json / embeddings.json). Safe to call from launch and after
    /// every transcription. All compute is best-effort and off the main actor; it never blocks the UI or
    /// the transcript pipeline.
    func refreshSemanticIndex() async {
        if semanticRefreshInFlight { semanticRefreshPending = true; return }
        semanticRefreshInFlight = true
        defer { semanticRefreshInFlight = false }
        repeat {
            semanticRefreshPending = false
            await backfillInsights()
            await backfillEmbeddings()
            backfillLemmas()
        } while semanticRefreshPending
        refreshRelatedNotes()   // the index just grew/shrank → refresh the open note's "Related"
    }

    /// Build/refresh the per-item lemma index used by morphology-aware search — for items missing from it,
    /// and pruning orphans (mirrors `backfillEmbeddings`). NLTagger lemmas need no asset download and are
    /// cheap, so this is synchronous. Kept in memory only (rebuilt on launch; trivial for a real history).
    func backfillLemmas() {
        let live = Set(history.map(\.id))
        var index = lemmaIndex.filter { live.contains($0.key) }   // prune orphans (deleted items)
        for item in history where index[item.id] == nil {
            index[item.id] = lemmaSet(of: item.text, language: item.language)
        }
        if index != lemmaIndex { lemmaIndex = index }   // single observed write (no per-item re-render storm)
    }

    /// Compute + persist extractive insights (title, summary, embedding-ranked keywords) for items not yet
    /// processed by the current pipeline (`aiModel != extractiveModelTag`) — covers new items and upgrades
    /// pre-keyword records once. All embeddable languages, best-effort, patched by id (history may shift
    /// across the awaits). A user-edited title is never overwritten; assets-missing items are left unmarked
    /// so they retry on a later pass.
    func backfillInsights() async {
        let targets = history.filter { $0.aiModel != Self.extractiveModelTag }
        guard !targets.isEmpty else { return }
        var changed = false
        for item in targets {
            guard let result = await extractiveInsights(for: item),
                  let idx = history.firstIndex(where: { $0.id == item.id }) else { continue }
            if history[idx].title == nil, history[idx].titleEdited != true { history[idx].title = result.title }
            if let summary = result.summary { history[idx].summary = summary }
            if !result.keywords.isEmpty { history[idx].keywords = result.keywords }
            history[idx].aiModel = Self.extractiveModelTag
            changed = true
        }
        if changed { HistoryStore.save(history) }
    }

    /// Provenance tag for the current extractive pipeline; bumped when the pipeline gains a capability so
    /// older records reprocess once (v2 = embedding-ranked keywords; v3 = morphology filter + dynamic count
    /// + MMR; v4 = in-context candidate vectors; v5 = min-3 keyword count + isolated fallback).
    static var extractiveModelTag: String { "extractive-v5" }

    /// Backfill search embeddings for items missing a vector, then persist. Best-effort: an item the
    /// embedder can't vectorize (assets not downloaded, unsupported language, empty text) is skipped and
    /// retried on a later pass. The compute lives in the embedder actor (off the main actor).
    func backfillEmbeddings() async {
        // Embed missing items into a LOCAL map; don't mutate the persisted store across the awaits.
        let initial = EmbeddingStore.load()
        var fresh: [UUID: Embedding] = [:]
        for item in history where initial[item.id] == nil {
            if let vector = await embedder.embed(embedText(for: item), language: item.language) {
                fresh[item.id] = vector
            }
        }
        // TOCTOU re-validate (mirror pruneAudioCache): a delete/edit may have run on the main actor during an
        // await. Re-read the store + live set NOW so we don't resurrect a vector saveEdit/delete just removed,
        // and add a freshly-computed vector only if its item is still live AND still missing on disk.
        var store = EmbeddingStore.load()
        let live = Set(history.map(\.id))
        var changed = false
        for (id, vector) in fresh where live.contains(id) && store[id] == nil { store[id] = vector; changed = true }
        let pruned = store.filter { live.contains($0.key) }
        if pruned.count != store.count { store = pruned; changed = true }
        if changed { EmbeddingStore.save(store) }
        embeddingIndex = store   // in-memory mirror == the just-persisted, re-validated store (no orphan, honors edits)
    }

    /// Extractive (title, summary?, keywords) for an item via per-sentence embeddings, or nil if it can't
    /// be embedded (assets missing → bail early). Summary only when the note is long enough to be worth
    /// condensing; a one/two-sentence voice message gets a title but no summary.
    func extractiveInsights(for item: TranscriptItem) async -> (title: String, summary: String?, keywords: [String])? {
        // Cap the extractive pass: the similarity matrix is O(n²) and the per-sentence embeds add up, so a
        // very long / chunked transcript would otherwise stall. The lead ~120 sentences carry the gist.
        let sents = Array(sentences(in: item.text).prefix(120))
        guard !sents.isEmpty else { return nil }
        var vectors: [Embedding] = []
        vectors.reserveCapacity(sents.count)
        for sentence in sents {
            guard let vector = await embedder.embed(sentence, language: item.language) else { return nil }
            vectors.append(vector)
        }
        guard let selection = SemanticIndex.extractiveSelection(vectors, summaryCount: 3) else { return nil }
        let title = conciseTitle(from: sents[selection.title])
        let summary = sents.count > 4 ? selection.summary.map { sents[$0] }.joined(separator: " ") : nil
        let keywords = await rankedKeywords(for: item)
        return (title, summary, keywords)
    }

    /// KeyBERT-style keyword ranking, IN CONTEXT: embed the note ONCE (per-token vectors), pool each
    /// candidate's vector from the token vectors at its actual occurrences (so a word's meaning reflects how
    /// it was used, not a generic out-of-context embedding), score by cosine to the document vector, choose
    /// HOW MANY dynamically (relevance floor + relative-to-top band + elbow + length cap → few or zero when
    /// weak), then MMR-select for diversity. Best-effort: nil/empty at any step → no keywords.
    private func rankedKeywords(for item: TranscriptItem) async -> [String] {
        let source = String(item.text.prefix(1200)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty,
              let tokens = await embedder.tokenVectors(source, language: item.language), !tokens.isEmpty,
              let document = SemanticIndex.meanPool(tokens.map(\.vector)) else { return [] }
        let candidates = keywordCandidatesWithRanges(from: source, language: item.language, max: 16)
        guard !candidates.isEmpty else { return [] }
        var terms: [String] = [], vectors: [Embedding] = [], scores: [Double] = []
        for candidate in candidates {
            let pooled = tokens.filter { token in candidate.ranges.contains { token.range.overlaps($0) } }.map(\.vector)
            // In-context vector; if the candidate's ranges didn't line up with any token (rare), fall back to
            // embedding the term on its own so a good keyword is never silently lost.
            var vector = SemanticIndex.meanPool(pooled)
            if vector == nil { vector = await embedder.embed(candidate.term, language: item.language) }
            guard let vector else { continue }
            terms.append(candidate.term); vectors.append(vector); scores.append(SemanticIndex.cosine(vector, document))
        }
        guard !scores.isEmpty else { return [] }
        let order = scores.indices.sorted { scores[$0] > scores[$1] }   // by relevance, descending
        let sortedTerms = order.map { terms[$0] }
        let sortedVectors = order.map { vectors[$0] }
        let sortedScores = order.map { scores[$0] }
        let count = SemanticIndex.dynamicKeywordCount(scores: sortedScores)
        guard count > 0 else { return [] }
        return SemanticIndex.mmr(scores: sortedScores, vectors: sortedVectors, count: count).map { sortedTerms[$0] }
    }
}
