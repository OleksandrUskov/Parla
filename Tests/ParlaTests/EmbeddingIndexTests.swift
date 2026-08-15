import XCTest
import os
import AVFoundation
import AppKit
@testable import ParlaCore
@testable import Parla

/// The semantic index: cosine/topK/TextRank, EmbeddingStore, the provenance tag that forces a re-embed, and the backfill's TOCTOU guard.
final class EmbeddingIndexTests: ParlaLogicTestCase {
    // MARK: - Semantic core (cosine / topK / TextRank)

    func testCosineSimilarity() {
        XCTAssertEqual(SemanticIndex.cosine([1, 0, 0], [1, 0, 0]), 1.0, accuracy: 1e-9)   // identical
        XCTAssertEqual(SemanticIndex.cosine([1, 0], [0, 1]), 0.0, accuracy: 1e-9)         // orthogonal
        XCTAssertEqual(SemanticIndex.cosine([1, 1], [-1, -1]), -1.0, accuracy: 1e-9)      // opposite
        XCTAssertEqual(SemanticIndex.cosine([2, 0], [5, 0]), 1.0, accuracy: 1e-9)         // scale-invariant
        XCTAssertEqual(SemanticIndex.cosine([1, 2, 3], [1, 2]), 0.0)   // length mismatch → 0, no trap
        XCTAssertEqual(SemanticIndex.cosine([0, 0], [1, 1]), 0.0)      // zero-norm → 0
        XCTAssertEqual(SemanticIndex.cosine([], []), 0.0)             // empty → 0
    }

    func testTopK() {
        let vectors: [Embedding] = [[1, 0], [0.9, 0.1], [0, 1], [-1, 0]]
        let ranked = SemanticIndex.topK([1, 0], in: vectors, k: 2)
        XCTAssertEqual(ranked.map { $0.index }, [0, 1])               // most-similar first
        XCTAssertGreaterThan(ranked[0].score, ranked[1].score)        // strictly ordered
        // minScore filters out the orthogonal/opposite ones even if k asks for more.
        let positives = SemanticIndex.topK([1, 0], in: vectors, k: 10, minScore: 0.5)
        XCTAssertEqual(positives.map { $0.index }, [0, 1])
        XCTAssertTrue(SemanticIndex.topK([1, 0], in: vectors, k: 0).isEmpty)        // k=0 → []
        XCTAssertTrue(SemanticIndex.topK([1, 0], in: [], k: 3).isEmpty)             // empty index → []
    }

    func testMeanPool() {
        XCTAssertEqual(SemanticIndex.meanPool([[1, 2], [3, 4]]), [2, 3])        // column-wise mean
        XCTAssertEqual(SemanticIndex.meanPool([[5, -5, 0]]), [5, -5, 0])        // single token = itself
        XCTAssertNil(SemanticIndex.meanPool([]))                               // no tokens → nil
        XCTAssertNil(SemanticIndex.meanPool([[]]))                             // zero-dim → nil
        XCTAssertEqual(SemanticIndex.meanPool([[1, 1], [9], [3, 3]]), [2, 2])  // ragged row skipped, not crashed
    }

    func testTextRankEdgeCases() {
        XCTAssertTrue(SemanticIndex.textRank(similarity: []).isEmpty)               // n=0 → []
        XCTAssertEqual(SemanticIndex.textRank(similarity: [[1]]), [1.0])            // n=1 → [1.0]
        // Uniform graph → equal centrality.
        let uniform = SemanticIndex.textRank(similarity: [[0, 1, 1], [1, 0, 1], [1, 1, 0]])
        XCTAssertEqual(uniform[0], uniform[1], accuracy: 1e-6)
        XCTAssertEqual(uniform[1], uniform[2], accuracy: 1e-6)
    }

    func testTextRankRanksCentralSentenceHighest() {
        // Sentence 0 is similar to everyone; 1–3 are similar only to 0 (a star graph) → 0 is most central.
        let sim: [[Double]] = [
            [0.0, 0.9, 0.9, 0.9],
            [0.9, 0.0, 0.1, 0.1],
            [0.9, 0.1, 0.0, 0.1],
            [0.9, 0.1, 0.1, 0.0],
        ]
        let scores = SemanticIndex.textRank(similarity: sim)
        let top = scores.enumerated().max { $0.element < $1.element }!.offset
        XCTAssertEqual(top, 0, "the hub sentence should be the most central")
        XCTAssertTrue(scores.allSatisfy { $0 > 0 && $0.isFinite })
    }


    // MARK: - EmbeddingStore + embedText + backfill

    @MainActor func testEmbeddingStoreRoundtrip() {
        withTemporaryHistoryStore {
            let a = UUID(), b = UUID()
            EmbeddingStore.save([a: [0.1, 0.2, 0.3], b: [1, 0]])
            let back = EmbeddingStore.load()
            XCTAssertEqual(back[a], [0.1, 0.2, 0.3])
            XCTAssertEqual(back[b], [1, 0])
            XCTAssertEqual(back.count, 2)
        }
    }

    @MainActor func testEmbeddingStoreMissingFileIsEmpty() {
        withTemporaryHistoryStore {
            XCTAssertTrue(EmbeddingStore.load().isEmpty)   // no file → empty, no crash
        }
    }

    func testEmbedTextHelper() {
        // No real title (displayTitle == sourceName) → just the body, no filename noise.
        let bare = makeItem(name: "msg.ogg", text: "купить хлеб и молоко")
        XCTAssertEqual(embedText(for: bare), "купить хлеб и молоко")
        // Real title → prepended.
        var titled = makeItem(name: "msg.ogg", text: "тело заметки")
        titled.title = "Покупки"
        XCTAssertEqual(embedText(for: titled), "Покупки. тело заметки")
        // Long body is capped.
        let long = makeItem(text: String(repeating: "а", count: 5000))
        XCTAssertEqual(embedText(for: long, maxChars: 100).count, 100)
    }

    @MainActor func testBackfillEmbeddingsPopulatesStoreOncePerItem() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEmbedder(vector: [0.1, 0.2, 0.3])
            let m = AppModel(engine: FakeEngine(), embedder: fake)
            m.history = [self.makeItem(text: "первый"), self.makeItem(text: "второй")]
            await m.backfillEmbeddings()
            XCTAssertEqual(EmbeddingStore.load().count, 2)
            XCTAssertEqual(fake.calls, 2)
            // Second pass: nothing missing → no re-embed (cheap + stable).
            await m.backfillEmbeddings()
            XCTAssertEqual(fake.calls, 2)
        }
    }

    func testCentroidAndCentered() {
        XCTAssertEqual(SemanticIndex.centroid([[2, 0], [0, 4]]), [1, 2])
        XCTAssertNil(SemanticIndex.centroid([]))
        XCTAssertEqual(SemanticIndex.centered([3, 5], by: [1, 2]), [2, 3])
        XCTAssertEqual(SemanticIndex.centered([1, 2], by: [9]), [1, 2])   // dim mismatch → unchanged
    }

    func testDominantScript() {
        XCTAssertEqual(dominantScript("криптобиржа"), "cyrillic")
        XCTAssertEqual(dominantScript("deadline review"), "latin")
        XCTAssertEqual(dominantScript("проект"), "cyrillic")            // recognizer mislabels this; the script doesn't
        XCTAssertEqual(dominantScript("123 ?!"), "other")
    }

    @MainActor func testEmbeddingStoreRemoveAndPrune() {
        withTemporaryHistoryStore {
            let a = UUID(), b = UUID(), c = UUID()
            EmbeddingStore.save([a: [1], b: [2], c: [3]])
            EmbeddingStore.remove([b])
            XCTAssertNil(EmbeddingStore.load()[b])
            XCTAssertEqual(EmbeddingStore.load().count, 2)
            EmbeddingStore.pruneOrphans(keeping: [a])   // drop everything not in {a}
            XCTAssertEqual(Set(EmbeddingStore.load().keys), [a])
        }
    }

    @MainActor func testRefreshRelatedNotesRanksByDocSimilarity() {
        withTemporaryHistoryStore {
            let m = AppModel(engine: FakeEngine(), embedder: FakeEmbedder(vector: [1, 0, 0]))
            let open = self.makeItem(text: "заметка про криптобиржи и портфель")
            let near = self.makeItem(text: "ещё одна про крипту и стартап")
            let far  = self.makeItem(text: "рецепт домашнего борща")
            m.history = [open, near, far]
            m.selection = open.id
            // In-memory mirror (what refreshRelatedNotes reads). near ∥ open, far ⟂ → after mean-centering
            // near stays positive (> floor) and far goes negative.
            m.embeddingIndex = [open.id: [1, 0, 0], near.id: [1, 0, 0], far.id: [0, 1, 0]]
            m.refreshRelatedNotes()
            XCTAssertEqual(m.relatedIDs, [near.id])   // only the genuinely-close note clears the floor
            // The open note has no vector → no "Related", best-effort.
            m.embeddingIndex[open.id] = nil
            m.refreshRelatedNotes()
            XCTAssertTrue(m.relatedIDs.isEmpty)
        }
    }

    @MainActor func testDeleteAndClearSyncSemanticIndexes() {
        withTemporaryHistoryStore {
            let m = AppModel(engine: FakeEngine(), embedder: FakeEmbedder())
            let a = self.makeItem(text: "первая"), b = self.makeItem(text: "вторая")
            m.history = [a, b]
            m.embeddingIndex = [a.id: [1, 0], b.id: [0, 1]]
            m.lemmaIndex = [a.id: ["первая"], b.id: ["вторая"]]
            EmbeddingStore.save([a.id: [1, 0], b.id: [0, 1]])
            m.delete(a)
            XCTAssertNil(m.embeddingIndex[a.id]); XCTAssertNil(m.lemmaIndex[a.id]); XCTAssertNil(EmbeddingStore.load()[a.id])
            XCTAssertNotNil(m.embeddingIndex[b.id])   // sibling untouched
            m.clearHistory()
            XCTAssertTrue(m.embeddingIndex.isEmpty); XCTAssertTrue(m.lemmaIndex.isEmpty)
            XCTAssertTrue(EmbeddingStore.load().isEmpty); XCTAssertTrue(m.relatedIDs.isEmpty)
        }
    }

    @MainActor func testInvalidateDerivedDataResetsAllButHandTitle() {
        withTemporaryHistoryStore {
            let m = AppModel(engine: FakeEngine(), embedder: FakeEmbedder())
            let a = self.makeItem(text: "текст")
            m.history = [a]; m.selection = a.id
            m.embeddingIndex = [a.id: [1, 0]]; m.lemmaIndex = [a.id: ["текст"]]
            EmbeddingStore.save([a.id: [1, 0]])
            if let i = m.history.firstIndex(where: { $0.id == a.id }) {
                m.history[i].aiModel = "extractive-v6"; m.history[i].title = "Авто"
                m.history[i].summary = "старое саммари"; m.history[i].keywords = ["старое"]
                m.history[i].actions = [ActionItem(text: "старая задача")]
            }
            m.invalidateDerivedData(for: a.id)
            XCTAssertNil(m.embeddingIndex[a.id]); XCTAssertNil(m.lemmaIndex[a.id]); XCTAssertNil(EmbeddingStore.load()[a.id])
            XCTAssertNil(m.history.first?.aiModel)    // insights re-eligible
            XCTAssertNil(m.history.first?.title)      // auto-title cleared so it regenerates from new text
            XCTAssertNil(m.history.first?.summary)    // stale summary dropped (won't be overwritten if new text is short)
            XCTAssertNil(m.history.first?.keywords)   // stale keywords dropped
            XCTAssertNil(m.history.first?.actions)    // stale action items dropped
            // A hand-edited title is preserved.
            if let i = m.history.firstIndex(where: { $0.id == a.id }) { m.history[i].titleEdited = true; m.history[i].title = "Моё" }
            m.invalidateDerivedData(for: a.id)
            XCTAssertEqual(m.history.first?.title, "Моё")
        }
    }

    @MainActor func testRefreshSemanticIndexIsSingleFlight() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine(), embedder: FakeEmbedder())
            m.history = [self.makeItem(text: "что-то")]
            m.semanticRefreshInFlight = true        // pretend a pass is already running
            await m.refreshSemanticIndex()          // must coalesce: set pending + return without doing work
            XCTAssertTrue(m.semanticRefreshPending)
            XCTAssertTrue(m.embeddingIndex.isEmpty) // no overlapping backfill happened
        }
    }


    // MARK: embedding-store provenance tag + re-embed on model switch

    func testEmbeddingStoreModelTagRoundtrip() {
        withTemporaryHistoryStore {
            XCTAssertEqual(EmbeddingStore.loadModelTag(), "")            // no sidecar yet
            EmbeddingStore.saveModelTag("emb:test-model")
            XCTAssertEqual(EmbeddingStore.loadModelTag(), "emb:test-model")
        }
    }

    @MainActor func testBackfillReembedsOnModelSwitch() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine(), embedder: FakeEmbedder(vector: [9, 9, 9]))
            let it = self.makeItem(text: "крипто стартап")
            m.history = [it]
            // A vector tagged with a DIFFERENT model lives in an incomparable space → the backfill must re-embed the
            // whole corpus with the active embedder and stamp the new tag.
            EmbeddingStore.save([it.id: [1, 1, 1]])
            EmbeddingStore.saveModelTag("emb:some-other-model")
            await m.backfillEmbeddings()
            XCTAssertEqual(m.embeddingIndex[it.id], [9, 9, 9])                       // re-embedded by the active fake
            XCTAssertEqual(EmbeddingStore.loadModelTag(), AppModel.nlEmbeddingTag)   // tag updated to the active model
        }
    }

    @MainActor func testBackfillKeepsLegacyVectorsWhenTagEmpty() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine(), embedder: FakeEmbedder(vector: [9, 9, 9]))
            let it = self.makeItem(text: "заметка про работу")
            m.history = [it]
            // A legacy P1 store has NL vectors but NO sidecar; the active model is also NL (nothing downloaded), so
            // an empty tag is treated as NL → the vectors are KEPT, not churned into a re-embed.
            EmbeddingStore.save([it.id: [7, 7, 7]])
            await m.backfillEmbeddings()
            XCTAssertEqual(m.embeddingIndex[it.id], [7, 7, 7])   // preserved (NOT the fake's [9,9,9])
        }
    }

    @MainActor func testFilteredHistoryBlendsSemanticHitsBelowLexical() {
        withTemporaryHistoryStore {
            let m = AppModel(engine: FakeEngine(), embedder: FakeEmbedder())
            let lex = self.makeItem(text: "крипта и биржи")    // literal match for «крипт»
            let sem = self.makeItem(text: "мой стартап")       // no literal match — a semantic-only hit
            let off = self.makeItem(text: "погода сегодня")    // neither
            m.history = [lex, sem, off]
            m.searchQuery = "крипт"
            m.semanticHitIDs = [sem.id, lex.id]                // download-tier ranking (lex is also lexical → not duplicated)
            // Lexical hit first, the semantic-ONLY hit appended below it; the unrelated note excluded.
            XCTAssertEqual(m.filteredHistory.map(\.id), [lex.id, sem.id])
            m.semanticHitIDs = []
            XCTAssertEqual(m.filteredHistory.map(\.id), [lex.id])   // no model / no hits → pure lexical (unchanged behavior)
        }
    }

    @MainActor func testRelatedNotesEmptyForHomogeneousCluster() {
        withTemporaryHistoryStore {
            let m = AppModel(engine: FakeEngine(), embedder: FakeEmbedder())
            let a = self.makeItem(text: "крипта один"), b = self.makeItem(text: "крипта два"), c = self.makeItem(text: "крипта три")
            m.history = [a, b, c]; m.selection = a.id
            // Tight single-topic cluster (near-identical vectors): centering forces them ~120° apart → all below
            // the floor → empty. Documented limitation (a raw fallback would re-admit hubness); pin it deliberately.
            m.embeddingIndex = [a.id: [10, 1, 0], b.id: [10, 0, 1], c.id: [10, 0, 0]]
            m.refreshRelatedNotes()
            XCTAssertTrue(m.relatedIDs.isEmpty)
        }
    }

    @MainActor func testRelatedNotesEmptyBelowFloor() {
        withTemporaryHistoryStore {
            let m = AppModel(engine: FakeEngine(), embedder: FakeEmbedder(vector: [1, 0, 0]))
            let open = self.makeItem(text: "первая заметка про работу"), p1 = self.makeItem(text: "вторая про код")
            let p2 = self.makeItem(text: "третья про спорт")
            m.history = [open, p1, p2]                       // 2 peers → centering is well-posed
            m.selection = open.id
            m.embeddingIndex = [open.id: [1, 0, 0], p1.id: [0, 1, 0], p2.id: [0, 0, 1]]   // mutually orthogonal
            m.refreshRelatedNotes()
            XCTAssertTrue(m.relatedIDs.isEmpty)             // all centered cosines < floor → never padded
        }
    }

    @MainActor func testRelatedNotesNeedTwoPeers() {
        withTemporaryHistoryStore {
            let m = AppModel(engine: FakeEngine(), embedder: FakeEmbedder(vector: [1, 0, 0]))
            let open = self.makeItem(text: "первая заметка о работе"), other = self.makeItem(text: "вторая про работу")
            m.history = [open, other]                        // only 1 peer
            m.selection = open.id
            // Even with identical (clearly related) vectors, a single-peer centroid forces antipodal directions,
            // so "Related" is deliberately suppressed until there are ≥2 peers (≥3 same-script notes).
            m.embeddingIndex = [open.id: [1, 0, 0], other.id: [1, 0, 0]]
            m.refreshRelatedNotes()
            XCTAssertTrue(m.relatedIDs.isEmpty)
        }
    }

    @MainActor func testMorphologySearchMatchesInflections() throws {
        try XCTSkipUnless(hasRussianLemmatizer, "Russian NLTagger lemma asset unavailable on this host")
        withTemporaryHistoryStore {
            let m = AppModel(engine: FakeEngine(), embedder: FakeEmbedder())
            let it = self.makeItem(text: "вчера долго думал о работе и проектах")
            m.history = [it]
            m.backfillLemmas()
            m.searchQuery = "работа"   // not a substring of «работе» — only the lemma matches
            XCTAssertEqual(m.filteredHistory.map(\.id), [it.id])
            // Without the lemma index, plain substring finds nothing (the feature is doing the work).
            XCTAssertTrue(filterHistory(m.history, query: "работа").isEmpty)
        }
    }

    @MainActor func testMorphologySearchInflectedQuery() throws {
        try XCTSkipUnless(hasRussianLemmatizer, "Russian NLTagger lemma asset unavailable on this host")
        withTemporaryHistoryStore {
            let m = AppModel(engine: FakeEngine(), embedder: FakeEmbedder())
            let it = self.makeItem(text: "вчера был на работе целый день")
            m.history = [it]
            m.backfillLemmas()
            // INFLECTED query (not the dictionary form, not a substring of «работе»). Only matches because the
            // query is lemmatized in the script's language too — the regression the review caught.
            m.searchQuery = "работу"
            XCTAssertEqual(m.filteredHistory.map(\.id), [it.id])
        }
    }

    @MainActor func testMorphologySearchIgnoresStoredLanguage() throws {
        try XCTSkipUnless(hasRussianLemmatizer, "Russian NLTagger lemma asset unavailable on this host")
        withTemporaryHistoryStore {
            let m = AppModel(engine: FakeEngine(), embedder: FakeEmbedder())
            let it = self.makeItem(text: "вчера был на работе целый день", lang: "")   // empty stored language
            m.history = [it]
            m.backfillLemmas()
            // Both sides route by SCRIPT (searchLemmaSet), so even an empty/auto item.language still matches —
            // the round-2 fix that unified index+query lemmatization. «работу» → «работа» both sides.
            m.searchQuery = "работу"
            XCTAssertEqual(m.filteredHistory.map(\.id), [it.id])
        }
    }

    func testSearchLemmaSetGatesLatinAndCorrectsIrregulars() throws {
        try XCTSkipUnless(hasRussianLemmatizer, "Russian NLTagger lemma asset unavailable on this host")
        XCTAssertTrue(searchLemmaSet(of: "meeting running build").isEmpty)   // Latin → substring only (no flaky EN lemma)
        XCTAssertTrue(searchLemmaSet(of: "работе").contains("работа"))       // Cyrillic still lemmatized
        XCTAssertTrue(searchLemmaSet(of: "деньги").contains("деньга"))       // irregular override applied
        XCTAssertEqual(searchLemmaSet(of: "денег"), searchLemmaSet(of: "деньги"))   // both collapse to one lemma
        XCTAssertEqual(searchLemmaSet(of: "матери"), searchLemmaSet(of: "мать"))    // мать/матерь irregular unified
        XCTAssertEqual(searchLemmaSet(of: "дочери"), searchLemmaSet(of: "дочь"))    // дочь/дочерь irregular unified
    }

    @MainActor func testMorphologyMatchesDengiIrregular() throws {
        try XCTSkipUnless(hasRussianLemmatizer, "Russian NLTagger lemma asset unavailable on this host")
        withTemporaryHistoryStore {
            let m = AppModel(engine: FakeEngine(), embedder: FakeEmbedder())
            let it = self.makeItem(text: "вчера потратил много денег на еду")
            m.history = [it]
            m.backfillLemmas()
            m.searchQuery = "деньги"   // the headline case: «деньги» (nom) now finds «денег» via the override
            XCTAssertEqual(m.filteredHistory.map(\.id), [it.id])
        }
    }

    @MainActor func testEnrichUpgradesInsightsForSupportedLanguage() async {
        await withTemporaryHistoryStoreAsync {
            let canned = AIInsights(title: "Sprint planning", summary: "Discussed the roadmap.", actions: [ActionItem(text: "Email Bob")])
            let m = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .ready, canned: canned), embedder: FakeEmbedder())
            m.history = [self.makeItem(text: "we discussed the roadmap and i'll email bob", lang: "en")]
            await m.enrichInsights()
            XCTAssertEqual(m.history.first?.title, "Sprint planning")
            XCTAssertEqual(m.history.first?.summary, "Discussed the roadmap.")
            XCTAssertEqual(m.history.first?.actions?.map(\.text), ["Email Bob"])
            XCTAssertEqual(m.history.first?.aiModel, AppModel.foundationModelTag)
        }
    }

    /// RU/UK enrich (MLX backend) tags with the MLX provenance, NOT foundation — so a prompt/model bump
    /// reprocesses only MLX records and the two backends never collide. (Language determines the backend:
    /// FoundationModels + MLX cover disjoint sets.)
    @MainActor func testEnrichTagsRussianWithMLXProvenance() async {
        await withTemporaryHistoryStoreAsync {
            let canned = AIInsights(title: "Планы", summary: "Обсудили дорожную карту.", actions: [ActionItem(text: "позвонить Бобу")])
            let m = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .ready, canned: canned), embedder: FakeEmbedder())
            m.history = [self.makeItem(text: "обсудили дорожную карту, надо позвонить Бобу", lang: "ru")]
            await m.enrichInsights()
            XCTAssertEqual(m.history.first?.title, "Планы")
            XCTAssertEqual(m.history.first?.aiModel, AppModel.mlxModelTag)
            XCTAssertNotEqual(m.history.first?.aiModel, AppModel.foundationModelTag)
        }
    }

    /// EN→MLX fallback: MLX now declares English among its supported languages, so an EN note can be served by the
    /// downloaded model when FoundationModels isn't usable (Apple Intelligence off). Until downloaded, EN reaches the
    /// actionable .needsModelDownload (not .languageUnsupported). DefaultAIService still tries FoundationModels FIRST.
    func testMLXServesEnglishAsFallback() {
        XCTAssertTrue(MLXLLMService.supportedLanguages.contains("en"))
        XCTAssertEqual(MLXLLMService().availability(forLanguage: "en"), .needsModelDownload)
    }

    /// Provenance follows the ACTUAL backend the service reports: an EN note produced by the MLX fallback is tagged
    /// `mlx`, by FoundationModels `foundation`; with no reported backend (test/extractive) it uses the language default.
    @MainActor func testEnrichTagsByActualBackend() async {
        await withTemporaryHistoryStoreAsync {
            let mlxBack = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .ready, canned: AIInsights(title: "T", summary: "S", actions: [], backend: .mlx)), embedder: FakeEmbedder())
            mlxBack.history = [self.makeItem(text: "english note", lang: "en")]
            await mlxBack.enrichInsights()
            XCTAssertEqual(mlxBack.history.first?.aiModel, AppModel.mlxModelTag)        // EN made by MLX → mlx tag
            let fdnBack = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .ready, canned: AIInsights(title: "T", summary: "S", actions: [], backend: .foundation)), embedder: FakeEmbedder())
            fdnBack.history = [self.makeItem(text: "english note", lang: "en")]
            await fdnBack.enrichInsights()
            XCTAssertEqual(fdnBack.history.first?.aiModel, AppModel.foundationModelTag)
            let noBack = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .ready, canned: AIInsights(title: "T", summary: "S", actions: [])), embedder: FakeEmbedder())
            noBack.history = [self.makeItem(text: "english note", lang: "en")]
            await noBack.enrichInsights()
            XCTAssertEqual(noBack.history.first?.aiModel, AppModel.foundationModelTag)  // nil backend → language default (en)
        }
    }

    /// An EN note already produced by the MLX fallback (tagged `mlx`) must NOT be re-enriched on every refresh just
    /// because EN's DEFAULT backend is FoundationModels — either backend's CURRENT tag counts as "done".
    @MainActor func testEnrichSkipsEnglishNoteAtMLXTag() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .ready, canned: AIInsights(title: "НЕ ДОЛЖНО", summary: "НЕ ДОЛЖНО", actions: [])), embedder: FakeEmbedder())
            var it = self.makeItem(text: "english note", lang: "en")
            it.aiModel = AppModel.mlxModelTag; it.summary = "из mlx"
            m.history = [it]
            await m.enrichInsights()
            XCTAssertEqual(m.history.first?.summary, "из mlx")              // unchanged → not reprocessed
            XCTAssertEqual(m.history.first?.aiModel, AppModel.mlxModelTag)
        }
    }

    /// The extractive pass must not clobber MLX-generated insights (mirror of the foundation skip test).
    @MainActor func testBackfillInsightsSkipsMLXGenerativeItems() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine(), ai: FakeAIService(), embedder: FakeEmbedder())
            m.history = [self.makeItem(text: "обсудили план", lang: "ru")]
            if let i = m.history.indices.first { m.history[i].title = "Ген"; m.history[i].aiModel = AppModel.mlxModelTag }
            await m.backfillInsights()
            XCTAssertEqual(m.history.first?.title, "Ген")                    // extractive must NOT clobber MLX output
            XCTAssertEqual(m.history.first?.aiModel, AppModel.mlxModelTag)
        }
    }

    /// A generative VERSION bump (e.g. mlx-qwen3-v1 → v2) reprocesses an outdated note via ENRICH, WITHOUT the
    /// extractive pass downgrading it first (it's recognized generative by family prefix). A current-version note stays.
    @MainActor func testGenerativeVersionBumpReprocessesNotDowngrades() async {
        await withTemporaryHistoryStoreAsync {
            let canned = AIInsights(title: "Новый", summary: "S2", actions: [], keywords: ["k"])
            let m = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .ready, canned: canned), embedder: FakeEmbedder())
            var old = self.makeItem(text: "русский текст для теста переобработки", lang: "ru")
            old.aiModel = "mlx-qwen3-v1"; old.title = "Старый"             // an OUTDATED generative note
            m.history = [old]
            await m.backfillInsights()                                      // extractive must NOT touch it...
            XCTAssertEqual(m.history.first?.title, "Старый")
            XCTAssertEqual(m.history.first?.aiModel, "mlx-qwen3-v1")
            await m.enrichInsights()                                        // ...enrich reprocesses to the current tag
            XCTAssertEqual(m.history.first?.title, "Новый")
            XCTAssertEqual(m.history.first?.aiModel, AppModel.mlxModelTag)  // mlx-qwen3-v2
        }
    }

    @MainActor func testEnrichAIFailureKeepsExtractiveFallback() async {
        await withTemporaryHistoryStoreAsync {
            // ai.insights throws for every item → best-effort: extractive fallback stays, nothing tagged generative.
            let m = AppModel(engine: FakeEngine(), ai: FakeAIService(error: .unavailable), embedder: FakeEmbedder())
            m.history = [self.makeItem(text: "english note one", lang: "en"), self.makeItem(text: "english note two", lang: "en")]
            for i in m.history.indices { m.history[i].title = "Extractive\(i)"; m.history[i].aiModel = AppModel.extractiveModelTag }
            await m.enrichInsights()
            for it in m.history {
                XCTAssertNotEqual(it.aiModel, AppModel.foundationModelTag)        // not upgraded
                XCTAssertNil(it.actions)                                          // no actions on failure
                XCTAssertTrue(it.title?.hasPrefix("Extractive") ?? false)         // extractive fallback intact
                XCTAssertTrue(m.enrichFailedIDs.contains(it.id))                  // recorded → not re-submitted this session
            }
            // BOTH items were attempted (one failure didn't abort the batch).
            XCTAssertEqual(m.enrichFailedIDs.count, 2)
        }
    }

    @MainActor func testProvenanceReGenerationAfterEditingGenerativeItem() async {
        await withTemporaryHistoryStoreAsync {
            let canned = AIInsights(title: "Regenerated", summary: "New summary", actions: [ActionItem(text: "X")])
            let m = AppModel(engine: FakeEngine(), ai: FakeAIService(canned: canned), embedder: FakeEmbedder())
            m.history = [self.makeItem(text: "english note", lang: "en")]
            if let i = m.history.indices.first { m.history[i].aiModel = AppModel.foundationModelTag; m.history[i].actions = [ActionItem(text: "old")] }
            let id = m.history[0].id
            m.invalidateDerivedData(for: id)                 // simulate an edit's invalidation
            XCTAssertNil(m.history.first?.aiModel); XCTAssertNil(m.history.first?.actions)
            await m.enrichInsights()                          // generative re-runs + re-tags
            XCTAssertEqual(m.history.first?.title, "Regenerated")
            XCTAssertEqual(m.history.first?.actions?.map(\.text), ["X"])
            XCTAssertEqual(m.history.first?.aiModel, AppModel.foundationModelTag)
        }
    }

    /// The manual "Regenerate" button FORCES a re-run even on a note already at the current generative tag —
    /// which enrich would otherwise SKIP. The force is a provenance clear, so the item re-enters both passes; a
    /// hand-edited title survives, the other fields are re-generated, a prior failure block clears, and the per-note
    /// spinner flag is gone when the await returns.
    @MainActor func testRegenerateForcesReprocessAndKeepsHandTitle() async {
        await withTemporaryHistoryStoreAsync {
            let canned = AIInsights(title: "Fresh", summary: "Fresh summary", actions: [ActionItem(text: "Do X")], keywords: ["fresh"])
            let m = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .ready, canned: canned), embedder: FakeEmbedder())
            var it = self.makeItem(text: "we discussed the roadmap and the plan", lang: "en")
            it.aiModel = AppModel.foundationModelTag        // ALREADY at the current tag → enrich would skip without the force
            it.title = "Stale"; it.titleEdited = true       // a hand-edited title (must survive)
            it.summary = "Stale summary"; it.keywords = ["stale"]; it.actions = [ActionItem(text: "old")]
            m.history = [it]
            m.enrichFailedIDs.insert(it.id)                 // a prior hard failure must not block a deliberate retry
            await m.regenerateInsights(for: it.id)
            XCTAssertEqual(m.history.first?.title, "Stale")             // hand-edited title preserved through the force
            XCTAssertEqual(m.history.first?.summary, "Fresh summary")   // ...but the rest is re-generated
            XCTAssertEqual(m.history.first?.keywords, ["fresh"])
            XCTAssertEqual(m.history.first?.actions?.map(\.text), ["Do X"])
            XCTAssertEqual(m.history.first?.aiModel, AppModel.foundationModelTag)
            XCTAssertFalse(m.enrichFailedIDs.contains(it.id))           // the retry block was cleared
            XCTAssertTrue(m.regeneratingIDs.isEmpty)                    // spinner flag cleared on completion (defer)
        }
    }

    /// Best-effort: when the generative backend throws, Regenerate leaves the TRANSCRIPT (text + segments) entirely
    /// untouched — only the derived insight fields fall back to extractive — and never drives the engine phase.
    @MainActor func testRegenerateNeverTouchesTranscriptOnFailure() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .ready, error: .unavailable), embedder: FakeEmbedder())
            let segs = [Segment(start: 0, end: 1, text: "english"), Segment(start: 1, end: 2, text: "note")]
            var it = self.makeItem(text: "english note", segments: segs, lang: "en")
            it.aiModel = AppModel.foundationModelTag
            m.history = [it]
            await m.regenerateInsights(for: it.id)
            XCTAssertEqual(m.history.first?.text, "english note")   // transcript text untouched on failure
            XCTAssertEqual(m.history.first?.segments, segs)         // segments untouched
            XCTAssertEqual(m.phase, .idle)                         // never drives the engine phase
            XCTAssertTrue(m.regeneratingIDs.isEmpty)               // spinner flag cleared
        }
    }


    // MARK: backfillInsights TOCTOU — an edit landing mid-embed must not be overwritten

    /// backfillInsights re-found the note by id after its multi-second per-sentence embed, but never checked
    /// that the TEXT was still the same. An edit landing meanwhile got the PRE-edit title/summary/keywords
    /// written over it and stamped `extractive-v6` -- the very tag the `targets` filter excludes, so the note
    /// was then never reprocessed and kept insights describing text it no longer contained.
    /// enrichInsights and backfillEmbeddings have always checked this; this pins the third sibling.
    @MainActor func testBackfillInsightsSkipsANoteEditedDuringItsEmbed() async {
        await withTemporaryHistoryStoreAsync {
            let embedder = HookEmbedder()
            let m = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .modelUnavailable),
                             embedder: embedder)
            var it = self.makeItem(text: "старый текст заметки про погоду и дела", lang: "ru")
            it.aiModel = nil          // → a backfill target
            m.history = [it]
            let id = it.id
            // The user edits the note WHILE the embed is in flight (the main actor is free — backfill awaits).
            embedder.hook = { [weak m] in
                guard let m, let i = m.history.firstIndex(where: { $0.id == id }) else { return }
                m.history[i].text = "новый текст, пользователь всё переписал"
                embedder.hook = nil   // once
            }

            await m.backfillInsights()

            let after = m.history.first(where: { $0.id == id })
            XCTAssertEqual(after?.text, "новый текст, пользователь всё переписал", "the edit stands")
            XCTAssertNil(after?.aiModel,
                         "a note edited mid-embed must stay unstamped so a later pass reprocesses it")
        }
    }


}
