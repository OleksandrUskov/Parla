import Foundation

// MARK: - Semantic index orchestration (Local-AI Layer P1c/P1d)

extension AppModel {
    /// The sidebar label for an item, per the chosen style: the extractive key sentence (persisted
    /// `title`, falling back to sourceName), a live keyword phrase (falling back to the sentence/name),
    /// or the raw file name. Keyword extraction is cheap and lazy (computed per visible row).
    func sidebarTitle(for item: TranscriptItem) -> String {
        switch sidebarTitleStyle {
        case .filename: return item.sourceName
        case .sentence: return item.displayTitle
        case .keywords:
            let phrase = keywordPhrase(from: item.text)
            return phrase.isEmpty ? item.displayTitle : phrase
        }
    }

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
        } while semanticRefreshPending
    }

    /// Compute + persist an extractive title (most-central sentence) + summary for history items that
    /// don't have a title yet (all embeddable languages). Best-effort + patches by id (history may shift
    /// across the awaits). The keyword-phrase title style is derived live at display, not stored here.
    func backfillInsights() async {
        let targets = history.filter { $0.title == nil }
        guard !targets.isEmpty else { return }
        var changed = false
        for item in targets {
            guard let result = await extractiveInsights(for: item),
                  let idx = history.firstIndex(where: { $0.id == item.id }) else { continue }
            history[idx].title = result.title
            history[idx].summary = result.summary
            history[idx].aiModel = "extractive"
            changed = true
        }
        if changed { HistoryStore.save(history) }
    }

    /// Backfill search embeddings for items missing a vector, then persist. Best-effort: an item the
    /// embedder can't vectorize (assets not downloaded, unsupported language, empty text) is skipped and
    /// retried on a later pass. The compute lives in the embedder actor (off the main actor).
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

    /// Extractive (title, summary?) for an item via per-sentence embeddings, or nil if it can't be
    /// embedded (assets missing → bail early). Summary only when the note is long enough to be worth
    /// condensing; a one/two-sentence voice message gets a title but no summary.
    func extractiveInsights(for item: TranscriptItem) async -> (title: String, summary: String?)? {
        let sents = sentences(in: item.text)
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
        return (title, summary)
    }
}
