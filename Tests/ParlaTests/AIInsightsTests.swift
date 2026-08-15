import XCTest
import os
import AVFoundation
import AppKit
@testable import ParlaCore
@testable import Parla

/// Generated insights: the MLX backend, extractive title/summary, per-chapter summaries, action items, backend provenance, and snapshot completeness.
final class AIInsightsTests: ParlaLogicTestCase {
    // MARK: - MLX backend

    /// Tolerant JSON extraction (MLX has no guided decoding): the model may fence the object or wrap it in
    /// prose, and braces inside string values must not confuse the balance scan.
    func testMLXFirstJSONObjectExtraction() {
        XCTAssertEqual(MLXLLMService.firstJSONObject(in: #"{"a":1}"#), #"{"a":1}"#)
        XCTAssertEqual(MLXLLMService.firstJSONObject(in: "```json\n{\"a\":1}\n```"), #"{"a":1}"#)
        XCTAssertEqual(MLXLLMService.firstJSONObject(in: "Sure! {\"a\":1} done"), #"{"a":1}"#)
        XCTAssertEqual(MLXLLMService.firstJSONObject(in: #"{"s":"a {b} c"}"#), #"{"s":"a {b} c"}"#)
        XCTAssertEqual(MLXLLMService.firstJSONObject(in: #"x {"o":{"n":1}} y"#), #"{"o":{"n":1}}"#)
        // escaped quote inside a string must not end the string early
        XCTAssertEqual(MLXLLMService.firstJSONObject(in: #"{"s":"he said \"hi\" }"}"#), #"{"s":"he said \"hi\" }"}"#)
        XCTAssertNil(MLXLLMService.firstJSONObject(in: "no json here"))
        XCTAssertNil(MLXLLMService.firstJSONObject(in: #"{"a":1"#))   // unbalanced
    }

    /// parseInsights: valid → insights; fenced+prose → parsed; blank actions dropped; missing actions ok;
    /// empty title AND summary → nil (so the caller keeps the extractive fallback).
    func testMLXParseInsights() {
        let raw = #"{"title":"Звонок маме","summary":"Обсудили планы.","actions":["позвонить маме",""]}"#
        let got = MLXLLMService.parseInsights(from: raw)
        XCTAssertEqual(got?.title, "Звонок маме")
        XCTAssertEqual(got?.summary, "Обсудили планы.")
        XCTAssertEqual(got?.actions.map(\.text), ["Позвонить маме"])   // blank dropped + first-letter cased

        let fenced = "Here you go:\n```json\n{\"title\":\"T\",\"summary\":\"S\",\"actions\":[]}\n```"
        XCTAssertEqual(MLXLLMService.parseInsights(from: fenced)?.title, "T")
        XCTAssertEqual(MLXLLMService.parseInsights(from: fenced)?.actions.count, 0)

        XCTAssertEqual(MLXLLMService.parseInsights(from: #"{"title":"T","summary":"S"}"#)?.summary, "S")
        XCTAssertNil(MLXLLMService.parseInsights(from: "totally not json"))
        XCTAssertNil(MLXLLMService.parseInsights(from: #"{"title":"","summary":"","actions":[]}"#))
    }

    /// Tolerant parse salvages a good title+summary even when `actions` (or `title`) has the WRONG JSON type — MLX
    /// has no guided decoding, so a model that emits a string instead of an array, or an array of objects, must not
    /// sink the whole result to the extractive fallback.
    func testMLXParseInsightsTolerantFields() {
        // actions as a bare string → one action
        let s = MLXLLMService.parseInsights(from: #"{"title":"T","summary":"S","actions":"call Bob"}"#)
        XCTAssertEqual(s?.title, "T"); XCTAssertEqual(s?.summary, "S")
        XCTAssertEqual(s?.actions.map(\.text), ["Call Bob"])   // first-letter cased
        // actions as an array of OBJECTS → non-string elements dropped, title+summary survive
        let o = MLXLLMService.parseInsights(from: #"{"title":"T2","summary":"S2","actions":[{"text":"x"},"ok"]}"#)
        XCTAssertEqual(o?.title, "T2"); XCTAssertEqual(o?.actions.map(\.text), ["Ok"])
        // title is the wrong type → empty title but a valid summary still salvages the result
        let n = MLXLLMService.parseInsights(from: #"{"title":123,"summary":"only summary"}"#)
        XCTAssertEqual(n?.summary, "only summary"); XCTAssertEqual(n?.title, "")
    }

    /// The parser scans ALL top-level balanced objects and skips a non-JSON brace-pair in pre-JSON prose.
    func testMLXParseInsightsSkipsProseBraces() {
        let raw = "Note: {not json here} then the real one:\n{\"title\":\"Real\",\"summary\":\"S\"}"
        XCTAssertEqual(MLXLLMService.parseInsights(from: raw)?.title, "Real")
        XCTAssertEqual(MLXLLMService.balancedJSONObjects(in: raw).count, 2)
    }

    /// Generative keywords are parsed (trimmed, case-insensitive de-duped, capped 6) and action items get
    /// first-letter casing normalized (so the checklist isn't a mix of cases).
    func testMLXParseInsightsKeywordsAndActionCasing() {
        let raw = #"{"title":"T","summary":"S","keywords":["крипта","API","крипта","биржа"],"actions":["позвонить бобу","  ","написать тесты"]}"#
        let r = MLXLLMService.parseInsights(from: raw)
        XCTAssertEqual(r?.keywords, ["крипта", "API", "биржа"])                       // trimmed + deduped (case-insens), order kept
        XCTAssertEqual(r?.actions.map(\.text), ["Позвонить бобу", "Написать тесты"])  // first letter cased, blank dropped
    }

    func testNormalizedKeywordsTrimsDedupesCaps() {
        XCTAssertEqual(
            normalizedKeywords([" one ", "ONE", "two", "", "three", "four", "five", "six", "seven"]),
            ["one", "two", "three", "four", "five", "six"])   // dedupe case-insens (keep first) + cap 6
    }

    /// The generative upgrade is Pro. This gate was missing entirely: Apple's on-device model needs NO download,
    /// so an English-speaking free user received the very thing the paywall sells. The downloads were gated; the
    /// one path that needs no download was not.
    @MainActor func testGenerativeEnrichmentIsProOnly() async {
        await withTemporaryHistoryStoreAsync {
            let canned = AIInsights(title: "Model title", summary: "Model summary",
                                    actions: [ActionItem(text: "do it")], keywords: ["gen"])

            let free = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .ready, canned: canned),
                                embedder: FakeEmbedder())
            free.isProUser = { false }
            var a = self.makeItem(text: "обсудили альфа и бета", lang: "ru")
            a.title = "Extractive title"; a.summary = "Extractive summary"; a.keywords = ["извлечённое"]
            free.history = [a]
            await free.enrichInsights()
            XCTAssertEqual(free.history.first?.title, "Extractive title", "a free user keeps the extractive insights")
            XCTAssertEqual(free.history.first?.summary, "Extractive summary")
            XCTAssertEqual(free.history.first?.keywords, ["извлечённое"])
            XCTAssertNil(free.history.first?.actions, "action items only exist generatively — never for free")

            let pro = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .ready, canned: canned),
                               embedder: FakeEmbedder())
            pro.isProUser = { true }
            var b = self.makeItem(text: "обсудили альфа и бета", lang: "ru")
            b.title = "Extractive title"; b.summary = "Extractive summary"; b.keywords = ["извлечённое"]
            pro.history = [b]
            await pro.enrichInsights()
            XCTAssertEqual(pro.history.first?.title, "Model title", "Pro gets the generative upgrade")
            XCTAssertEqual(pro.history.first?.actions?.count, 1)
        }
    }

    /// The gate must be SILENT. `aiPowerIsGated()` sets `paywallReason`, which is right for a button the user
    /// pressed and wrong here — enrichment runs automatically after every note, so upselling would throw a
    /// paywall in the user's face each time.
    @MainActor func testGenerativeGateNeverPopsThePaywallByItself() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine(),
                             ai: FakeAIService(availabilityToReturn: .ready,
                                               canned: AIInsights(title: "T", summary: "S", actions: [])),
                             embedder: FakeEmbedder())
            m.isProUser = { false }
            m.history = [self.makeItem(text: "какой-то текст", lang: "ru")]
            await m.enrichInsights()
            XCTAssertNil(m.paywallReason, "an automatic pass must never present the paywall")
        }
    }

    /// Generative keywords UPGRADE the extractive ones; an empty generative list keeps the extractive default
    /// (so an un-downloaded model behaves exactly as before).
    @MainActor func testEnrichKeywordsUpgradeButEmptyKeepsExtractive() async {
        await withTemporaryHistoryStoreAsync {
            let withKw = AIInsights(title: "T", summary: "S", actions: [], keywords: ["альфа", "бета"])
            let m = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .ready, canned: withKw), embedder: FakeEmbedder())
            var a = self.makeItem(text: "обсудили альфа и бета", lang: "ru"); a.keywords = ["старое"]
            m.history = [a]
            await m.enrichInsights()
            XCTAssertEqual(m.history.first?.keywords, ["альфа", "бета"])   // generative replaced extractive

            let noKw = AIInsights(title: "T", summary: "S", actions: [], keywords: [])
            let m2 = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .ready, canned: noKw), embedder: FakeEmbedder())
            var b = self.makeItem(text: "другой текст", lang: "ru"); b.keywords = ["сохранить"]
            m2.history = [b]
            await m2.enrichInsights()
            XCTAssertEqual(m2.history.first?.keywords, ["сохранить"])      // empty generative → extractive kept
        }
    }

    /// MLX covers ru/uk AND English-as-a-fallback (FoundationModels is tried first for EN); other languages it can't
    /// (fr → .languageUnsupported). Until the model is downloaded it is dormant (.needsModelDownload), never .ready.
    func testMLXAvailabilityLanguageGating() {
        let mlx = MLXLLMService()
        #if arch(arm64)
        XCTAssertEqual(mlx.availability(forLanguage: "ru"), .needsModelDownload)
        XCTAssertEqual(mlx.availability(forLanguage: "uk"), .needsModelDownload)
        XCTAssertEqual(mlx.availability(forLanguage: "ru-RU"), .needsModelDownload)
        XCTAssertEqual(mlx.availability(forLanguage: "en"), .needsModelDownload)    // English = MLX fallback
        XCTAssertEqual(mlx.availability(forLanguage: "fr"), .languageUnsupported)   // still not covered
        #else
        XCTAssertEqual(mlx.availability(forLanguage: "ru"), .noAppleSilicon)
        #endif
    }

    /// DefaultAIService falls through to MLX for ru/uk: surfaces the actionable .needsModelDownload (the UI can
    /// offer the opt-in download) rather than a dead .languageUnsupported — while still never .ready pre-download.
    func testDefaultAIServiceFallsThroughToMLXForRUUK() {
        #if arch(arm64)
        let ai = DefaultAIService()
        XCTAssertEqual(ai.availability(forLanguage: "ru"), .needsModelDownload)
        XCTAssertEqual(ai.availability(forLanguage: "uk"), .needsModelDownload)
        #endif
    }

    /// Per-OS floor — asserts on EVERY OS (incl. a macOS-26 dev box, where an `else`-only test would be
    /// a silent no-op): below the floor / no FoundationModels SDK → dormant `.unsupportedOS` (the ship-safe
    /// no-op); on macOS 26 with the SDK → live, so English is NOT dormant (.ready or .modelUnavailable).
    func testFoundationModelsFloorPerOS() {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            XCTAssertNotEqual(FoundationModelsService().availability(forLanguage: "en"), .unsupportedOS)
            return
        }
        #endif
        XCTAssertEqual(FoundationModelsService().availability(forLanguage: "en"), .unsupportedOS)
        XCTAssertEqual(DefaultAIService().availability(forLanguage: "en"), .unsupportedOS)
    }

    /// The seam is injectable on AppModel, exactly like `engine` — a fake reports its canned availability.
    @MainActor func testAppModelAcceptsInjectedAIService() {
        let m = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .languageUnsupported))
        XCTAssertEqual(m.ai.availability(forLanguage: "ru"), .languageUnsupported)
    }

    /// The async `insights` path flows through the injected backend (proves the contract end-to-end).
    @MainActor func testInjectedAIServiceProducesInsights() async throws {
        let canned = AIInsights(title: "Заголовок", summary: "Итог",
                                actions: [ActionItem(text: "позвонить", done: false)])
        let m = AppModel(engine: FakeEngine(), ai: FakeAIService(canned: canned))
        let got = try await m.ai.insights(forTranscript: "длинный текст", language: "ru")
        XCTAssertEqual(got.title, "Заголовок")
        XCTAssertEqual(got.actions.first?.text, "позвонить")
    }


    // MARK: per-chapter summaries (on-demand, generative-only)

    /// A chapter's text source strips WhisperKit tokens (cleanText), drops empties, space-joins.
    func testChapterJoinedText() {
        let ch = Chapter(index: 0, startSec: 0, endSec: 120, segments: [
            Segment(start: 0, end: 1, text: "<|0.00|> привет<|1.0|>"),   // tokens stripped
            Segment(start: 1, end: 2, text: "<|endoftext|>"),            // tokens-only → empty → dropped
            Segment(start: 2, end: 3, text: "мир"),
        ])
        XCTAssertEqual(ch.joinedText, "привет мир")
    }

    /// ChapterSummary round-trips; absent key → nil (legacy); a partial element does NOT drop the whole record.
    func testChapterSummaryCodableRoundtripAndTolerant() throws {
        var item = makeItem(text: "t")
        item.chapterSummaries = [ChapterSummary(startSec: 0, endSec: 120, summary: "первая"),
                                 ChapterSummary(startSec: 120, endSec: 240, summary: "вторая")]
        let back = try JSONDecoder().decode([TranscriptItem].self, from: JSONEncoder().encode([item]))
        XCTAssertEqual(back.first?.chapterSummaries, item.chapterSummaries)
        // Legacy record without the key → nil (Optional invariant).
        let legacy = #"[{"id":"\#(UUID().uuidString)","date":1,"sourceName":"a.ogg","language":"ru","durationSec":1,"model":"m","text":"t","segments":[]}]"#
        XCTAssertNil(try JSONDecoder().decode([TranscriptItem].self, from: Data(legacy.utf8)).first?.chapterSummaries)
        // Tolerant nested decode: a ChapterSummary missing fields survives instead of dropping the WHOLE record.
        let partial = #"[{"id":"\#(UUID().uuidString)","date":1,"sourceName":"a.ogg","language":"ru","durationSec":1,"model":"m","text":"t","segments":[],"chapterSummaries":[{"summary":"только текст"}]}]"#
        let items = try JSONDecoder().decode([TranscriptItem].self, from: Data(partial.utf8))
        XCTAssertEqual(items.first?.chapterSummaries?.first, ChapterSummary(startSec: 0, endSec: 0, summary: "только текст"))
    }

    @MainActor func testGenerateChapterSummariesPersistsPerChapter() async {
        await withTemporaryHistoryStoreAsync {
            let canned = AIInsights(title: "T", summary: "сводка главы", actions: [])
            let m = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .ready, canned: canned), embedder: FakeEmbedder())
            var it = self.makeItem(text: "длинная запись", segments: [
                Segment(start: 0, end: 5, text: "первая глава тут"),
                Segment(start: 130, end: 135, text: "вторая глава тут"),
            ], lang: "ru")
            it.durationSec = 700   // > 600 → long → has chapters
            m.history = [it]
            await m.generateChapterSummaries(for: it.id)
            let cs = m.history.first?.chapterSummaries
            XCTAssertEqual(cs?.count, 2)
            XCTAssertEqual(cs?.map(\.startSec).sorted(), [0, 120])            // keyed by the stable window
            XCTAssertTrue(cs?.allSatisfy { $0.summary == "сводка главы" } ?? false)
            XCTAssertTrue(m.summarizingChaptersIDs.isEmpty)                   // spinner flag cleared (defer)
        }
    }

    /// THE call-site guard for the merge. «Regenerate all summaries» used to assign the freshly-built array
    /// wholesale, so a chapter that had a summary and failed THIS run lost it — and per-chapter failure is
    /// ordinary (a truncated JSON the parser rejects, a guardrail refusal). regenerateChapterSummary already
    /// keeps the old one on failure; this pins the same contract for the all-chapters path.
    @MainActor func testRegenerateAllChaptersKeepsTheSummaryOfAChapterThatFailsThisRun() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine(), ai: PerChapterAIService(failMarker: "вторая"),
                             embedder: FakeEmbedder())
            var it = self.makeItem(text: "длинная запись", segments: [
                Segment(start: 0, end: 5, text: "первая глава тут"),
                Segment(start: 130, end: 135, text: "вторая глава тут"),
            ], lang: "ru")
            it.durationSec = 700   // > 600 → long → two chapters at 0 and 120
            it.chapterSummaries = [ChapterSummary(startSec: 0, endSec: 120, summary: "старая первая"),
                                   ChapterSummary(startSec: 120, endSec: 240, summary: "старая вторая")]
            m.history = [it]

            await m.generateChapterSummaries(for: it.id)

            let cs = m.history.first?.chapterSummaries ?? []
            XCTAssertEqual(cs.count, 2, "the failing chapter must keep its previous summary, not be dropped")
            XCTAssertEqual(cs.first(where: { $0.startSec == 120 })?.summary, "старая вторая",
                           "chapter two failed this run — its earlier summary survives")
            XCTAssertEqual(cs.first(where: { $0.startSec == 0 })?.summary, "ok",
                           "chapter one succeeded — it is replaced")
        }
    }

    /// Map→reduce (P4 punch-list 8): after the per-chapter MAP, a REDUCE over the chapter summaries builds the
    /// WHOLE-recording overall summary (+title/keywords) — fixing the thin first-minutes summary on long notes.
    @MainActor func testGenerateChapterSummariesReducesOverallSummary() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine(), ai: ReduceAIService(), embedder: FakeEmbedder())
            var it = self.makeItem(text: "длинная запись", segments: [
                Segment(start: 0, end: 5, text: "первая глава"),
                Segment(start: 130, end: 135, text: "вторая глава"),
            ], lang: "ru")
            it.durationSec = 700
            m.history = [it]
            await m.generateChapterSummaries(for: it.id)
            XCTAssertEqual(m.history.first?.chapterSummaries?.count, 2)
            XCTAssertEqual(m.history.first?.chapterSummaries?.allSatisfy { $0.summary == "chS" }, true)  // MAP
            XCTAssertEqual(m.history.first?.summary, "OVERALL")     // REDUCE → whole-recording summary
            XCTAssertEqual(m.history.first?.title, "OverallТ")      // ...and title/keywords from the full digest
            XCTAssertEqual(m.history.first?.keywords, ["ovk"])
        }
    }

    /// The reduce's overall SUMMARY comes from the DETAILED `summarize` (not the terse `insights` summary), while
    /// title/keywords still come from `insights`. This is the fix for "summary too short on long notes".
    @MainActor func testReduceUsesDetailedSummarize() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine(), ai: DetailedSummaryAIService(), embedder: FakeEmbedder())
            var it = self.makeItem(text: "длинная", segments: [
                Segment(start: 0, end: 5, text: "первая глава"),
                Segment(start: 130, end: 135, text: "вторая глава"),
            ], lang: "ru")
            it.durationSec = 700
            m.history = [it]
            await m.generateChapterSummaries(for: it.id)
            XCTAssertEqual(m.history.first?.summary, "DETAILED whole-recording summary")           // from summarize, NOT "BRIEF"
            XCTAssertEqual(m.history.first?.chapterSummaries?.allSatisfy { $0.summary == "BRIEF" }, true)  // chapters: brief insights
            XCTAssertEqual(m.history.first?.keywords, ["k"])                                        // title/keywords still from insights
        }
    }

    /// Greedy batching packs strings under the budget, never splits a single item, and drops nothing.
    func testBatchedPacksUnderBudget() {
        let items = Array(repeating: String(repeating: "a", count: 100), count: 10)
        let batches = AppModel.batched(items, maxChars: 250)
        XCTAssertEqual(batches.flatMap { $0 }.count, 10)                                            // nothing dropped
        XCTAssertGreaterThan(batches.count, 1)                                                      // actually split
        XCTAssertTrue(batches.allSatisfy { $0.count == 1 || $0.joined(separator: "\n").count <= 250 })
        // an item bigger than the budget goes ALONE (never split)
        let big = AppModel.batched([String(repeating: "x", count: 500), "tiny"], maxChars: 250)
        XCTAssertEqual(big.first, [String(repeating: "x", count: 500)])
    }

    /// Hierarchical reduce: over-budget input is BATCHED + RECURSED (many summarize calls); fitting input = one pass.
    @MainActor func testHierarchicalSummaryRecursesForLargeInput() async {
        let ai = CountingSummaryAIService()
        let m = AppModel(engine: FakeEngine(), ai: ai, embedder: FakeEmbedder())
        let big = Array(repeating: String(repeating: "ы", count: 600), count: 40)   // 24000 chars ≫ budget
        let result = await m.hierarchicalSummary(of: big, language: "ru")
        XCTAssertEqual(result, "SUM")
        XCTAssertGreaterThan(ai.summarizeCalls, 1)                                   // batched + recursed
        let ai2 = CountingSummaryAIService()
        let m2 = AppModel(engine: FakeEngine(), ai: ai2, embedder: FakeEmbedder())
        _ = await m2.hierarchicalSummary(of: ["short", "two"], language: "ru")
        XCTAssertEqual(ai2.summarizeCalls, 1)                                        // fits → single pass
    }

    /// Granular "regenerate summary" on a long note WITH chapter summaries uses the DETAILED reduce, not a brief pass.
    @MainActor func testGranularSummaryUsesReduceForLongNote() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine(), ai: DetailedSummaryAIService(), embedder: FakeEmbedder())
            var it = self.makeItem(text: "длинная", segments: [Segment(start: 0, end: 5, text: "глава")], lang: "ru")
            it.durationSec = 700
            it.chapterSummaries = [ChapterSummary(startSec: 0, endSec: 120, summary: "ch1"),
                                   ChapterSummary(startSec: 120, endSec: 240, summary: "ch2")]
            m.history = [it]
            await m.regenerateInsight(for: it.id, field: .summary)
            XCTAssertEqual(m.history.first?.summary, "DETAILED whole-recording summary")   // detailed reduce, not "BRIEF"
        }
    }

    /// The reduce respects a hand-edited title (never overwrites it) while still upgrading the summary.
    @MainActor func testGenerateChapterSummariesReduceKeepsHandTitle() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine(), ai: ReduceAIService(), embedder: FakeEmbedder())
            var it = self.makeItem(text: "длинная", segments: [
                Segment(start: 0, end: 5, text: "первая"),
                Segment(start: 130, end: 135, text: "вторая"),
            ], lang: "ru")
            it.durationSec = 700; it.title = "Мой ручной"; it.titleEdited = true
            m.history = [it]
            await m.generateChapterSummaries(for: it.id)
            XCTAssertEqual(m.history.first?.title, "Мой ручной")   // hand title survives the reduce
            XCTAssertEqual(m.history.first?.summary, "OVERALL")    // summary still upgraded
        }
    }

    /// Per-chapter best-effort: one chapter's generation fails → it's skipped, the others land, transcript untouched.
    @MainActor func testGenerateChapterSummariesBestEffortPartial() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine(), ai: PerChapterAIService(failMarker: "СЛОМАЙ"), embedder: FakeEmbedder())
            var it = self.makeItem(text: "длинная", segments: [
                Segment(start: 0, end: 5, text: "норм глава"),
                Segment(start: 130, end: 135, text: "СЛОМАЙ глава"),
            ], lang: "ru")
            it.durationSec = 700
            m.history = [it]
            await m.generateChapterSummaries(for: it.id)
            let cs = m.history.first?.chapterSummaries
            XCTAssertEqual(cs?.count, 1)                       // the failing chapter skipped, the other survives
            XCTAssertEqual(cs?.first?.startSec, 0)
            XCTAssertEqual(m.history.first?.text, "длинная")   // transcript untouched
            XCTAssertEqual(m.history.first?.segments.count, 2)
        }
    }

    @MainActor func testGenerateChapterSummariesSkipsShortOrNoBackend() async {
        await withTemporaryHistoryStoreAsync {
            // Short note → not long → no-op even with a ready backend.
            let canned = AIInsights(title: "T", summary: "s", actions: [])
            let m = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .ready, canned: canned), embedder: FakeEmbedder())
            let short = self.makeItem(text: "коротко", segments: [Segment(start: 0, end: 1, text: "коротко")], lang: "ru")
            m.history = [short]
            await m.generateChapterSummaries(for: short.id)
            XCTAssertNil(m.history.first?.chapterSummaries)
            // Long note but NO ready backend (default NoopAIService) → no-op.
            let m2 = AppModel(engine: FakeEngine(), embedder: FakeEmbedder())
            var long = self.makeItem(text: "длинная", segments: [Segment(start: 0, end: 5, text: "глава")], lang: "ru")
            long.durationSec = 700
            m2.history = [long]
            await m2.generateChapterSummaries(for: long.id)
            XCTAssertNil(m2.history.first?.chapterSummaries)
        }
    }

    /// Per-chapter regenerate upserts ONE chapter's summary by its stable window key — updating an existing one
    /// and inserting a missing one (kept sorted) — without re-running the whole recording.
    @MainActor func testRegenerateChapterSummaryUpsertsOne() async {
        await withTemporaryHistoryStoreAsync {
            let canned = AIInsights(title: "T", summary: "новое саммари", actions: [])
            let m = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .ready, canned: canned), embedder: FakeEmbedder())
            var it = self.makeItem(text: "длинная", segments: [
                Segment(start: 0, end: 5, text: "первая глава"),
                Segment(start: 130, end: 135, text: "вторая глава"),
            ], lang: "ru")
            it.durationSec = 700
            it.chapterSummaries = [ChapterSummary(startSec: 0, endSec: 120, summary: "старое1")]   // only ch0 has one
            m.history = [it]
            await m.regenerateChapterSummary(for: it.id, startSec: 0)     // update the existing one
            XCTAssertEqual(m.history.first?.chapterSummaries?.first(where: { $0.startSec == 0 })?.summary, "новое саммари")
            await m.regenerateChapterSummary(for: it.id, startSec: 120)   // insert the missing one
            let cs = m.history.first?.chapterSummaries
            XCTAssertEqual(cs?.map(\.startSec), [0, 120])                 // both present, sorted by start
            XCTAssertEqual(cs?.first(where: { $0.startSec == 120 })?.summary, "новое саммари")
            XCTAssertTrue(m.summarizingChapters.isEmpty)                  // per-chapter spinner cleared (defer)
        }
    }

    /// Per-chapter regenerate is best-effort: a failure leaves the EXISTING summary and the transcript untouched.
    @MainActor func testRegenerateChapterSummaryFailureKeepsOld() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .ready, error: .unavailable), embedder: FakeEmbedder())
            var it = self.makeItem(text: "длинная", segments: [Segment(start: 0, end: 5, text: "глава")], lang: "ru")
            it.durationSec = 700
            it.chapterSummaries = [ChapterSummary(startSec: 0, endSec: 120, summary: "старое")]
            m.history = [it]
            await m.regenerateChapterSummary(for: it.id, startSec: 0)     // AI throws → keep old
            XCTAssertEqual(m.history.first?.chapterSummaries?.first?.summary, "старое")
            XCTAssertEqual(m.history.first?.text, "длинная")             // transcript untouched
        }
    }

    @MainActor func testInvalidateClearsChapterSummaries() {
        withTemporaryHistoryStore {
            let m = AppModel(engine: FakeEngine(), embedder: FakeEmbedder())
            var it = self.makeItem(text: "текст", lang: "ru")
            it.chapterSummaries = [ChapterSummary(startSec: 0, endSec: 120, summary: "с")]
            m.history = [it]
            m.invalidateDerivedData(for: it.id)   // an edit re-buckets chapters → stale summaries must drop
            XCTAssertNil(m.history.first?.chapterSummaries)
        }
    }

    /// Granular regenerate (P4 menu): regenerating ONE field applies only that field, leaving the others intact.
    @MainActor func testRegenerateInsightSummaryOnly() async {
        await withTemporaryHistoryStoreAsync {
            let canned = AIInsights(title: "NewТ", summary: "NewС", actions: [ActionItem(text: "NewЗ")], keywords: ["newK"])
            let m = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .ready, canned: canned), embedder: FakeEmbedder())
            var it = self.makeItem(text: "english note", lang: "en")
            it.title = "oldT"; it.titleEdited = true; it.summary = "oldS"; it.keywords = ["oldK"]; it.actions = [ActionItem(text: "oldA")]
            m.history = [it]
            await m.regenerateInsight(for: it.id, field: .summary)
            XCTAssertEqual(m.history.first?.summary, "NewС")                  // only summary regenerated
            XCTAssertEqual(m.history.first?.title, "oldT")                    // others untouched
            XCTAssertEqual(m.history.first?.keywords, ["oldK"])
            XCTAssertEqual(m.history.first?.actions?.map(\.text), ["oldA"])
            XCTAssertTrue(m.regeneratingIDs.isEmpty)                          // spinner cleared
        }
    }

    /// Explicit title regenerate overwrites even a hand-edited title and clears `titleEdited` (it's auto again).
    @MainActor func testRegenerateInsightTitleClearsHandEdit() async {
        await withTemporaryHistoryStoreAsync {
            let canned = AIInsights(title: "NewТ", summary: "S", actions: [], keywords: [])
            let m = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .ready, canned: canned), embedder: FakeEmbedder())
            var it = self.makeItem(text: "english note", lang: "en")
            it.title = "Мой ручной"; it.titleEdited = true; it.summary = "keepS"
            m.history = [it]
            await m.regenerateInsight(for: it.id, field: .title)
            XCTAssertEqual(m.history.first?.title, "NewТ")     // overwrites the hand title (explicit action)
            XCTAssertNil(m.history.first?.titleEdited)         // ...now auto again
            XCTAssertEqual(m.history.first?.summary, "keepS")  // summary untouched
        }
    }

    /// Tasks are generative-only: with a backend they regenerate; without one, extractive can't make them, so the
    /// existing tasks are LEFT untouched (a generative failure/absence must not silently clear the user's tasks).
    @MainActor func testRegenerateInsightActionsGenerativeOnly() async {
        await withTemporaryHistoryStoreAsync {
            let canned = AIInsights(title: "T", summary: "S", actions: [ActionItem(text: "NewЗ")], keywords: [])
            let gen = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .ready, canned: canned), embedder: FakeEmbedder())
            var it = self.makeItem(text: "english note", lang: "en")
            it.actions = [ActionItem(text: "oldA")]
            gen.history = [it]
            await gen.regenerateInsight(for: it.id, field: .actions)
            XCTAssertEqual(gen.history.first?.actions?.map(\.text), ["NewЗ"])   // generative → regenerated
            let ext = AppModel(engine: FakeEngine(), embedder: FakeEmbedder())  // NoopAIService → not ready
            var it2 = self.makeItem(text: "ru заметка здесь", lang: "ru")
            it2.actions = [ActionItem(text: "keep")]
            ext.history = [it2]
            await ext.regenerateInsight(for: it2.id, field: .actions)
            XCTAssertEqual(ext.history.first?.actions?.map(\.text), ["keep"])   // extractive can't → untouched
        }
    }

    @MainActor func testDefaultBackendsAreNoopUnderTests() {
        // Locks the load-bearing headless gate: a test that doesn't inject fakes never hits the real model/embedder.
        XCTAssertTrue(AppModel.defaultAI() is NoopAIService)
        XCTAssertTrue(AppModel.defaultEmbedder() is NoopEmbedder)
        let m = AppModel(engine: FakeEngine())
        XCTAssertTrue(m.ai is NoopAIService)
        XCTAssertTrue(m.embedder is NoopEmbedder)
    }

    @MainActor func testToggleActionFlipsDone() {
        withTemporaryHistoryStore {
            let m = AppModel(engine: FakeEngine(), embedder: FakeEmbedder())
            let it = self.makeItem(text: "note")
            m.history = [it]
            if let i = m.history.indices.first { m.history[i].actions = [ActionItem(text: "A"), ActionItem(text: "B")] }
            m.toggleAction(1, for: it.id)
            XCTAssertEqual(m.history.first?.actions?[1].done, true)
            XCTAssertEqual(m.history.first?.actions?[0].done, false)
            m.toggleAction(1, for: it.id)
            XCTAssertEqual(m.history.first?.actions?[1].done, false)
            m.toggleAction(5, for: it.id)   // out of range → no-op, no crash
        }
    }

    @MainActor func testEnrichSkipsUnsupportedLanguage() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .languageUnsupported), embedder: FakeEmbedder())
            m.history = [self.makeItem(text: "обсудили дорожную карту", lang: "ru")]
            await m.enrichInsights()
            XCTAssertNil(m.history.first?.actions)
            XCTAssertNotEqual(m.history.first?.aiModel, AppModel.foundationModelTag)   // RU keeps extractive (no generative backend)
        }
    }

    @MainActor func testEnrichPreservesHandEditedTitle() async {
        await withTemporaryHistoryStoreAsync {
            let canned = AIInsights(title: "Generated", summary: "S", actions: [])
            let m = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .ready, canned: canned), embedder: FakeEmbedder())
            m.history = [self.makeItem(text: "english note", lang: "en")]
            if let i = m.history.indices.first { m.history[i].title = "Мой заголовок"; m.history[i].titleEdited = true }
            await m.enrichInsights()
            XCTAssertEqual(m.history.first?.title, "Мой заголовок")   // hand-edited title preserved
            XCTAssertEqual(m.history.first?.summary, "S")            // summary still upgraded
            XCTAssertEqual(m.history.first?.aiModel, AppModel.foundationModelTag)
        }
    }

    @MainActor func testBackfillInsightsSkipsGenerativeItems() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine(), ai: FakeAIService(), embedder: FakeEmbedder())
            m.history = [self.makeItem(text: "english note here", lang: "en")]
            if let i = m.history.indices.first { m.history[i].title = "Gen"; m.history[i].aiModel = AppModel.foundationModelTag }
            await m.backfillInsights()
            XCTAssertEqual(m.history.first?.title, "Gen")                          // extractive must NOT clobber generative
            XCTAssertEqual(m.history.first?.aiModel, AppModel.foundationModelTag)
        }
    }

    @MainActor func testSaveEditInvalidatesSemanticIndexes() {
        withTemporaryHistoryStore {
            let m = AppModel(engine: FakeEngine(), embedder: FakeEmbedder())
            let a = self.makeItem(text: "первая про крипту"), b = self.makeItem(text: "вторая про крипту")
            let c = self.makeItem(text: "третья про крипту")
            m.history = [a, b, c]
            m.selection = a.id
            m.embeddingIndex = [a.id: [1, 0, 0], b.id: [1, 0, 0], c.id: [1, 0, 0]]
            m.lemmaIndex = [a.id: ["крипта"], b.id: ["крипта"], c.id: ["крипта"]]
            EmbeddingStore.save([a.id: [1, 0, 0]])
            m.relatedIDs = [b.id, c.id]
            XCTAssertTrue(m.saveEdit("совсем другой текст про спорт", for: a.id))
            XCTAssertNil(m.embeddingIndex[a.id])        // vector invalidated synchronously
            XCTAssertNil(m.lemmaIndex[a.id])            // lemmas invalidated
            XCTAssertNil(EmbeddingStore.load()[a.id])   // persisted vector removed
            XCTAssertTrue(m.relatedIDs.isEmpty)         // stale "Related" footer cleared at once
        }
    }

    @MainActor func testEditInvalidatesSearchIndex() throws {
        try XCTSkipUnless(hasRussianLemmatizer, "Russian NLTagger lemma asset unavailable on this host")
        withTemporaryHistoryStore {
            let m = AppModel(engine: FakeEngine(), embedder: FakeEmbedder())
            let it = self.makeItem(text: "старый текст про работу команды")
            m.history = [it]
            m.backfillLemmas()
            XCTAssertTrue(m.lemmaIndex[it.id]?.contains("работа") ?? false)
            _ = m.saveEdit("совсем другое содержание про криптовалюту", for: it.id)
            m.backfillLemmas()   // stand in for the async refresh saveEdit kicks off
            XCTAssertTrue(m.lemmaIndex[it.id]?.contains("криптовалюта") ?? false)   // new text indexed
            XCTAssertFalse(m.lemmaIndex[it.id]?.contains("работа") ?? true)         // stale lemma gone
        }
    }

    @MainActor func testBackfillLemmasBuildsAndPrunes() {
        withTemporaryHistoryStore {
            let m = AppModel(engine: FakeEngine(), embedder: FakeEmbedder())
            let a = self.makeItem(text: "проект про крипту"), b = self.makeItem(text: "рецепт супа")
            m.history = [a, b]
            m.backfillLemmas()
            XCTAssertEqual(Set(m.lemmaIndex.keys), [a.id, b.id])
            XCTAssertTrue(m.lemmaIndex[a.id]?.contains("проект") ?? false)
            // Remove an item → its lemmas are pruned on the next pass.
            m.history = [a]
            m.backfillLemmas()
            XCTAssertEqual(Set(m.lemmaIndex.keys), [a.id])
        }
    }

    @MainActor func testBackfillEmbeddingsMirrorsIntoMemoryIndex() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine(), embedder: FakeEmbedder(vector: [0.5, 0.5]))
            let it = self.makeItem(text: "заметка")
            m.history = [it]
            await m.backfillEmbeddings()
            XCTAssertEqual(m.embeddingIndex[it.id], [0.5, 0.5])   // in-memory mirror populated for doc↔doc related
        }
    }

    @MainActor func testBackfillEmbeddingsSkipsVectorForItemEditedMidEmbed() async {
        await withTemporaryHistoryStoreAsync {
            let embedder = HookEmbedder()
            let m = AppModel(engine: FakeEngine(), embedder: embedder)
            let it = self.makeItem(text: "старый текст про работу")
            m.history = [it]
            // Edit the item DURING its first embed → the stale "старый" vector must NOT be committed (the round-2
            // TOCTOU gap: EmbeddingStore.remove is a no-op for a never-persisted item, so a text snapshot guards it).
            embedder.hook = { _ = m.saveEdit("новый текст про крипту", for: it.id) }
            await m.backfillEmbeddings()
            XCTAssertNil(m.embeddingIndex[it.id])              // stale pre-edit vector skipped
            XCTAssertNil(EmbeddingStore.load()[it.id])
            embedder.hook = nil                               // next pass embeds the CURRENT (edited) text
            await m.backfillEmbeddings()
            XCTAssertEqual(m.embeddingIndex[it.id], [0, 1])   // "новый" → [0,1] (re-embedded from new text)
        }
    }

    @MainActor func testBackfillSkipsUnembeddableItems() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine(), embedder: FakeEmbedder(vector: nil))
            m.history = [self.makeItem(text: "x")]
            await m.backfillEmbeddings()
            XCTAssertTrue(EmbeddingStore.load().isEmpty)   // unembeddable → skipped, not stored empty; retried later
        }
    }


    // MARK: - Extractive title/summary

    func testConciseTitle() {
        XCTAssertEqual(conciseTitle(from: "  Короткий   заголовок  "), "Короткий заголовок")   // trim + collapse
        let cut = conciseTitle(from: "Это очень длинное предложение которое точно превышает лимит символов заголовка", maxChars: 30)
        XCTAssertLessThanOrEqual(cut.count, 31)            // ~maxChars + ellipsis
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertFalse(cut.dropLast().hasSuffix(" "))      // cut on a word boundary, no dangling space before …
    }

    func testTopTerms() {
        XCTAssertEqual(topTerms(["релиз", "Олег", "релиз", "оплата", "релиз", "Олег"], max: 2), ["релиз", "Олег"])
        XCTAssertEqual(topTerms(["a", "B", "c"], max: 5), ["a", "B", "c"])   // fewer than max, casing kept
        XCTAssertTrue(topTerms([], max: 3).isEmpty)
    }

    func testExtractiveSelection() {
        XCTAssertNil(SemanticIndex.extractiveSelection([], summaryCount: 3))
        let one = SemanticIndex.extractiveSelection([[1, 0]], summaryCount: 3)
        XCTAssertEqual(one?.title, 0)
        XCTAssertEqual(one?.summary, [0])
        // Star graph: sentence 0 (the hub) is central → title; summary returned in document order.
        let sel = SemanticIndex.extractiveSelection([[1, 1, 1], [1, 0, 0], [0, 1, 0], [0, 0, 1]], summaryCount: 2)
        XCTAssertEqual(sel?.title, 0)
        XCTAssertEqual(sel?.summary, sel?.summary.sorted())
        XCTAssertEqual(sel?.summary.count, 2)
    }

    func testSentencesSplit() {
        XCTAssertTrue(sentences(in: "   ").isEmpty)
        let s = sentences(in: "Привет мир. Как дела? Хорошо!")
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.first, "Привет мир.")
    }

    func testKeywordCandidates() {
        XCTAssertTrue(keywordCandidates(from: "   ", language: "ru").isEmpty)
        let kw = keywordCandidates(from: "Купить молоко и хлеб в магазине у дома", language: "ru", max: 2)
        XCTAssertFalse(kw.isEmpty)                  // pulls some nouns out
        XCTAssertLessThanOrEqual(kw.count, 2)       // respects max
        // Stopwords are never candidates, even if the tagger mislabels them (the casual-speech failure mode).
        let kw2 = keywordCandidates(from: "Если честно это вообще ерунда какая-то", language: "ru", max: 8)
        XCTAssertFalse(kw2.contains { ["если", "это", "вообще"].contains($0.lowercased()) })
        // Verbs/adjectives the POS tagger mislabels as nouns are dropped by the morphology filter.
        let kw3 = keywordCandidates(from: "стягивает данные и синхронизирует портфель параллельно", language: "ru", max: 8)
            .map { $0.lowercased() }
        XCTAssertFalse(kw3.contains { ["стягивать", "синхронизировать", "параллельный"].contains($0) })
    }

    func testBundledStopwordsQuality() {
        XCTAssertGreaterThan(keywordStopwords.count, 1000)   // canonical + complete, not a hand sample
        for filler in ["если", "просто", "вообще", "якщо", "взагалі", "like", "well", "actually", "блин", "типа"] {
            XCTAssertTrue(keywordStopwords.contains(filler), "\(filler) should be a stopword")
        }
        // Content words + tech homonyms must NOT be stoplisted — the embedding ranking decides those.
        for content in ["данные", "биржа", "стартап", "портфель", "код", "сериал", "проект", "дело", "робота"] {
            XCTAssertFalse(keywordStopwords.contains(content), "\(content) is content, must not be stoplisted")
        }
    }

    func testLooksLikeVerbLemma() {
        for verb in ["гонять", "долбить", "стягивать", "синхронизировать", "кидать", "делать", "писать", "учиться"] {
            XCTAssertTrue(looksLikeVerbLemma(verb), "\(verb) is a verb infinitive")
        }
        for noun in ["часть", "власть", "новость", "сеть", "путь", "портфель", "биржа", "спринт", "код"] {
            XCTAssertFalse(looksLikeVerbLemma(noun), "\(noun) is a noun, keep it")
        }
    }

    func testLooksLikeAdjectiveLemma() {
        for adj in ["далёкий", "параллельный", "быстрый", "короткий", "читающий", "сделанный"] {
            XCTAssertTrue(looksLikeAdjectiveLemma(adj), "\(adj) is an adjective/participle")
        }
        for noun in ["код", "утро", "биржа", "история", "музыка", "созвон"] {
            XCTAssertFalse(looksLikeAdjectiveLemma(noun), "\(noun) is a noun, keep it")
        }
    }

    func testDynamicKeywordCount() {
        // Band/elbow choose WITHIN [min 3 … cap 6]; a tight cluster keeps several.
        XCTAssertEqual(SemanticIndex.dynamicKeywordCount(scores: [0.62, 0.58, 0.55, 0.51]), 4)
        // A sharp cliff would cut to 1, but the floor lifts it to 3 (there are 3+ candidates to show).
        XCTAssertEqual(SemanticIndex.dynamicKeywordCount(scores: [0.61, 0.34, 0.30, 0.29]), 3)
        // Fewer candidates than the floor → return what's there, never invent.
        XCTAssertEqual(SemanticIndex.dynamicKeywordCount(scores: [0.61, 0.34]), 2)
        XCTAssertEqual(SemanticIndex.dynamicKeywordCount(scores: [0.9]), 1)
        // Flat-high cluster is capped at 6, not unbounded.
        XCTAssertEqual(SemanticIndex.dynamicKeywordCount(scores: Array(repeating: 0.5, count: 9)), 6)
        XCTAssertEqual(SemanticIndex.dynamicKeywordCount(scores: []), 0)
    }

    func testMMR() {
        // Two near-identical top vectors + one diverse: MMR picks the top, then the diverse one over the near-dup.
        let vectors: [Embedding] = [[1, 0], [0.99, 0.01], [0, 1]]
        let scores = [0.9, 0.88, 0.6]
        let picked = SemanticIndex.mmr(scores: scores, vectors: vectors, count: 2, lambda: 0.6)
        XCTAssertEqual(picked.first, 0)            // most relevant first
        XCTAssertEqual(picked, [0, 2])             // diverse #2 beats the near-duplicate #1
    }

    @MainActor func testBackfillInsightsSetsTitleAndSummary() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine(), embedder: FakeEmbedder(vector: [0.1, 0.2, 0.3]))
            let long = self.makeItem(text: "Первое предложение тут. Второе предложение тут. Третье тут. Четвёртое тут. Пятое предложение тут.")
            let short = self.makeItem(text: "Купить хлеб.")
            m.history = [long, short]
            await m.backfillInsights()
            let lt = m.history.first { $0.id == long.id }
            XCTAssertEqual(lt?.title, "Первое предложение тут.")   // central sentence (constant vectors → first)
            XCTAssertEqual(lt?.aiModel, "extractive-v6")
            XCTAssertNotNil(lt?.summary)                           // 5 sentences > 4 → summary present
            XCTAssertNotNil(lt?.keywords)                          // embedding-ranked tags populated
            let st = m.history.first { $0.id == short.id }
            XCTAssertNotNil(st?.title)                             // single sentence still gets a title
            XCTAssertNil(st?.summary)                              // too short to summarize
        }
    }

    @MainActor func testBackfillInsightsSkipsUnembeddable() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine(), embedder: FakeEmbedder(vector: nil))
            m.history = [self.makeItem(text: "Раз. Два. Три.")]
            await m.backfillInsights()
            XCTAssertNil(m.history.first?.title)   // embedder unavailable → title stays nil, retried later
        }
    }

    @MainActor func testSidebarTitleHonorsToggle() {
        let m = AppModel(engine: FakeEngine())
        var item = self.makeItem(name: "msg.ogg", text: "тело")
        item.title = "Сгенерённый заголовок"
        m.showTitles = true
        XCTAssertEqual(m.sidebarTitle(for: item), "Сгенерённый заголовок")   // title shown
        m.showTitles = false
        XCTAssertEqual(m.sidebarTitle(for: item), "msg.ogg")                 // feature off → raw name
        // Titles on but no title yet → falls back to sourceName.
        m.showTitles = true
        XCTAssertEqual(m.sidebarTitle(for: self.makeItem(name: "x.ogg", text: "t")), "x.ogg")
    }

    @MainActor func testSetTitleEditsAndProtects() {
        withTemporaryHistoryStore {
            let m = AppModel(engine: FakeEngine())
            var item = self.makeItem(name: "msg.ogg", text: "тело")
            item.title = "Авто заголовок"            // pretend the engine generated this
            m.history = [item]
            // Hand-rename → title set + pinned against regeneration.
            XCTAssertTrue(m.setTitle("Мой заголовок", for: item.id))
            XCTAssertEqual(m.history.first?.title, "Мой заголовок")
            XCTAssertEqual(m.history.first?.titleEdited, true)
            // No-op rename → false, nothing rewritten.
            XCTAssertFalse(m.setTitle("Мой заголовок", for: item.id))
            // Empty → reverts to the generated/sourceName fallback, edit flag cleared.
            XCTAssertTrue(m.setTitle("   ", for: item.id))
            XCTAssertNil(m.history.first?.title)
            XCTAssertNil(m.history.first?.titleEdited)
        }
    }

    @MainActor func testSaveEditPersistsAndStamps() {
        withTemporaryHistoryStore {
            let m = AppModel()
            let item = makeItem(text: "оригинал")
            m.history = [item]

            XCTAssertTrue(m.saveEdit("исправлено", for: item.id))
            XCTAssertEqual(m.history.first?.text, "исправлено")
            XCTAssertEqual(m.history.first?.edited, true)
            XCTAssertNotNil(m.history.first?.editedAt)

            // no-op: same text → false, leave the timestamp alone
            let stampedAt = m.history.first?.editedAt
            XCTAssertFalse(m.saveEdit("исправлено", for: item.id))
            XCTAssertEqual(m.history.first?.editedAt, stampedAt)

            // unknown id → false, history unchanged
            XCTAssertFalse(m.saveEdit("другое", for: UUID()))
            XCTAssertEqual(m.history.count, 1)

            // edit really lands on disk (in the temp file) and decodes back
            let reloaded = HistoryStore.load()
            XCTAssertEqual(reloaded.first?.text, "исправлено")
            XCTAssertEqual(reloaded.first?.isEdited, true)
        }
    }

    func testExportTextMarksEdited() {
        let out = exportText([
            makeItem(name: "a.ogg", text: "txt", edited: true),
            makeItem(name: "b.ogg", text: "txt2"),
        ])
        let blocks = out.components(separatedBy: "---")
        XCTAssertTrue(blocks[0].contains("## a.ogg"))
        XCTAssertTrue(blocks[0].contains("изменено"))    // edited — with the marker
        XCTAssertTrue(blocks[1].contains("## b.ogg"))
        XCTAssertFalse(blocks[1].contains("изменено"))   // plain — without
    }


    // MARK: Provenance — a new backend must never be mis-tagged as another's output

    /// The trap this closes: `tag(for:)` was a ternary, so a THIRD AIBackend case compiled perfectly and stamped
    /// its output `foundation-v2`. That is not cosmetic — `backfillInsights` treats an unrecognised tag as
    /// un-processed and OVERWRITES the note's title, summary and keywords with extractive output. Everything is
    /// now derived from AIBackend.allCases through exhaustive switches, so the day a backend is added it is
    /// protected; this test guards the derivation itself against being hardcoded back.
    @MainActor func testEveryBackendGetsItsOwnRecognisedProvenanceTag() {
        var seenPrefixes = Set<String>()
        for backend in AIBackend.allCases {
            let prefix = AppModel.tagPrefix(for: backend)
            let tag = AppModel.tag(for: backend)
            XCTAssertFalse(prefix.isEmpty, "\(backend) needs its own family prefix")
            XCTAssertTrue(seenPrefixes.insert(prefix).inserted, "\(backend) shares a prefix with another backend")
            XCTAssertTrue(tag.hasPrefix(prefix))
            XCTAssertTrue(AppModel.isGenerativeTag(tag),
                          "\(backend)'s output must be recognised as generative, or backfill overwrites it")
            XCTAssertTrue(AppModel.isAtCurrentGenerativeVersion(tag),
                          "\(backend)'s current tag must count as current, or enrich re-runs it forever")
        }
        XCTAssertEqual(seenPrefixes.count, AIBackend.allCases.count)
    }

    /// A tag from an OLDER version of a backend stays recognised as generative (so extractive never downgrades a
    /// note that enrich is about to regenerate) while NOT counting as current (so enrich does regenerate it).
    @MainActor func testAnOlderVersionOfABackendTagIsProtectedButStillReprocessed() {
        for backend in AIBackend.allCases {
            let old = AppModel.tagPrefix(for: backend) + "v0"
            XCTAssertTrue(AppModel.isGenerativeTag(old), "extractive must not clobber \(backend) v0")
            XCTAssertFalse(AppModel.isAtCurrentGenerativeVersion(old), "\(backend) v0 must still be re-enriched")
        }
    }

    @MainActor func testExtractiveAndUnknownTagsAreNotGenerative() {
        XCTAssertFalse(AppModel.isGenerativeTag(AppModel.extractiveModelTag))
        XCTAssertFalse(AppModel.isGenerativeTag(nil))
        XCTAssertFalse(AppModel.isGenerativeTag("something-else-v1"))
        XCTAssertFalse(AppModel.isAtCurrentGenerativeVersion(nil))
    }


    // MARK: MLX snapshot completeness — drives BOTH availability and the no-network short-circuit

    private func writeSnapshot(_ dir: URL, files: [String: String]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body) in files { try Data(body.utf8).write(to: dir.appendingPathComponent(name)) }
    }

    /// A complete snapshot must be recognised WITHOUT the Hub: this is what stops a fully downloaded model
    /// phoning huggingface.co before every insight, contradicting the app's own "runs fully offline" copy.
    func testSnapshotIsCompleteWithConfigTokenizerAndWeights() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSnapshot(dir, files: ["config.json": "{}", "tokenizer_config.json": "{}",
                                       "tokenizer.json": "{}", "model.safetensors": "w"])
        XCTAssertTrue(MLXHubDownloader.isSnapshotComplete(at: dir))
    }

    /// THE strictness guard: an interrupted MULTI-SHARD download has an index naming shards that never arrived.
    /// "any .safetensors" called that complete — reporting .ready in the UI, and (once the downloader trusts this)
    /// skipping the fetch of the missing shards entirely.
    func testSnapshotWithAMissingShardIsIncomplete() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = #"{"weight_map":{"a":"model-00001-of-00002.safetensors","b":"model-00002-of-00002.safetensors"}}"#
        try writeSnapshot(dir, files: ["config.json": "{}", "tokenizer_config.json": "{}", "tokenizer.json": "{}",
                                       "model.safetensors.index.json": index,
                                       "model-00001-of-00002.safetensors": "w"])   // shard 2 never arrived
        XCTAssertFalse(MLXHubDownloader.isSnapshotComplete(at: dir), "one of two shards is not a usable model")

        try Data("w".utf8).write(to: dir.appendingPathComponent("model-00002-of-00002.safetensors"))
        XCTAssertTrue(MLXHubDownloader.isSnapshotComplete(at: dir), "…and it is complete once every shard lands")
    }

    func testSnapshotMissingTokenizerOrWeightsIsIncomplete() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let noTok = base.appendingPathComponent("a")
        try writeSnapshot(noTok, files: ["config.json": "{}", "model.safetensors": "w"])
        XCTAssertFalse(MLXHubDownloader.isSnapshotComplete(at: noTok))
        let noWeights = base.appendingPathComponent("b")
        try writeSnapshot(noWeights, files: ["config.json": "{}", "tokenizer_config.json": "{}", "tokenizer.json": "{}"])
        XCTAssertFalse(MLXHubDownloader.isSnapshotComplete(at: noWeights))
        XCTAssertFalse(MLXHubDownloader.isSnapshotComplete(at: base.appendingPathComponent("missing")))
    }


    // MARK: Action items — regeneration must not un-tick the user's checkboxes

    /// enrichInsights re-runs over the WHOLE history whenever a generative tag is bumped, which the tags' own
    /// comments prescribe on any prompt change. It assigned `actions` wholesale, and a fresh ActionItem always
    /// has done == false, so every box the user had ticked was silently cleared and persisted.
    func testCarryOverDoneFlagsKeepsTheUsersTicks() {
        let previous = [ActionItem(text: "позвонить в банк", done: true),
                        ActionItem(text: "купить билеты", done: false)]
        let fresh = [ActionItem(text: "Позвонить в банк"),      // same task, re-cased by a new prompt
                     ActionItem(text: "купить билеты"),
                     ActionItem(text: "новая задача")]
        let merged = AppModel.carryOverDoneFlags(fresh, from: previous)
        XCTAssertEqual(merged.map(\.done), [true, false, false],
                       "a ticked task stays ticked across a regeneration, matched case-insensitively")
        XCTAssertEqual(merged.count, 3, "the fresh list still decides WHICH actions exist")
    }

    func testCarryOverDoneFlagsIsANoOpWithoutTicks() {
        let fresh = [ActionItem(text: "a"), ActionItem(text: "b")]
        XCTAssertEqual(AppModel.carryOverDoneFlags(fresh, from: [ActionItem(text: "a", done: false)]).map(\.done),
                       [false, false])
        XCTAssertEqual(AppModel.carryOverDoneFlags(fresh, from: []).map(\.text), ["a", "b"])
    }

    /// A task the user ticked that the new run no longer produces is simply gone — the model decides the list.
    func testCarryOverDoneFlagsDoesNotResurrectDroppedTasks() {
        let merged = AppModel.carryOverDoneFlags([ActionItem(text: "b")],
                                                 from: [ActionItem(text: "a", done: true)])
        XCTAssertEqual(merged.map(\.text), ["b"])
    }

    /// The CALL-SITE guard: enrichInsights must run its regenerated actions through the carry-over, not assign
    /// them raw. Bumping a generative tag re-enriches the whole history, so without this every ticked box in
    /// every note is cleared at once.
    @MainActor func testEnrichInsightsKeepsTickedActionsAcrossARegeneration() async {
        await withTemporaryHistoryStoreAsync {
            let canned = AIInsights(title: "T", summary: "S",
                                    actions: [ActionItem(text: "позвонить в банк"), ActionItem(text: "новое дело")])
            let m = AppModel(engine: FakeEngine(), ai: FakeAIService(availabilityToReturn: .ready, canned: canned),
                             embedder: FakeEmbedder())
            m.isProUser = { true }                       // enrichInsights is Pro-gated, silently
            var it = self.makeItem(text: "какой-то осмысленный текст заметки", lang: "ru")
            it.actions = [ActionItem(text: "позвонить в банк", done: true)]   // the user ticked this off
            it.aiModel = nil                             // → a target for enrichment
            m.history = [it]

            await m.enrichInsights()

            let actions = m.history.first?.actions ?? []
            XCTAssertEqual(actions.first(where: { $0.text == "позвонить в банк" })?.done, true,
                           "the user's tick survives a regeneration")
            XCTAssertEqual(actions.count, 2, "the fresh list still decides which actions exist")
        }
    }


    // MARK: Chapter summaries — a failed chapter must not cost the user a summary it already had

    /// «Regenerate all summaries» rebuilds the set chapter by chapter, and chapterSummaryText returns nil on the
    /// ordinary failures (a truncated JSON the parser rejects, a guardrail refusal). Assigning the fresh array
    /// wholesale deleted every chapter that had a summary and failed THIS run; if all failed, the Digest tab
    /// disappeared. regenerateChapterSummary already keeps the old one on failure — this is the same contract
    /// for the all-chapters path.
    func testUpsertChapterSummariesKeepsChaptersMissingFromThisRun() {
        let existing = [ChapterSummary(startSec: 0, endSec: 600, summary: "old one"),
                        ChapterSummary(startSec: 600, endSec: 1200, summary: "old two")]
        let fresh = [ChapterSummary(startSec: 0, endSec: 600, summary: "new one")]   // chapter two failed this run
        let merged = AppModel.upsertChapterSummaries(fresh, into: existing)
        XCTAssertEqual(merged.count, 2, "a chapter that failed this run keeps its previous summary")
        XCTAssertEqual(merged[0].summary, "new one", "a chapter that succeeded is replaced")
        XCTAssertEqual(merged[1].summary, "old two")
    }

    func testUpsertChapterSummariesMatchesOnTheWindowKeyAndStaysSorted() {
        let existing = [ChapterSummary(startSec: 600, endSec: 1200, summary: "old two")]
        // 600.3 is the SAME window (the +/-0.5s key regenerateChapterSummary uses), 1200 is a new one.
        let fresh = [ChapterSummary(startSec: 1200, endSec: 1800, summary: "new three"),
                     ChapterSummary(startSec: 600.3, endSec: 1200, summary: "new two")]
        let merged = AppModel.upsertChapterSummaries(fresh, into: existing)
        XCTAssertEqual(merged.map(\.summary), ["new two", "new three"], "upsert by window, then sort by start")
    }

    func testUpsertChapterSummariesOnAnEmptyRunChangesNothing() {
        let existing = [ChapterSummary(startSec: 0, endSec: 600, summary: "old one")]
        XCTAssertEqual(AppModel.upsertChapterSummaries([], into: existing).map(\.summary), ["old one"],
                       "every chapter failing must leave the Digest intact, not erase it")
    }


}
