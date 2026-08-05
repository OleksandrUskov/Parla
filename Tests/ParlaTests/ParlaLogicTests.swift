import XCTest
import os
import AVFoundation
import AppKit
@testable import ParlaCore
@testable import Parla

/// Unit tests for pure logic (no WhisperKit/audio/UI):
/// model names and tiers, history (schema/search/export/migration),
/// model sizes/paths, audio file collection, formatting, languages.
final class ParlaLogicTests: XCTestCase {

    // MARK: Localization (test seam)

    /// Repo root, derived from this file's path (Tests/ParlaTests/… → ../../..).
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Point `Localized` at a real `.lproj` from the repo (deterministic, no Bundle.main).
    private func activateLocalization(_ lang: String) {
        let lproj = repoRoot.appendingPathComponent("Localization/\(lang).lproj")
        Localized.bundle = Bundle(path: lproj.path) ?? .main
        Localized.currentCode = lang
    }

    /// By default all tests run in Russian (historical expectations = Russian source text).
    override func setUp() {
        super.setUp()
        activateLocalization("ru")
        // Point legacy migration at a non-existent dir so tests never copy the real ~/…/Murmur dataset.
        HistoryStore.legacyBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParlaTests-NoLegacy-\(UUID().uuidString)")
        // CRITICAL ISOLATION: redirect the store itself to a throwaway dir for EVERY test, process-wide. This is
        // the bulletproof guard (not the per-test drain): even a detached refresh Task that outlives a per-test
        // `withTemporaryHistoryStore` scope writes here, never the user's real ~/Library/.../Parla data. Embedding/
        // audio dirs derive from this path, so they're redirected too.
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParlaTests-Store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        HistoryStore.fileURL = storeDir.appendingPathComponent("history.json")
        // ProcessedStore is a SEPARATE global path (not derived from HistoryStore.fileURL) — redirect it too,
        // or folder-watch tests would write the user's real processed.json. (EmbeddingStore/AudioStore DO derive
        // from HistoryStore.fileURL's dir, so they're already covered.)
        ProcessedStore.fileURL = storeDir.appendingPathComponent("processed.json")
        // The MLX model cache is ANOTHER global path that reads the real disk — redirect it to a temp dir so
        // `MLXModelSpec.isDownloaded()` is deterministic (false) in tests. Otherwise, once the user has actually
        // downloaded the RU/UK model, availability tests would see `.ready` and flake. (Same class as above.)
        MLXModelSpec.downloadBase = storeDir.appendingPathComponent("mlx")
        // The embedding-model cache is likewise a separate global path — redirect it so `EmbeddingModelSpec.isDownloaded()`
        // is deterministic (false) in tests; otherwise the retrieval-embedder routing would pick the real downloaded
        // model over the injected fake (the probe already downloaded it on the dev machine).
        EmbeddingModelSpec.downloadBase = storeDir.appendingPathComponent("embed")
    }

    // MARK: Model names

    func testPrettyModel() {
        XCTAssertEqual(prettyModel("openai_whisper-tiny"), "Tiny")
        XCTAssertEqual(prettyModel("openai_whisper-large-v3"), "Large v3")
        XCTAssertEqual(prettyModel(""), "")
    }

    func testFriendlyModel() {
        XCTAssertEqual(friendlyModel("openai_whisper-large-v3-v20240930_626MB"), "Large v3 turbo")
        XCTAssertEqual(friendlyModel("openai_whisper-large-v3-v20240930"), "Large v3 turbo")
        XCTAssertEqual(friendlyModel("openai_whisper-large-v3"), "Large v3")
        XCTAssertEqual(friendlyModel("openai_whisper-large-v3_947MB"), "Large v3")
        XCTAssertEqual(friendlyModel("distil-whisper_distil-large-v3"), "Distil Large v3")
        XCTAssertEqual(friendlyModel("openai_whisper-large-v2_949MB"), "Large v2")
        XCTAssertEqual(friendlyModel("openai_whisper-medium"), "Medium")
        XCTAssertEqual(friendlyModel("openai_whisper-small"), "Small")
        XCTAssertEqual(friendlyModel("openai_whisper-base"), "Base")
        XCTAssertEqual(friendlyModel("openai_whisper-tiny"), "Tiny")
        XCTAssertEqual(friendlyModel("something-weird"), prettyModel("something-weird"))
    }

    // MARK: Formatting

    func testFmtTime() {
        XCTAssertEqual(fmtTime(0), "00:00")
        XCTAssertEqual(fmtTime(5), "00:05")
        XCTAssertEqual(fmtTime(59), "00:59")
        XCTAssertEqual(fmtTime(60), "01:00")
        XCTAssertEqual(fmtTime(65), "01:05")
        XCTAssertEqual(fmtTime(3661), "61:01")
    }

    func testFormatBytes() {
        XCTAssertEqual(formatBytes(0), "—")
        XCTAssertEqual(formatBytes(-5), "—")
        XCTAssertEqual(formatBytes(500 * 1_048_576), "500 МБ")
        XCTAssertEqual(formatBytes(Int64(1.5 * 1024 * 1_048_576)), "1.5 ГБ")
    }

    // MARK: Dictation

    /// The recorder writes WhisperKit's native input format. If this constant drifts, dictation would
    /// silently produce the wrong sample rate / channel count and tank recognition quality. (The live
    /// mic path itself is manual-only — this pins the one piece that's pure and regressable.)
    @MainActor
    func testDictationTargetFormatIs16kMonoInt16() {
        let f = MicRecorder.targetFormat
        XCTAssertEqual(f.sampleRate, 16_000)
        XCTAssertEqual(f.channelCount, 1)
        XCTAssertEqual(f.commonFormat, .pcmFormatInt16)
    }

    // MARK: Streaming engine seam

    /// The streaming seam decodes an in-memory Float buffer and threads results through the SAME mapping
    /// as the file path. The real WhisperKit decode is manual-only; this pins the seam's shape + that the
    /// orchestrator gets a buffer-sized, canned-result double to drive.
    func testStreamingSeamDecodesBufferAndReportsSize() async throws {
        let canned = EngineResult(text: "привет", language: "ru",
                                  segments: [Segment(start: 0, end: 1, text: "привет")], duration: 1)
        let fake = FakeEngine(results: [canned])
        let r = try await fake.transcribe(samples: [Float](repeating: 0, count: 16_000),
                                          language: "ru", model: "m")
        XCTAssertEqual(r.text, "привет")
        XCTAssertEqual(r.segments.count, 1)
        XCTAssertEqual(fake.transcribedSampleCounts, [16_000])
        XCTAssertEqual(fake.transcribeCalls, 1)
    }

    /// The streaming Float feed must be bit-identical to how WhisperKit reads an Int16 WAV (÷32768) — if it
    /// drifts (e.g. ÷32767), the live path and the file path would decode subtly different samples. The live
    /// tap itself is manual-only; this pins the one pure piece. (Int16 min −32768 → exactly −1.0.)
    func testStreamingNormalizeMatchesWhisperKitWavScaling() {
        XCTAssertEqual(MicRecorder.normalize([0]), [0])
        XCTAssertEqual(MicRecorder.normalize([-32768]), [-1.0])
        XCTAssertEqual(MicRecorder.normalize([16384]), [0.5])
        XCTAssertEqual(MicRecorder.normalize([32767]).first!, 32767.0 / 32768.0, accuracy: 1e-7)
        XCTAssertEqual(MicRecorder.normalize([]).count, 0)
    }

    /// Launch pre-warm fires only for users who dictate (hotkey on) AND when the model is already on disk
    /// (never start a download from a pre-warm).
    func testShouldPrewarmModelGate() {
        XCTAssertTrue(AppModel.shouldPrewarmModel(dictationHotkeyEnabled: true, modelDownloaded: true))
        XCTAssertFalse(AppModel.shouldPrewarmModel(dictationHotkeyEnabled: true, modelDownloaded: false))
        XCTAssertFalse(AppModel.shouldPrewarmModel(dictationHotkeyEnabled: false, modelDownloaded: true))
        XCTAssertFalse(AppModel.shouldPrewarmModel(dictationHotkeyEnabled: false, modelDownloaded: false))
    }

    /// Streaming language is pinned after the first detection so short windows don't flap (RU/UK guardrail).
    func testLockedLanguagePinsAfterFirstDetect() {
        XCTAssertEqual(AppModel.lockedLanguage(current: "ru", detected: "en"), "ru")   // explicit / already-locked wins
        XCTAssertEqual(AppModel.lockedLanguage(current: nil, detected: "ru"), "ru")    // Auto → lock the first detection
        XCTAssertNil(AppModel.lockedLanguage(current: nil, detected: ""))              // nothing detected yet → stay Auto
        XCTAssertEqual(AppModel.lockedLanguage(current: "uk", detected: ""), "uk")     // keep current on an empty detect
    }

    // MARK: Streaming reconciler

    private func seg(_ start: Double, _ end: Double, _ text: String) -> Segment {
        Segment(start: start, end: end, text: text)
    }

    /// Confirm all but the last `holdback` segments; the tail is the dimmed hypothesis; the cursor advances
    /// to the last confirmed segment's absolute end.
    func testReconcilerConfirmsAllButHoldback() {
        var r = StreamingReconciler(holdback: 2)
        r.ingest(segments: [seg(0, 1, "a"), seg(1, 2, "b"), seg(2, 3, "c")], windowStart: 0)
        XCTAssertEqual(r.confirmedText, "a")
        XCTAssertEqual(r.hypothesisText, "b c")
        XCTAssertEqual(r.confirmedSeconds, 1, accuracy: 1e-9)
        XCTAssertEqual(r.liveText, "a b c")
    }

    /// With ≤ holdback segments nothing is stable yet: confirm nothing, hold the cursor, everything is hypothesis.
    func testReconcilerWithholdsWhenTooFewSegments() {
        var r = StreamingReconciler(holdback: 2)
        r.ingest(segments: [seg(0, 1, "only"), seg(1, 2, "two")], windowStart: 0)
        XCTAssertEqual(r.confirmedText, "")
        XCTAssertEqual(r.hypothesisText, "only two")
        XCTAssertEqual(r.confirmedSeconds, 0, accuracy: 1e-9)
    }

    /// Across ticks the confirmed text accumulates IN ORDER with no double-counting: segments that were the
    /// hypothesis tail one tick get confirmed the next (the window restarts at the advanced cursor).
    func testReconcilerAccumulatesAcrossTicksNoDoubleCount() {
        var r = StreamingReconciler(holdback: 2)
        // Tick 1: window @0 → confirm "a", hold "b c".
        r.ingest(segments: [seg(0, 1, "a"), seg(1, 2, "b"), seg(2, 3, "c")], windowStart: 0)
        // Tick 2: window restarts @ confirmedSeconds (1.0); decode is window-relative → "b c" now confirm-able.
        r.ingest(segments: [seg(0, 1, "b"), seg(1, 2, "c"), seg(2, 3, "d"), seg(3, 4, "e")],
                 windowStart: r.confirmedSeconds)
        XCTAssertEqual(r.confirmedText, "a b c")          // b, c counted exactly once
        XCTAssertEqual(r.hypothesisText, "d e")
        XCTAssertEqual(r.confirmedSeconds, 3, accuracy: 1e-9)   // 1.0 windowStart + 2.0 last confirmed end
    }

    /// An empty (silent) window doesn't disturb the confirmed prefix or cursor; it just clears the hypothesis.
    func testReconcilerEmptyWindowKeepsConfirmed() {
        var r = StreamingReconciler(holdback: 2)
        r.ingest(segments: [seg(0, 1, "a"), seg(1, 2, "b"), seg(2, 3, "c")], windowStart: 0)
        r.ingest(segments: [], windowStart: r.confirmedSeconds)
        XCTAssertEqual(r.confirmedText, "a")
        XCTAssertEqual(r.hypothesisText, "")
        XCTAssertEqual(r.confirmedSeconds, 1, accuracy: 1e-9)
    }

    /// holdback 0 confirms everything (a "flush"-style decode), nothing held back.
    func testReconcilerHoldbackZeroConfirmsAll() {
        var r = StreamingReconciler(holdback: 0)
        r.ingest(segments: [seg(0, 1, "a"), seg(1, 2, "b")], windowStart: 5)
        XCTAssertEqual(r.confirmedText, "a b")
        XCTAssertEqual(r.hypothesisText, "")
        XCTAssertEqual(r.confirmedSeconds, 7, accuracy: 1e-9)   // 5 windowStart + 2 last end
    }

    /// Joining trims each segment, drops empties, and uses single spaces (Whisper segment text often carries
    /// leading spaces / blank tokens after stripping).
    func testReconcilerJoinNormalizesSpacing() {
        var r = StreamingReconciler(holdback: 0)
        r.ingest(segments: [seg(0, 1, "  hello "), seg(1, 2, ""), seg(2, 3, " world")], windowStart: 0)
        XCTAssertEqual(r.confirmedText, "hello world")
    }

    /// `flush: true` overrides holdback and confirms every segment, advancing the cursor — the orchestrator
    /// uses this when the window has grown large without confirming (continuous speech), to keep it bounded.
    func testReconcilerFlushConfirmsAllSegmentsDespiteHoldback() {
        var r = StreamingReconciler(holdback: 2)
        r.ingest(segments: [seg(0, 1, "a"), seg(1, 2, "b"), seg(2, 3, "c")], windowStart: 0, flush: true)
        XCTAssertEqual(r.confirmedText, "a b c")          // all confirmed despite holdback 2
        XCTAssertEqual(r.hypothesisText, "")
        XCTAssertEqual(r.confirmedSeconds, 3, accuracy: 1e-9)
    }

    /// Overlap-aware merge drops ONLY the single boundary word a re-decoded window can re-emit — never a
    /// longer run (that would eat genuinely repeated speech, the regression the re-review caught).
    func testReconcilerMergeDedupDropsSingleBoundaryWord() {
        XCTAssertEqual(StreamingReconciler.mergeDedup("привет", "привет мир"), "привет мир")     // re-emit removed
        XCTAssertEqual(StreamingReconciler.mergeDedup("раз два три", "три четыре"), "раз два три четыре")
        XCTAssertEqual(StreamingReconciler.mergeDedup("a b", "c d"), "a b c d")                 // no overlap
        XCTAssertEqual(StreamingReconciler.mergeDedup("так", "так"), "так")                     // pure single re-emit
        XCTAssertEqual(StreamingReconciler.mergeDedup("", "hello"), "hello")
        XCTAssertEqual(StreamingReconciler.mergeDedup("done", ""), "done")
        // A genuinely repeated run is PRESERVED (minus only the one boundary word) — NOT collapsed.
        XCTAssertEqual(StreamingReconciler.mergeDedup("да да да", "да да да да да"), "да да да да да да да")
    }

    /// The decode window is clamped to a max look-back so a stalled cursor (zero-segment silence / pre-first
    /// confirm) can't grow the decode or the lock-held copy without bound.
    func testStreamWindowStartClampsToMaxLookback() {
        let maxW = 240_000   // 15 s @ 16 kHz
        // Cursor recent → start at the cursor (no clamp).
        XCTAssertEqual(AppModel.streamWindowStartSample(cursorSample: 100_000, liveCount: 120_000, maxWindow: maxW), 100_000)
        // Cursor stalled far back → clamp to liveCount - maxWindow.
        XCTAssertEqual(AppModel.streamWindowStartSample(cursorSample: 0, liveCount: 400_000, maxWindow: maxW), 160_000)
        // Buffer shorter than the window → start at the cursor (0).
        XCTAssertEqual(AppModel.streamWindowStartSample(cursorSample: 0, liveCount: 50_000, maxWindow: maxW), 0)
    }

    /// End-to-end: a tick whose re-decoded window re-emits the prior confirmed word must NOT duplicate it.
    func testReconcilerNoDuplicateWordAcrossReSegmentedWindow() {
        var r = StreamingReconciler(holdback: 2)
        r.ingest(segments: [seg(0, 1, "a"), seg(1, 2, "b"), seg(2, 3, "c")], windowStart: 0)   // confirm "a"
        // Next window restarts at the cursor (1.0) but re-emits "a" first (cut landed before a's acoustic end).
        r.ingest(segments: [seg(0, 1, "a"), seg(1, 2, "b"), seg(2, 3, "c"), seg(3, 4, "d")], windowStart: 1.0)
        XCTAssertEqual(r.confirmedText, "a b")            // "a" not duplicated, "b" confirmed
        XCTAssertEqual(r.hypothesisText, "c d")
    }

    // MARK: TranscriptItem

    func testDisplayPlain() {
        let item = makeItem(text: "привет мир", segments: [])
        XCTAssertEqual(item.display(timestamps: false), "привет мир")
        XCTAssertEqual(item.display(timestamps: true), "привет мир")   // no segments → fallback
    }

    func testDisplayTimestamps() {
        let segs = [Segment(start: 0, end: 2, text: "привет"), Segment(start: 65, end: 67, text: "мир")]
        let item = makeItem(text: "привет мир", segments: segs)
        XCTAssertEqual(item.display(timestamps: true), "[00:00] привет\n[01:05] мир")
        XCTAssertEqual(item.display(timestamps: false), "привет мир")
    }

    func testWordCount() {
        XCTAssertEqual(makeItem(text: "привет мир как дела").wordCount, 4)
        XCTAssertEqual(makeItem(text: "  один  ").wordCount, 1)
        XCTAssertEqual(makeItem(text: "").wordCount, 0)
        XCTAssertEqual(makeItem(text: "строка\nдве слова").wordCount, 3)
    }

    func testCodableRoundtrip() throws {
        let item = makeItem(text: "txt", segments: [Segment(start: 0, end: 1, text: "x")])
        let data = try JSONEncoder().encode([item])
        let back = try JSONDecoder().decode([TranscriptItem].self, from: data)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].id, item.id)
        XCTAssertEqual(back[0].text, "txt")
        XCTAssertEqual(back[0].segments.first?.text, "x")
        XCTAssertEqual(back[0].model, item.model)
    }

    // MARK: History — search

    func testFilterHistory() {
        let items = [
            makeItem(name: "a.ogg", text: "привет мир"),
            makeItem(name: "b.ogg", text: "пока всем"),
            makeItem(name: "secret.ogg", text: "ничего"),
        ]
        XCTAssertEqual(filterHistory(items, query: "").count, 3)       // empty query → all
        XCTAssertEqual(filterHistory(items, query: "  ").count, 3)     // whitespace → all
        XCTAssertEqual(filterHistory(items, query: "мир").count, 1)    // by text
        XCTAssertEqual(filterHistory(items, query: "ПРИВЕТ").count, 1) // case-insensitive
        XCTAssertEqual(filterHistory(items, query: "secret").count, 1) // by file name
        XCTAssertEqual(filterHistory(items, query: "неттакого").count, 0)
        // Morphology path: with a lemma index, a query lemma matches even with no substring hit anywhere.
        let lemmas = [items[2].id: Set(["тайна"])]                       // secret.ogg ("ничего") tagged with «тайна»
        XCTAssertEqual(filterHistory(items, query: "тайна", lemmaIndex: lemmas).map(\.id), [items[2].id])
        XCTAssertTrue(filterHistory(items, query: "тайна").isEmpty)      // no index → substring only → nothing
    }

    /// True when the host's NLTagger has the Russian lemma asset (inflected → dictionary-form reduction).
    /// Fresh CI runners lack it — the on-device NL language models download on demand and aren't present on a
    /// clean image — so the morphology tests `XCTSkipUnless` this: meaningful on a dev machine (asset present),
    /// green in CI (asset absent). The feature itself degrades gracefully at runtime when the asset is missing.
    private var hasRussianLemmatizer: Bool { searchLemmaSet(of: "работе").contains("работа") }

    func testLemmaSet() throws {
        try XCTSkipUnless(hasRussianLemmatizer, "Russian NLTagger lemma asset unavailable on this host")
        let s = lemmaSet(of: "Обсудили проекты и работу команды", language: "ru")
        XCTAssertTrue(s.contains("проект"))   // проекты → проект
        XCTAssertTrue(s.contains("работа"))   // работу → работа
        XCTAssertFalse(s.contains("и"))       // ≤2 chars dropped as noise
        XCTAssertTrue(lemmaSet(of: "   ").isEmpty)
    }

    // MARK: History — export

    func testExportText() {
        let items = [makeItem(name: "a.ogg", text: "первый"), makeItem(name: "b.ogg", text: "второй")]
        let out = exportText(items)
        XCTAssertTrue(out.hasPrefix("# Parla"))
        XCTAssertTrue(out.contains("## a.ogg"))
        XCTAssertTrue(out.contains("первый"))
        XCTAssertTrue(out.contains("второй"))
        XCTAssertEqual(exportText([]).hasPrefix("# Parla"), true)
    }

    // MARK: History — Murmur → Parla migration

    func testMigrationCopiesWhenTargetMissing() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        let legacy = tmp.appendingPathComponent("Murmur/history.json")
        let target = tmp.appendingPathComponent("Parla/history.json")
        try fm.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: legacy)

        HistoryStore.migrate(target: target, legacy: legacy)
        XCTAssertTrue(fm.fileExists(atPath: target.path))

        try Data("[1,2,3]".utf8).write(to: legacy)  // run again — does not overwrite
        HistoryStore.migrate(target: target, legacy: legacy)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "[]")
    }

    func testMigrationNoopWhenLegacyMissing() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        let target = tmp.appendingPathComponent("Parla/history.json")
        HistoryStore.migrate(target: target, legacy: tmp.appendingPathComponent("Murmur/history.json"))
        XCTAssertFalse(fm.fileExists(atPath: target.path))
    }

    // MARK: Default model selection

    func testBestDefault() {
        XCTAssertEqual(AppModel.bestDefault(from: ["openai_whisper-base", "openai_whisper-large-v3-v20240930"]),
                       "openai_whisper-large-v3-v20240930")
        XCTAssertEqual(AppModel.bestDefault(from: ["openai_whisper-base", "openai_whisper-large-v3-v20240930_626MB"]),
                       "openai_whisper-large-v3-v20240930_626MB")
        // 626MB quantized turbo wins over the full-precision 1.5GB variant when BOTH are present
        // (measured: quantized decodes RU better + is smaller).
        XCTAssertEqual(AppModel.bestDefault(from: ["openai_whisper-large-v3-v20240930", "openai_whisper-large-v3-v20240930_626MB"]),
                       "openai_whisper-large-v3-v20240930_626MB")
        XCTAssertEqual(AppModel.bestDefault(from: ["openai_whisper-large-v3", "openai_whisper-tiny"]),
                       "openai_whisper-large-v3")
        XCTAssertEqual(AppModel.bestDefault(from: ["openai_whisper-small", "openai_whisper-base"]),
                       "openai_whisper-base")
        XCTAssertEqual(AppModel.bestDefault(from: ["openai_whisper-small"]), "openai_whisper-small")
        XCTAssertEqual(AppModel.bestDefault(from: []), "openai_whisper-base")
    }

    func testRepinnedLanguage() {
        // Unchanged explicit pick → keep the current lock (which auto-detect may have pinned).
        XCTAssertEqual(AppModel.repinnedLanguage(explicit: "ru", lastExplicit: "ru", locked: "ru").locked, "ru")
        XCTAssertEqual(AppModel.repinnedLanguage(explicit: nil, lastExplicit: nil, locked: "uk").locked, "uk")
        // User switches the pill mid-dictation RU→EN → re-pin the lock to the new explicit choice.
        let toEN = AppModel.repinnedLanguage(explicit: "en", lastExplicit: "ru", locked: "ru")
        XCTAssertEqual(toEN.locked, "en"); XCTAssertEqual(toEN.lastExplicit, "en")
        // User switches to Auto (explicit nil) → drop the lock to nil so detection re-pins next window.
        let toAuto = AppModel.repinnedLanguage(explicit: nil, lastExplicit: "ru", locked: "ru")
        XCTAssertNil(toAuto.locked); XCTAssertNil(toAuto.lastExplicit)
    }

    // MARK: Model paths / sizes

    func testLocalFolderPath() {
        let url = TranscriptionEngine.localFolder("openai_whisper-tiny")
        XCTAssertTrue(url.path.hasSuffix("huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-tiny"),
                      url.path)
    }

    func testFolderSize() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1000).write(to: tmp.appendingPathComponent("a.bin"))
        try Data(repeating: 0, count: 2000).write(to: tmp.appendingPathComponent("sub/b.bin"))
        XCTAssertEqual(TranscriptionEngine.folderSize(at: tmp), 3000)
        XCTAssertEqual(TranscriptionEngine.folderSize(at: tmp.appendingPathComponent("nope")), 0)
    }

    // MARK: Collecting audio files from a folder

    func testAudioFiles() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for name in ["b.mp3", "a.ogg", "note.txt", "image.png"] {
            try Data("x".utf8).write(to: tmp.appendingPathComponent(name))
        }
        try Data("x".utf8).write(to: tmp.appendingPathComponent("sub/d.wav"))

        let found = AppModel.audioFiles(in: tmp).map { $0.lastPathComponent }
        XCTAssertEqual(found, ["a.ogg", "b.mp3", "d.wav"])  // audio only, sorted by name
        XCTAssertFalse(found.contains("note.txt"))
        XCTAssertFalse(found.contains("image.png"))
    }

    // MARK: Languages

    func testLanguages() {
        XCTAssertGreaterThan(whisperLanguages.count, 20)
        XCTAssertEqual(whisperLanguages.first?.code, "")   // «Auto» first
        XCTAssertTrue(whisperLanguages.contains { $0.code == "en" })
        XCTAssertTrue(whisperLanguages.contains { $0.code == "ru" })
        XCTAssertTrue(whisperLanguages.contains { $0.code == "uk" })
        // codes are unique
        XCTAssertEqual(Set(whisperLanguages.map(\.code)).count, whisperLanguages.count)
    }

    // MARK: Model tiers

    @MainActor func testModelTiersCuration() {
        let m = AppModel()
        m.availableModels = [
            "openai_whisper-tiny", "openai_whisper-base", "openai_whisper-small",
            "openai_whisper-large-v3-v20240930_626MB", "openai_whisper-large-v3",
            "openai_whisper-large-v3_947MB", "distil-whisper_distil-large-v3",
        ]
        m.selectedModel = "openai_whisper-large-v3-v20240930_626MB"
        let tiers = m.modelTiers

        XCTAssertEqual(tiers.count, 5)                                   // 5 tiers, no clones
        XCTAssertEqual(tiers.first(where: { $0.recommended })?.name,
                       "openai_whisper-large-v3-v20240930_626MB")
        XCTAssertTrue(tiers.contains { $0.title == "Large v3 turbo" })
        XCTAssertFalse(tiers.contains { $0.name.contains("distil") })
        XCTAssertFalse(tiers.contains { $0.name.contains("947MB") })
    }

    @MainActor func testModelTiersCurrentFallback() {
        let m = AppModel()
        m.availableModels = [
            "openai_whisper-tiny", "openai_whisper-base", "openai_whisper-small",
            "openai_whisper-large-v3-v20240930_626MB", "openai_whisper-large-v3",
            "openai_whisper-large-v2_949MB",
        ]
        m.selectedModel = "openai_whisper-large-v2_949MB"   // matches no tier
        let tiers = m.modelTiers
        XCTAssertEqual(tiers.count, 6)                       // 5 + «current»
        XCTAssertEqual(tiers.last?.name, "openai_whisper-large-v2_949MB")
        XCTAssertEqual(tiers.last?.title, "Large v2")
    }

    // MARK: Extra coverage (from review)

    func testDisplayDropsEmptySegments() {
        let segs = [Segment(start: 0, end: 1, text: "привет"),
                    Segment(start: 1, end: 2, text: ""),
                    Segment(start: 2, end: 3, text: "мир")]
        let item = makeItem(text: "привет мир", segments: segs)
        XCTAssertEqual(item.display(timestamps: true), "[00:00] привет\n[00:02] мир")  // empty segment dropped
    }

    func testFmtTimeNegativeAndRounding() {
        XCTAssertEqual(fmtTime(-5), "00:00")    // negative is clamped
        XCTAssertEqual(fmtTime(-1), "00:00")
        XCTAssertEqual(fmtTime(59.6), "01:00")  // rounds up
        XCTAssertEqual(fmtTime(0.4), "00:00")
    }

    func testFormatBytesBoundaries() {
        XCTAssertEqual(formatBytes(1), "0 МБ")
        XCTAssertEqual(formatBytes(1023 * 1_048_576), "1023 МБ")
        XCTAssertEqual(formatBytes(1024 * 1_048_576), "1.0 ГБ")
    }

    func testAudioFilesCaseInsensitiveAndExtensions() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        for name in ["A.OGG", "b.M4A", "c.Opus", "d.flac", "f.mp4", "skip.txt", "drop.webm"] {
            try Data("x".utf8).write(to: tmp.appendingPathComponent(name))
        }
        let found = Set(AppModel.audioFiles(in: tmp).map { $0.lastPathComponent })
        XCTAssertTrue(found.isSuperset(of: ["A.OGG", "b.M4A", "c.Opus", "d.flac", "f.mp4"]))
        XCTAssertFalse(found.contains("skip.txt"))
        // Phase 2c (native-first decode) dropped webm/amr/wma → no longer recognized as importable audio.
        XCTAssertFalse(found.contains("drop.webm"))
    }

    /// Intake filter: a known extension qualifies; an EXTENSION-LESS (or share-inbox `.dat`) file qualifies only
    /// when its header sniffs as Ogg. A real-but-unsupported extension is still rejected by name (no sniffing
    /// `.txt`/`.webm`). Pins the fix for silently-ignored extension-less Telegram voice notes.
    func testIsTranscribableAcceptsExtensionlessOggOnly() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("parla-intake-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        func write(_ name: String, _ bytes: String) throws -> URL {
            let u = dir.appendingPathComponent(name)
            try Data(bytes.utf8).write(to: u)
            return u
        }
        let ogg = "OggS\u{01}\u{00}\u{00}\u{00}"

        // Known extensions → accepted on name alone (content irrelevant).
        XCTAssertTrue(AppModel.isTranscribable(try write("a.m4a", "x")))
        XCTAssertTrue(AppModel.isTranscribable(try write("b.OGG", "x")))
        // Extension-less: accepted ONLY with the Ogg magic (the Telegram-voice case).
        XCTAssertTrue(AppModel.isTranscribable(try write("voice_30-07-2026_20-26-47", ogg)))
        XCTAssertFalse(AppModel.isTranscribable(try write("random-blob", "not audio at all")))
        // Share-inbox placeholder extension: same content rule (an extension-less shared item lands as `.dat`).
        XCTAssertTrue(AppModel.isTranscribable(try write("shared.dat", ogg)))
        XCTAssertFalse(AppModel.isTranscribable(try write("other.dat", "junk")))
        // A real but unsupported extension is rejected by NAME — never sniffed.
        XCTAssertFalse(AppModel.isTranscribable(try write("notes.txt", ogg)))
        XCTAssertFalse(AppModel.isTranscribable(try write("clip.webm", ogg)))
        // Missing file → false, never a crash.
        XCTAssertFalse(AppModel.isTranscribable(dir.appendingPathComponent("gone-\(UUID().uuidString)")))
    }

    /// A dropped/watched FOLDER must pick up an extension-less Ogg voice note too (same intake rule).
    func testAudioFilesPicksUpExtensionlessOgg() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("parla-folder-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try Data("OggS\u{01}\u{00}\u{00}\u{00}".utf8).write(to: dir.appendingPathComponent("voice_no_ext"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("note.txt"))
        let found = Set(AppModel.audioFiles(in: dir).map(\.lastPathComponent))
        XCTAssertTrue(found.contains("voice_no_ext"))
        XCTAssertFalse(found.contains("note.txt"))
    }

    func testAudioFilesEmptyAndMissing() throws {
        let fm = FileManager.default
        let empty = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: empty) }
        XCTAssertEqual(AppModel.audioFiles(in: empty), [])
        XCTAssertEqual(AppModel.audioFiles(in: fm.temporaryDirectory.appendingPathComponent("nope-\(UUID())")), [])
    }

    func testBestDefaultEnExclusion() {
        XCTAssertEqual(AppModel.bestDefault(from: ["openai_whisper-base.en", "openai_whisper-tiny"]),
                       "openai_whisper-base.en")   // base branch skips .en → first element
        XCTAssertEqual(AppModel.bestDefault(from: ["openai_whisper-base.en", "openai_whisper-base"]),
                       "openai_whisper-base")       // picks the non-.en base
    }

    func testPrettyModelMultiToken() {
        XCTAssertEqual(prettyModel("openai_whisper-large-v3-v20240930_turbo_632MB"),
                       "Large v3 v20240930 turbo 632MB")
    }

    func testExportTextMetadataAndSeparator() {
        let items = [
            makeItem(name: "a.ogg", text: "txt", lang: "ru", model: "openai_whisper-large-v3"),
            makeItem(name: "b.ogg", text: "txt2", lang: "en", model: "openai_whisper-small"),
        ]
        let out = exportText(items)
        XCTAssertTrue(out.contains("RU · Large v3"))
        XCTAssertTrue(out.contains("EN · Small"))
        XCTAssertEqual(out.components(separatedBy: "---").count, items.count + 1)  // one separator per entry
    }

    @MainActor func testModelTiersPrefixFallback() {
        let m = AppModel()
        m.availableModels = ["openai_whisper-tiny", "openai_whisper-large-v3-v20240930_626MB_quant"]
        m.selectedModel = "openai_whisper-tiny"
        XCTAssertTrue(m.modelTiers.contains { $0.title == "Large v3 turbo" })  // resolved by prefix
    }

    @MainActor func testModelTiersSparse() {
        let m = AppModel()
        m.availableModels = ["openai_whisper-small", "openai_whisper-large-v3"]
        m.selectedModel = "openai_whisper-small"
        let titles = Set(m.modelTiers.map(\.title))
        XCTAssertTrue(titles.contains("Small"))
        XCTAssertTrue(titles.contains("Large v3"))
        XCTAssertFalse(titles.contains("Tiny"))
        XCTAssertFalse(titles.contains("Base"))
        XCTAssertLessThan(m.modelTiers.count, 5)   // missing tiers are not shown
    }

    // MARK: Text editing (feature 02)

    func testNormalizedEditDetectsChange() {
        let a = normalizedEdit("новый текст", from: "старый")
        XCTAssertTrue(a.changed)
        XCTAssertEqual(a.text, "новый текст")
        let b = normalizedEdit("одинаковый", from: "одинаковый")
        XCTAssertFalse(b.changed)
        XCTAssertEqual(b.text, "одинаковый")
    }

    func testNormalizedEditTrimsAndIgnoresWhitespace() {
        XCTAssertFalse(normalizedEdit("  привет мир  \n", from: "привет мир").changed)  // trimming → equal
        XCTAssertFalse(normalizedEdit("a\r\nb", from: "a\nb").changed)                  // CRLF normalized
        let changed = normalizedEdit("  новое  ", from: "старое")
        XCTAssertTrue(changed.changed)
        XCTAssertEqual(changed.text, "новое")   // returns the trimmed text
    }

    func testNormalizedEditEmptyKeepsOriginal() {
        let r = normalizedEdit("   ", from: "оригинал")
        XCTAssertEqual(r.text, "оригинал")   // we don't apply an empty edit
        XCTAssertFalse(r.changed)
    }

    func testEditedItemSuppressesTimestamps() {
        let segs = [Segment(start: 0, end: 2, text: "привет"), Segment(start: 65, end: 67, text: "мир")]
        let edited = makeItem(text: "привет мир", segments: segs, edited: true)
        XCTAssertEqual(edited.display(timestamps: true), "привет мир")   // timestamps suppressed
        let notEdited = makeItem(text: "привет мир", segments: segs, edited: false)
        XCTAssertEqual(notEdited.display(timestamps: true), "[00:00] привет\n[01:05] мир")
        let legacy = makeItem(text: "привет мир", segments: segs, edited: nil)
        XCTAssertEqual(legacy.display(timestamps: true), "[00:00] привет\n[01:05] мир")  // nil = not edited
    }

    /// Key migration test: an old history.json without the edited/editedAt keys decodes without throwing.
    func testCodableBackwardCompatLegacyJSON() throws {
        let legacy = #"[{"id":"\#(UUID().uuidString)","date":740000000,"sourceName":"a.ogg","language":"ru","durationSec":1,"model":"openai_whisper-tiny","text":"привет","segments":[]}]"#
        let items = try JSONDecoder().decode([TranscriptItem].self, from: Data(legacy.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items.first?.edited)              // missing key → nil, NOT a throw
        XCTAssertFalse(items.first?.isEdited ?? true)
        XCTAssertNil(items.first?.editedAt)
        XCTAssertEqual(items.first?.text, "привет")
    }

    func testCodableRoundtripWithEditFields() throws {
        var item = makeItem(text: "txt", segments: [Segment(start: 0, end: 1, text: "x")])
        item.edited = true
        item.editedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try JSONEncoder().encode([item])
        let back = try JSONDecoder().decode([TranscriptItem].self, from: data)
        XCTAssertEqual(back.first?.edited, true)
        XCTAssertTrue(back.first?.isEdited ?? false)
        XCTAssertEqual(back.first?.editedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - Optional fields, displayTitle, seam gating

    /// T1 (mandatory): a history.json written before the AI layer (no title/summary/actions/aiModel
    /// keys) still decodes; all four are nil; displayTitle falls back to sourceName.
    func testLegacyJSONDecodesWithoutAIKeys() throws {
        let legacy = #"[{"id":"\#(UUID().uuidString)","date":740000000,"sourceName":"msg123.ogg","language":"ru","durationSec":1,"model":"openai_whisper-tiny","text":"привет","segments":[]}]"#
        let items = try JSONDecoder().decode([TranscriptItem].self, from: Data(legacy.utf8))
        XCTAssertEqual(items.count, 1)
        let it = try XCTUnwrap(items.first)
        XCTAssertNil(it.title); XCTAssertNil(it.summary); XCTAssertNil(it.actions)
        XCTAssertNil(it.aiModel); XCTAssertNil(it.titleEdited); XCTAssertNil(it.keywords)
        XCTAssertEqual(it.displayTitle, "msg123.ogg")   // nil title → sourceName
    }

    /// T2: a record carrying insights round-trips, including a toggled ActionItem.done.
    func testCodableRoundtripWithInsights() throws {
        var item = makeItem(name: "note.m4a", text: "длинный текст")
        item.title = "Звонок с командой"
        item.summary = "Обсудили релиз и сроки."
        item.actions = [ActionItem(text: "написать Олегу", done: true),
                        ActionItem(text: "запушить ветку", done: false)]
        item.aiModel = "foundationmodels"
        item.keywords = ["релиз", "сроки"]
        let back = try JSONDecoder().decode([TranscriptItem].self, from: JSONEncoder().encode([item]))
        let r = try XCTUnwrap(back.first)
        XCTAssertEqual(r.title, "Звонок с командой")
        XCTAssertEqual(r.summary, "Обсудили релиз и сроки.")
        XCTAssertEqual(r.actions?.count, 2)
        XCTAssertEqual(r.actions?.first, ActionItem(text: "написать Олегу", done: true))
        XCTAssertEqual(r.actions?.last?.done, false)
        XCTAssertEqual(r.aiModel, "foundationmodels")
        XCTAssertEqual(r.keywords, ["релиз", "сроки"])
        XCTAssertEqual(r.displayTitle, "Звонок с командой")
    }

    /// T3: displayTitle — non-empty title wins; nil / empty / whitespace-only → sourceName
    /// (legacy/disabled stay identical; a model emitting a blank title can't render an empty label).
    func testDisplayTitleFallback() {
        var item = makeItem(name: "msg.ogg", text: "t")
        XCTAssertEqual(item.displayTitle, "msg.ogg")     // nil
        item.title = ""
        XCTAssertEqual(item.displayTitle, "msg.ogg")     // empty → fallback, not a blank title
        item.title = "  \n\t "
        XCTAssertEqual(item.displayTitle, "msg.ogg")     // whitespace-only → fallback, not a blank label
        item.title = "Покупки"
        XCTAssertEqual(item.displayTitle, "Покупки")     // present → wins
    }

    /// A stored/hand-edited ActionItem missing `done` defaults to false instead of throwing — a throw
    /// would drop the WHOLE record via the salvage path (FailableDecodable<TranscriptItem>).
    func testActionItemDecodesWithoutDoneKey() throws {
        let bare = try JSONDecoder().decode(ActionItem.self, from: Data(#"{"text":"позвонить"}"#.utf8))
        XCTAssertEqual(bare, ActionItem(text: "позвонить", done: false))
        // …and it survives nested in a record (the path the salvage code walks).
        let rec = #"[{"id":"\#(UUID().uuidString)","date":1,"sourceName":"a.ogg","language":"ru","durationSec":1,"model":"m","text":"t","segments":[],"actions":[{"text":"купить хлеб"}]}]"#
        let items = try JSONDecoder().decode([TranscriptItem].self, from: Data(rec.utf8))
        XCTAssertEqual(items.first?.actions?.first, ActionItem(text: "купить хлеб", done: false))
    }

    /// Pure: BCP-47 primary subtag, lowercased + normalized (drives the language-aware gate).
    func testLanguagePrimarySubtag() {
        XCTAssertEqual(languagePrimarySubtag("en-US"), "en")
        XCTAssertEqual(languagePrimarySubtag("RU_ru"), "ru")
        XCTAssertEqual(languagePrimarySubtag("uk"), "uk")
        XCTAssertEqual(languagePrimarySubtag(""), "")
    }

    /// Load-bearing language gate: FoundationModels covers English, NOT Russian/Ukrainian — the whole
    /// reason Parla needs the embedding + MLX paths. Case/subtag-insensitive.
    func testFoundationModelsLanguageGate() {
        XCTAssertTrue(FoundationModelsService.maySupport(language: "en"))
        XCTAssertTrue(FoundationModelsService.maySupport(language: "EN-US"))
        XCTAssertFalse(FoundationModelsService.maySupport(language: "ru"))
        XCTAssertFalse(FoundationModelsService.maySupport(language: "uk"))
        XCTAssertFalse(FoundationModelsService.maySupport(language: "ru-RU"))
    }

    /// T7 (P0 slice): the generative LLM service NEVER serves ru/uk in P0 — true on every OS
    /// (FoundationModels can't; the MLX RU/UK backend lands). RU/UK get value via SemanticIndex.
    func testDefaultAIServiceNeverReadyForRussianUkrainian() {
        let ai = DefaultAIService()
        XCTAssertNotEqual(ai.availability(forLanguage: "ru"), .ready)
        XCTAssertNotEqual(ai.availability(forLanguage: "uk"), .ready)
        XCTAssertNotEqual(ai.availability(forLanguage: "ru-RU"), .ready)
    }

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

    // MARK: Batch progress + notifications (feature 05)

    func testBatchLabelSingleVsMulti() {
        XCTAssertEqual(batchLabel("a.ogg", nil), "«a.ogg»")
        XCTAssertEqual(batchLabel("a.ogg", BatchProgress(index: 1, total: 1, done: 0)), "«a.ogg»")  // single — no counter
        XCTAssertEqual(batchLabel("a.ogg", BatchProgress(index: 3, total: 12, done: 2)), "«a.ogg» (3 из 12)")
    }

    func testEnginePhaseDefaultBatchNil() {
        XCTAssertEqual(EnginePhase.preparing("x"), .preparing("x", batch: nil))   // default initializer = nil
        XCTAssertNotEqual(EnginePhase.transcribing("x", batch: BatchProgress(index: 1, total: 2, done: 0)),
                          .transcribing("x", batch: nil))
    }

    func testShouldNotifyBatchAlwaysWhenBackground() {
        XCTAssertTrue(BatchNotifier.shouldNotify(total: 5, elapsed: 1, frontmost: false))
    }
    func testShouldNotifyNeverWhenFrontmost() {
        XCTAssertFalse(BatchNotifier.shouldNotify(total: 5, elapsed: 999, frontmost: true))
    }
    func testShouldNotifySingleFileThreshold() {
        XCTAssertFalse(BatchNotifier.shouldNotify(total: 1, elapsed: 5,  frontmost: false))   // fast single — stay quiet
        XCTAssertTrue (BatchNotifier.shouldNotify(total: 1, elapsed: 25, frontmost: false))   // slow single — notify
        XCTAssertFalse(BatchNotifier.shouldNotify(total: 1, elapsed: 25, frontmost: true))    // but if active — no
    }

    func testSummaryAllSuccess() {
        XCTAssertEqual(BatchNotifier.summary(succeeded: 12, failed: 0).body, "Готово: 12 расшифровок")
        XCTAssertEqual(BatchNotifier.summary(succeeded: 1,  failed: 0).body, "Готово: 1 расшифровка")
        XCTAssertEqual(BatchNotifier.summary(succeeded: 3,  failed: 0).body, "Готово: 3 расшифровки")
    }
    func testSummaryAllFailed() {
        XCTAssertEqual(BatchNotifier.summary(succeeded: 0, failed: 4).body, "Не удалось распознать (4)")
    }
    func testSummaryMixed() {
        XCTAssertEqual(BatchNotifier.summary(succeeded: 11, failed: 1).body, "11 из 12 готово · 1 не удалось")
        XCTAssertEqual(BatchNotifier.summary(succeeded: 8,  failed: 4).body, "8 из 12 готово · 4 не удалось")
    }
    func testSummaryTitleAlwaysParla() {
        XCTAssertEqual(BatchNotifier.summary(succeeded: 1, failed: 0).title, "Parla")
        XCTAssertEqual(BatchNotifier.summary(succeeded: 0, failed: 2).title, "Parla")
    }

    func testPluralRu() {
        XCTAssertEqual(pluralRu(1,  "ф", "ф2", "ф5"), "ф")
        XCTAssertEqual(pluralRu(2,  "ф", "ф2", "ф5"), "ф2")
        XCTAssertEqual(pluralRu(5,  "ф", "ф2", "ф5"), "ф5")
        XCTAssertEqual(pluralRu(11, "ф", "ф2", "ф5"), "ф5")   // 11–14 → many
        XCTAssertEqual(pluralRu(21, "ф", "ф2", "ф5"), "ф")    // 21 → one
        XCTAssertEqual(pluralRu(0,  "ф", "ф2", "ф5"), "ф5")
    }

    func testPluralEn() {
        XCTAssertEqual(pluralEn(1, "file", "files"), "file")
        XCTAssertEqual(pluralEn(2, "file", "files"), "files")
        XCTAssertEqual(pluralEn(21, "file", "files"), "files")   // english: 1 → one, everything else → other
        XCTAssertEqual(pluralEn(0, "file", "files"), "files")
    }

    /// All three catalogs (en/ru/uk) must have the SAME set of keys — catches missing translations.
    func testLocalizationKeyParity() {
        func keys(_ lang: String) -> Set<String> {
            let url = repoRoot.appendingPathComponent("Localization/\(lang).lproj/Localizable.strings")
            let dict = NSDictionary(contentsOf: url) as? [String: String] ?? [:]
            return Set(dict.keys)
        }
        let en = keys("en"), ru = keys("ru"), uk = keys("uk")
        XCTAssertGreaterThan(en.count, 100, "english catalog looks empty/unreadable")
        XCTAssertEqual(en, ru, "ru differs from en: \(en.symmetricDifference(ru).sorted())")
        XCTAssertEqual(en, uk, "uk differs from en: \(en.symmetricDifference(uk).sorted())")
    }

    /// Switching the language at runtime really changes the output of localized functions.
    func testLocalizationLanguageSwitch() {
        activateLocalization("en")
        XCTAssertEqual(formatBytes(500 * 1_048_576), "500 MB")
        XCTAssertEqual(batchLabel("a.ogg", BatchProgress(index: 3, total: 12, done: 2)), "“a.ogg” (3 of 12)")
        XCTAssertEqual(BatchNotifier.summary(succeeded: 1, failed: 0).body, "Done: 1 transcription")
        XCTAssertEqual(BatchNotifier.summary(succeeded: 5, failed: 0).body, "Done: 5 transcriptions")
        XCTAssertEqual(BatchNotifier.summary(succeeded: 21, failed: 0).body, "Done: 21 transcriptions") // english 21 → other

        activateLocalization("uk")
        XCTAssertEqual(BatchNotifier.summary(succeeded: 5, failed: 0).body, "Готово: 5 розшифровок")
        XCTAssertEqual(BatchNotifier.summary(succeeded: 1, failed: 0).body, "Готово: 1 розшифровка")
    }

    // MARK: Monetization — free/Pro length gate (Phase 3)

    /// The stateless per-file length gate: FREE covers "up to 5 minutes" (inclusive); a longer file gates a
    /// non-Pro user; Pro is always unlimited; a zero/unknown duration never gates.
    func testProGateLengthBoundaries() {
        XCTAssertEqual(ProGate.freeLimitSec, 300, "free cap is 5 minutes")
        // Free user, at/under the cap → allowed.
        XCTAssertFalse(ProGate.exceedsFreeLimit(durationSec: 1,     isPro: false))
        XCTAssertFalse(ProGate.exceedsFreeLimit(durationSec: 299,   isPro: false))
        XCTAssertFalse(ProGate.exceedsFreeLimit(durationSec: 300,   isPro: false), "exactly 5 min is still free (inclusive)")
        // Free user, over the cap → gated.
        XCTAssertTrue(ProGate.exceedsFreeLimit(durationSec: 300.5,  isPro: false))
        XCTAssertTrue(ProGate.exceedsFreeLimit(durationSec: 301,    isPro: false))
        XCTAssertTrue(ProGate.exceedsFreeLimit(durationSec: 7200,   isPro: false))
        // Pro user → never gated, at any length.
        XCTAssertFalse(ProGate.exceedsFreeLimit(durationSec: 7200,  isPro: true))
        XCTAssertFalse(ProGate.exceedsFreeLimit(durationSec: 301,   isPro: true))
        // Unknown / non-positive duration → never gated (we don't block what we can't measure).
        XCTAssertFalse(ProGate.exceedsFreeLimit(durationSec: 0,     isPro: false))
        XCTAssertFalse(ProGate.exceedsFreeLimit(durationSec: -1,    isPro: false))
    }

    /// The placeholder product ID stays in the `com.parla.*` namespace until the app's final reserved namespace
    /// is flipped in (alongside the bundle IDs). Pins that no premature production-namespace ID leaked into code.
    func testProProductIDIsPlaceholderNamespace() {
        XCTAssertEqual(ProGate.proProductID, "com.parla.pro.lifetime")
        XCTAssertTrue(ProGate.proProductID.hasPrefix("com.parla."), "product ID stays in the placeholder namespace pre-rebrand")
    }

    // MARK: Native decode routing (Phase 2c regression)

    /// The Opus lane must be chosen by CONTENT (Ogg magic "OggS"), not only by extension — Telegram voice
    /// messages are often saved with no extension, and routing them to the AVAssetReader lane (which can't demux
    /// Ogg) is exactly the "No audio decoder available" regression this fixes.
    func testOpusDecoderRoutesOggByContentNotJustExtension() throws {
        let tmp = FileManager.default.temporaryDirectory
        let oggNoExt = tmp.appendingPathComponent("voice_\(UUID().uuidString)")   // no extension, Ogg content
        try Data("OggS\u{01}\u{00}\u{00}\u{00}".utf8).write(to: oggNoExt)
        defer { try? FileManager.default.removeItem(at: oggNoExt) }
        XCTAssertTrue(OpusAudioDecoder.looksLikeOgg(oggNoExt), "an extension-less OggS file must route to the Opus lane")

        let byExt = tmp.appendingPathComponent("x.ogg")                            // extension wins even w/o content
        try Data("whatever".utf8).write(to: byExt)
        defer { try? FileManager.default.removeItem(at: byExt) }
        XCTAssertTrue(OpusAudioDecoder.looksLikeOgg(byExt))

        let notOgg = tmp.appendingPathComponent("clip_\(UUID().uuidString)")        // WAV-ish header, no ogg ext → Lane 2
        try Data("RIFF....WAVE".utf8).write(to: notOgg)
        defer { try? FileManager.default.removeItem(at: notOgg) }
        XCTAssertFalse(OpusAudioDecoder.looksLikeOgg(notOgg))

        XCTAssertFalse(OpusAudioDecoder.looksLikeOgg(tmp.appendingPathComponent("missing-\(UUID().uuidString)")))
    }

    /// Runtime proof that the libopusfile lane REALLY decodes an Ogg/Opus file — on every machine and in CI.
    /// This used to be opt-in behind `PARLA_OGG_FIXTURE`, which meant the native decoder (the whole point of
    /// Phase 2c — no ffmpeg) was automatically proven NOWHERE. `Fixtures/tone.ogg` is a 6.7 KB synthetic tone
    /// (no voice → fine in a public repo), so the real C decode path runs unconditionally.
    func testDecodesBundledOggFixture() throws {
        let f = try XCTUnwrap(Bundle.module.url(forResource: "tone", withExtension: "ogg", subdirectory: "Fixtures"),
                              "bundled Ogg fixture missing — check Package.swift resources")
        try assertOggDecodes(f, expectedSeconds: 3.0)
    }

    /// The intake rule from `0b779fc`: a Telegram voice note arrives with NO extension, so recognition must be by
    /// CONTENT. Same bytes, no extension → still sniffed as Ogg, still accepted by the one intake gate, still
    /// measurable by the cheap index probe (so it can't slip the free/Pro length gate).
    func testExtensionlessOggIsSniffedAndAcceptedByIntake() throws {
        let src = try XCTUnwrap(Bundle.module.url(forResource: "tone", withExtension: "ogg", subdirectory: "Fixtures"))
        let bare = FileManager.default.temporaryDirectory.appendingPathComponent("voice_\(UUID().uuidString)")
        try FileManager.default.copyItem(at: src, to: bare)
        defer { try? FileManager.default.removeItem(at: bare) }

        XCTAssertTrue(OpusAudioDecoder.looksLikeOgg(bare), "no extension → must be recognized by the OggS header")
        XCTAssertTrue(AppModel.isTranscribable(bare), "the intake gate must accept an extension-less Ogg voice note")
        try assertOggDecodes(bare, expectedSeconds: 3.0)
    }

    /// Optional extra: point PARLA_OGG_FIXTURE at a REAL voice note to run the same assertions on real bytes.
    /// (Real voice never lives in git; the bundled tone is what CI proves.)
    func testDecodeRealOggFixtureIfProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["PARLA_OGG_FIXTURE"] else {
            throw XCTSkip("PARLA_OGG_FIXTURE not set — the bundled fixture already covers the decode path")
        }
        let f = URL(fileURLWithPath: path)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: f.path), "fixture missing")
        try assertOggDecodes(f, expectedSeconds: nil)
    }

    /// Shared body: the cheap index-based duration probe (what the length gate uses) must agree with a real full
    /// decode, and the decode must produce a non-trivial 16 kHz WAV.
    private func assertOggDecodes(_ f: URL, expectedSeconds: Double?, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(OpusAudioDecoder.looksLikeOgg(f), "should be recognized as Ogg", file: file, line: line)
        let probe = try XCTUnwrap(OpusAudioDecoder.oggDurationSeconds(f),
                                  "opusfile op_pcm_total should measure the ogg WITHOUT decoding", file: file, line: line)
        let wav = try OpusAudioDecoder().decodeToWav16k(f)
        defer { try? FileManager.default.removeItem(at: wav) }
        let dur = AudioDuration.seconds(ofFileAt: wav.path) ?? 0
        XCTAssertGreaterThan(dur, 1, "opusfile should decode to a non-trivial WAV", file: file, line: line)
        XCTAssertEqual(probe, dur, accuracy: 0.2, "index-probe duration ≈ decoded duration", file: file, line: line)
        if let expected = expectedSeconds {
            XCTAssertEqual(dur, expected, accuracy: 0.2, "decoded duration should match the fixture", file: file, line: line)
        }
    }

    /// Tip-jar consumables are separate from Pro (a tip must never grant the entitlement) and stay in the
    /// placeholder namespace pre-rebrand.
    func testTipProductsSeparateFromPro() {
        XCTAssertEqual(ProGate.tipProductIDs.count, 3)
        XCTAssertFalse(ProGate.tipProductIDs.contains(ProGate.proProductID), "a tip must never be the Pro product")
        for id in ProGate.tipProductIDs {
            XCTAssertTrue(id.hasPrefix("com.parla.tip."), "tip IDs stay in the placeholder namespace")
        }
    }

    /// The export split: TXT/Markdown are free, SRT/VTT/JSON are Pro.
    func testProExportFormatSplit() {
        XCTAssertFalse(ProGate.isProExportFormat(.txt))
        XCTAssertFalse(ProGate.isProExportFormat(.markdown))
        XCTAssertTrue(ProGate.isProExportFormat(.srt))
        XCTAssertTrue(ProGate.isProExportFormat(.vtt))
        XCTAssertTrue(ProGate.isProExportFormat(.json))
    }

    /// exportIsGated: a free user is blocked (with a paywall) on the Pro formats only; a Pro user never is.
    @MainActor func testExportGateFreeVsPro() {
        let m = AppModel(engine: FakeEngine())
        m.isProUser = { false }
        XCTAssertFalse(m.exportIsGated(.txt));      XCTAssertNil(m.paywallReason)
        XCTAssertFalse(m.exportIsGated(.markdown)); XCTAssertNil(m.paywallReason)
        XCTAssertTrue(m.exportIsGated(.srt))
        guard case .featureLocked(.export)? = m.paywallReason else { return XCTFail("SRT should upsell for a free user") }
        m.paywallReason = nil
        XCTAssertTrue(m.exportIsGated(.vtt));  m.paywallReason = nil
        XCTAssertTrue(m.exportIsGated(.json)); m.paywallReason = nil
        // Pro user: nothing gated.
        m.isProUser = { true }
        for fmt in ExportFormat.allCases { XCTAssertFalse(m.exportIsGated(fmt)) }
        XCTAssertNil(m.paywallReason)
    }

    /// Batch (a multi-file drop) is Pro: a free user transcribes NONE of them and sees the upsell.
    @MainActor func testBatchGateBlocksMultiFileForFree() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "a", language: "en", segments: [], duration: 1),
                                            EngineResult(text: "b", language: "en", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }; m.soundOnComplete = false; m.history = []; m.autoCopy = false
            m.isProUser = { false }
            let a = makeTempSource("a.m4a"), b = makeTempSource("b.m4a")
            defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }

            await m.transcribe(urls: [a, b])

            XCTAssertTrue(m.history.isEmpty, "a free multi-file batch transcribes nothing")
            XCTAssertEqual(fake.transcribeCalls, 0)
            guard case .featureLocked(.batch)? = m.paywallReason else { return XCTFail("batch should upsell") }
        }
    }

    /// A single-file drop is never batch-gated (a free user still gets one-at-a-time transcription).
    @MainActor func testBatchGateAllowsSingleFileForFree() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "ok", language: "en", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }; m.soundOnComplete = false; m.history = []; m.autoCopy = false
            m.isProUser = { false }
            m.mediaDuration = { _ in 60 }   // short → not length-gated either
            let a = makeTempSource("a.m4a")
            defer { try? FileManager.default.removeItem(at: a) }

            await m.transcribe(urls: [a])

            XCTAssertEqual(m.history.count, 1)
            XCTAssertNil(m.paywallReason)
        }
    }

    /// A Pro user transcribes a whole batch (no gate).
    @MainActor func testBatchGateProProcessesAll() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "a", language: "en", segments: [], duration: 1),
                                            EngineResult(text: "b", language: "en", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }; m.soundOnComplete = false; m.history = []; m.autoCopy = false
            m.isProUser = { true }
            let a = makeTempSource("a.m4a"), b = makeTempSource("b.m4a")
            defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }

            await m.transcribe(urls: [a, b])

            XCTAssertEqual(m.history.count, 2)
            XCTAssertNil(m.paywallReason)
        }
    }

    /// Folder-watch is Pro: enabling it upsells a free user; turning it off / a Pro user is never gated.
    @MainActor func testFolderWatchEnableGate() {
        let m = AppModel(engine: FakeEngine())
        m.isProUser = { false }
        XCTAssertTrue(m.folderWatchEnableGated(true))
        guard case .featureLocked(.folderWatch)? = m.paywallReason else { return XCTFail("enabling watch should upsell") }
        m.paywallReason = nil
        XCTAssertFalse(m.folderWatchEnableGated(false))   // turning OFF is never gated
        XCTAssertNil(m.paywallReason)
        m.isProUser = { true }
        XCTAssertFalse(m.folderWatchEnableGated(true))    // Pro → not gated
        XCTAssertNil(m.paywallReason)
    }

    /// Generative AI power (model downloads, manual ✨ regenerate, per-chapter summaries) is Pro.
    @MainActor func testAiPowerGateFreeVsPro() {
        let m = AppModel(engine: FakeEngine())
        m.isProUser = { false }
        XCTAssertTrue(m.aiPowerIsGated())
        guard case .featureLocked(.aiPower)? = m.paywallReason else { return XCTFail("AI power should upsell") }
        m.paywallReason = nil
        m.isProUser = { true }
        XCTAssertFalse(m.aiPowerIsGated())
        XCTAssertNil(m.paywallReason)
    }

    /// Related is Pro but AUTO-computed on note open → a free user gets an EMPTY Related section, and it must NOT
    /// pop the paywall (that would fire on every note open).
    @MainActor func testRelatedClearedForFreeWithoutPaywall() {
        let m = AppModel(engine: FakeEngine())
        m.isProUser = { false }
        m.relatedIDs = [UUID(), UUID()]
        m.refreshRelatedNotes()
        XCTAssertTrue(m.relatedIDs.isEmpty, "a free user gets no Related")
        XCTAssertNil(m.paywallReason, "Related absence must NOT pop the paywall (it's auto-called on open)")
    }

    /// Folder-watch is Pro even after a refund: a persisted/running watcher's files are DROPPED for a non-Pro user
    /// at the drain (no transcribe, no paywall). Closes the review's launch-re-arm gate gap.
    @MainActor func testFolderWatchDrainDropsFilesForFreeUser() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "x", language: "en", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }; m.soundOnComplete = false; m.history = []
            m.isProUser = { false }
            // TWO files, not one. With a single-element queue this test passed identically with the Pro guard
            // deleted: removeFirst() and removeAll() both leave it empty and the count at 0, and transcribeCalls
            // is read before the un-awaited Task at the end of drainQueue can run — so nothing here could tell
            // the two branches apart. Two files make removeFirst() leave one behind, and `phase` (claimed
            // SYNCHRONOUSLY by the Pro branch) is the second discriminator.
            m.watchQueue = [URL(fileURLWithPath: "/tmp/parla-watched-1.m4a"),
                            URL(fileURLWithPath: "/tmp/parla-watched-2.m4a")]
            m.watchQueueCount = 2
            m.drainQueue()
            XCTAssertTrue(m.watchQueue.isEmpty, "a free user's watched files are ALL dropped, not transcribed")
            XCTAssertEqual(m.watchQueueCount, 0)
            XCTAssertEqual(m.phase, .idle, "the Pro branch claims the phase synchronously — a free user's never does")
            XCTAssertEqual(fake.transcribeCalls, 0)
        }
    }

    /// Download-tier semantic search is Pro (mirrors Related): a free user gets no semantic hits even if the embed
    /// model is still on disk (e.g. post-refund).
    @MainActor func testSemanticSearchClearedForFreeUser() async {
        let m = AppModel(engine: FakeEngine())
        m.isProUser = { false }
        m.semanticHitIDs = [UUID()]
        await m.refreshSemanticSearch()
        XCTAssertTrue(m.semanticHitIDs.isEmpty, "a free user gets no semantic search hits")
    }

    // MARK: Audio-cache prune protection — TOCTOU

    /// Pins the exact bug the review found: the displayed/playing entry is never evicted, and the
    /// re-check is a pure function applied after the off-main pass.
    func testApplyProtectionRemovesShownId() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(AudioStore.applyProtection([a, b, c], evicting: b), [a, c])       // shown id dropped
        XCTAssertEqual(AudioStore.applyProtection([a, b, c], evicting: nil), [a, b, c])  // nil → passthrough
        XCTAssertEqual(AudioStore.applyProtection([a, b], evicting: c), [a, b])          // not in plan → unchanged
        XCTAssertEqual(AudioStore.applyProtection([], evicting: a), [])                  // empty plan
        // Invariant: whatever the plan, the protected id is never in the result.
        XCTAssertFalse(AudioStore.applyProtection([a, b, c], evicting: b).contains(b))
    }

    // MARK: Transcribe orchestration with a fake engine

    @MainActor func testTranscribeSingleFileInsertsHistory() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "привет мир", language: "ru", segments: [], duration: 1.5)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }   // don't touch the notification center in tests
            m.soundOnComplete = false          // no completion beeps during tests
            m.history = []                     // ignore any legacy Murmur history migrated on the dev machine
            m.autoCopy = false
            // src is .m4a → AVFoundation path: the ffmpeg converter is intentionally NOT involved.
            // No stub on purpose — if a regression routed .m4a through ffmpeg, the real converter would
            // hit this fake 5-byte file and FAIL the test. The converter path is covered by testTranscribeUsesConverterForOpus.
            let src = makeTempSource()
            defer { try? FileManager.default.removeItem(at: src) }

            await m.transcribe(urls: [src])

            XCTAssertEqual(m.history.count, 1)
            XCTAssertEqual(m.history.first?.text, "привет мир")
            XCTAssertEqual(m.history.first?.language, "ru")
            XCTAssertEqual(m.selection, m.history.first?.id)
            if case .idle = m.phase {} else { XCTFail("phase should be .idle") }
            XCTAssertEqual(fake.ensureLoadedCalls, 1)
            XCTAssertEqual(fake.transcribeCalls, 1)
            XCTAssertNotNil(m.history.first?.audioFile)   // keepAudio copied the source AFTER the insert (perf-fix path)
        }
    }

    // MARK: Free-tier length gate (Phase 3)

    /// A non-Pro user dropping an over-cap file: it's skipped BEFORE any engine work (never decoded/transcribed),
    /// history stays empty, phase returns to .idle, and the paywall reason is set so the UI can upsell.
    @MainActor func testFreeLengthGateSkipsOverCapFileAndSetsPaywall() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "should not run", language: "ru", segments: [], duration: 600)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.isProUser = { false }                 // free tier
            m.mediaDuration = { _ in 600 }          // 10-minute file (over the 5-min cap)
            let src = makeTempSource()
            defer { try? FileManager.default.removeItem(at: src) }

            await m.transcribe(urls: [src])

            XCTAssertTrue(m.history.isEmpty, "over-cap file must not be transcribed for a free user")
            XCTAssertEqual(fake.transcribeCalls, 0, "no engine work should start for a gated file")
            XCTAssertEqual(fake.ensureLoadedCalls, 0)
            if case .idle = m.phase {} else { XCTFail("phase should be .idle after a pure-gate outcome") }
            guard case .lengthExceeded(let name, let dur)? = m.paywallReason else {
                return XCTFail("paywallReason should be .lengthExceeded")
            }
            XCTAssertEqual(name, src.lastPathComponent)
            XCTAssertEqual(dur, 600, accuracy: 0.001)
        }
    }

    /// A non-Pro user's file UNDER the cap transcribes normally — no gate, no paywall.
    @MainActor func testFreeUnderCapTranscribesNormally() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "ok", language: "ru", segments: [], duration: 60)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            m.isProUser = { false }
            m.mediaDuration = { _ in 60 }           // 1-minute file (under the cap)
            let src = makeTempSource()
            defer { try? FileManager.default.removeItem(at: src) }

            await m.transcribe(urls: [src])

            XCTAssertEqual(m.history.count, 1)
            XCTAssertEqual(fake.transcribeCalls, 1)
            XCTAssertNil(m.paywallReason)
        }
    }

    /// A Pro user is never length-gated — an over-cap file transcribes and the paywall never fires.
    @MainActor func testProUserBypassesLengthGate() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "long", language: "ru", segments: [], duration: 7200)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            m.isProUser = { true }                  // Pro (also the fail-open default)
            m.mediaDuration = { _ in 7200 }         // 2-hour file — never probed for Pro, never gated
            let src = makeTempSource()
            defer { try? FileManager.default.removeItem(at: src) }

            await m.transcribe(urls: [src])

            XCTAssertEqual(m.history.count, 1, "Pro transcribes any length")
            XCTAssertEqual(fake.transcribeCalls, 1)
            XCTAssertNil(m.paywallReason)
        }
    }

    /// Re-transcribe is a fresh transcription → the length gate must apply there too: a non-Pro user re-running
    /// an over-cap history note is blocked (old transcript untouched, no engine work) and the paywall shows.
    @MainActor func testRetranscribeGatedForFreeOverCapNote() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "NEW-should-not-apply", language: "en", segments: [], duration: 600)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.autoCopy = false
            m.isProUser = { false }
            let item = TranscriptItem(sourceName: "long.m4a", language: "en", durationSec: 600,
                                      model: "old-model", text: "OLD-keep-me", segments: [], sourcePath: "/tmp/parla-nope.m4a")
            m.history = [item]

            m.retranscribe(item, with: "new-model")
            await m.currentTranscriptionTask?.value   // nil when gated (no task spawned) → no-op

            XCTAssertEqual(m.history.first?.text, "OLD-keep-me")   // untouched
            XCTAssertEqual(m.history.first?.model, "old-model")    // not re-transcribed
            XCTAssertEqual(fake.transcribeCalls, 0)                // no engine work started
            guard case .lengthExceeded? = m.paywallReason else { return XCTFail("gated re-transcribe should show the paywall") }
        }
    }

    /// A Pro user re-transcribes an over-cap note normally (no gate).
    @MainActor func testRetranscribeProOverCapProceeds() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "NEW", language: "en", segments: [], duration: 600)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.autoCopy = false
            m.isProUser = { true }
            let src = makeTempSource("long.m4a")
            defer { try? FileManager.default.removeItem(at: src) }
            let item = TranscriptItem(sourceName: "long.m4a", language: "en", durationSec: 600,
                                      model: "old-model", text: "OLD", segments: [], sourcePath: src.path)
            m.history = [item]

            m.retranscribe(item, with: "new-model")
            await m.currentTranscriptionTask?.value

            XCTAssertEqual(m.history.first?.text, "NEW")           // replaced in place
            XCTAssertEqual(m.history.first?.model, "new-model")
            XCTAssertEqual(fake.transcribeCalls, 1)
            XCTAssertNil(m.paywallReason)
        }
    }

    /// PurchaseManager stays inert until `start()`: no entitlement, no product, no store contact — so a unit
    /// test can construct one without touching StoreKit. The DEBUG preview hook flips isPro for previews/tests.
    @MainActor func testPurchaseManagerInertUntilStart() {
        UserDefaults.standard.removeObject(forKey: "debugProState")   // ensure no dev override leaks in
        let pm = PurchaseManager()
        XCTAssertFalse(pm.isPro)
        XCTAssertNil(pm.proProduct)
        XCTAssertTrue(pm.tipProducts.isEmpty)
        XCTAssertFalse(pm.tipThanks)
        XCTAssertFalse(pm.entitlementsResolved)
        XCTAssertTrue(pm.grantsUnlimited, "gate fails open until entitlements resolve — never block a payer mid-launch")
        #if DEBUG
        pm.previewSetPro(true)
        XCTAssertTrue(pm.isPro)
        XCTAssertTrue(pm.grantsUnlimited)
        #endif
    }

    @MainActor func testTranscribeFailureRecordsAndLeavesHistory() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(throwOnTranscribe: true)
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }   // don't touch the notification center in tests
            m.soundOnComplete = false          // no completion beeps during tests
            m.history = []                     // ignore any legacy Murmur history migrated on the dev machine
            // src is .m4a → AVFoundation path: no converter involved (the engine throws before any audio work).
            let src = makeTempSource()
            defer { try? FileManager.default.removeItem(at: src) }

            await m.transcribe(urls: [src])

            XCTAssertTrue(m.history.isEmpty)               // a failed file never lands in history
            XCTAssertEqual(fake.transcribeCalls, 1)
            if case .failed = m.phase {} else { XCTFail("phase should be .failed") }
        }
    }

    @MainActor func testTranscribeBatchInsertsAllNewestFirst() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [
                EngineResult(text: "one",   language: "en", segments: [], duration: 1),
                EngineResult(text: "two",   language: "en", segments: [], duration: 1),
                EngineResult(text: "three", language: "en", segments: [], duration: 1),
            ])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }   // don't touch the notification center in tests
            m.soundOnComplete = false          // no completion beeps during tests
            m.history = []                     // ignore any legacy Murmur history migrated on the dev machine
            m.autoCopy = false
            // all .m4a → AVFoundation path: no converter involved (covered for ffmpeg by testTranscribeUsesConverterForOpus).
            let srcs = [makeTempSource("a.m4a"), makeTempSource("b.m4a"), makeTempSource("c.m4a")]
            defer { srcs.forEach { try? FileManager.default.removeItem(at: $0) } }

            await m.transcribe(urls: srcs)

            XCTAssertEqual(m.history.count, 3)
            XCTAssertEqual(fake.transcribeCalls, 3)
            XCTAssertEqual(m.history.first?.text, "three")   // insert(at:0) → last processed is newest
            if case .idle = m.phase {} else { XCTFail("phase should be .idle") }
        }
    }

    @MainActor func testTranscribeEmptyFolderFailsWithoutTouchingEngine() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine()
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }   // don't touch the notification center in tests
            m.soundOnComplete = false          // no completion beeps during tests
            m.history = []                     // ignore any legacy Murmur history migrated on the dev machine
            let emptyDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("empty-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: emptyDir) }

            await m.transcribe(urls: [emptyDir])

            XCTAssertTrue(m.history.isEmpty)
            XCTAssertEqual(fake.transcribeCalls, 0)          // no audio → engine never invoked
            if case .failed = m.phase {} else { XCTFail("phase should be .failed (no audio)") }
        }
    }

    @MainActor func testTranscribeMissingSourceStillSavesTranscript() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "text", language: "ru", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }   // don't touch the notification center in tests
            m.soundOnComplete = false          // no completion beeps during tests
            m.history = []                     // ignore any legacy Murmur history migrated on the dev machine
            m.autoCopy = false
            // ghost .m4a → AVFoundation path: the engine still runs (it doesn't read the file), keepAudio
            // gracefully no-ops on the missing source. No converter stub — none is reached.
            let ghost = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).m4a")

            await m.transcribe(urls: [ghost])

            XCTAssertEqual(m.history.count, 1)               // transcript is kept even if the source vanished
            XCTAssertEqual(m.history.first?.text, "text")
            XCTAssertNil(m.history.first?.audioFile)         // no source on disk → no player copy (graceful)
            XCTAssertNil(m.history.first?.audioPlayable)
        }
    }

    // MARK: Transcription queue (stack drops instead of dropping them)

    @MainActor func testDropWhileBusyQueuesInsteadOfRejecting() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine()
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.phase = .transcribing("busy")          // lane occupied → a drop must QUEUE, not run and not vanish
            let src = makeTempSource()
            defer { try? FileManager.default.removeItem(at: src) }

            m.handleDrop(urls: [src])
            XCTAssertEqual(m.transcriptionQueue.count, 1)   // queued (the old guard silently dropped it)
            XCTAssertEqual(fake.transcribeCalls, 0)         // and NOT started while the lane is busy

            m.handleDrop(urls: [src])
            XCTAssertEqual(m.transcriptionQueue.count, 2)   // a second drop stacks behind the first
            XCTAssertEqual(m.queuedCount, 2)                // watchQueue empty → total == manual
        }
    }

    @MainActor func testDrainManualQueueBailsWhileBusyDequeuesWhenFree() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "x", language: "en", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            let src = makeTempSource()
            defer { try? FileManager.default.removeItem(at: src) }
            m.transcriptionQueue = [TranscriptionJob(urls: [src])]

            m.phase = .transcribing("busy")
            m.drainManualQueue()                             // busy → must not dequeue or start
            XCTAssertEqual(m.transcriptionQueue.count, 1)
            XCTAssertEqual(fake.transcribeCalls, 0)

            m.phase = .idle
            m.drainManualQueue()                             // free → synchronous dequeue + phase claim (the Task runs async)
            XCTAssertEqual(m.transcriptionQueue.count, 0)
            if case .preparing = m.phase {} else { XCTFail("drain should claim the lane synchronously") }
        }
    }

    // MARK: Transcription cancel (stop + discard the in-flight result)

    @MainActor func testCancelTranscriptionClearsQueue() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine())
            m.history = []
            m.transcriptionQueue = [TranscriptionJob(urls: [makeTempSource()]),
                                    TranscriptionJob(urls: [makeTempSource()])]
            m.cancelTranscription()                          // no running task → just clears what's queued
            XCTAssertTrue(m.transcriptionQueue.isEmpty)
            XCTAssertFalse(m.cancelling)                     // nothing in flight → nothing to "stop"
        }
    }

    @MainActor func testCancelledRunDiscardsResultAndEndsIdle() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "should-not-save", language: "en", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            let src = makeTempSource()
            defer { try? FileManager.default.removeItem(at: src) }

            let task = Task { @MainActor in await m.transcribe(urls: [src]) }
            task.cancel()                                    // cancelled → the loop's Task.isCancelled guard trips
            await task.value

            XCTAssertTrue(m.history.isEmpty)                 // nothing partial saved
            XCTAssertEqual(fake.transcribeCalls, 0)          // never decoded (cancelled at the loop top)
            XCTAssertFalse(m.cancelling)
            if case .idle = m.phase {} else { XCTFail("a cancelled run ends idle") }
        }
    }

    @MainActor func testCancelMidBatchKeepsCompletedDiscardsInFlight() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [
                EngineResult(text: "file-A-kept", language: "en", segments: [], duration: 1),
                EngineResult(text: "file-B-discarded", language: "en", segments: [], duration: 1),
            ])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.autoCopy = false
            m.history = []
            let a = makeTempSource("a.m4a"), b = makeTempSource("b.m4a")
            defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }

            // Cancel DURING file B's decode → file A is already inserted (kept), B's decoded result is discarded.
            let box = TaskBox()
            fake.onTranscribe = { call in if call == 2 { box.task?.cancel() } }
            let task = Task { @MainActor in await m.transcribe(urls: [a, b]) }
            box.task = task
            await task.value

            XCTAssertEqual(m.history.count, 1)                    // file A completed → KEPT
            XCTAssertEqual(m.history.first?.text, "file-A-kept")
            XCTAssertEqual(fake.transcribeCalls, 2)               // file B decoded, but its result was DISCARDED (not saved)
            XCTAssertFalse(m.cancelling)                          // flag cleared on the cancelled exit
            if case .idle = m.phase {} else { XCTFail("a cancelled run ends idle") }
        }
    }

    @MainActor func testCancelRetranscribeKeepsOldTranscript() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "NEW-should-not-apply", language: "en", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.autoCopy = false
            let src = makeTempSource("orig.m4a")
            defer { try? FileManager.default.removeItem(at: src) }
            let item = TranscriptItem(sourceName: "orig.m4a", language: "en", durationSec: 1,
                                      model: "old-model", text: "OLD-keep-me", segments: [], sourcePath: src.path)
            m.history = [item]

            // Cancel DURING the re-transcribe decode → the in-place replace must be skipped (old transcript kept).
            let box = TaskBox()
            fake.onTranscribe = { _ in box.task?.cancel() }
            m.retranscribe(item, with: "new-model")
            let t = m.currentTranscriptionTask
            box.task = t
            await t?.value

            XCTAssertEqual(m.history.first?.text, "OLD-keep-me")   // untouched
            XCTAssertEqual(m.history.first?.model, "old-model")    // not replaced with the new model
            XCTAssertFalse(m.cancelling)
            if case .idle = m.phase {} else { XCTFail("a cancelled re-transcribe ends idle") }
        }
    }

    // MARK: Dictation orchestration

    @MainActor func testDictationInsertsHistoryRecord() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "надиктованный текст", language: "ru", segments: [], duration: 2)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            // 5-byte stub .wav → AudioDuration.seconds is nil → the short-clip guard is skipped and the
            // FakeEngine runs. The live mic capture itself is manual-only; this drives the result back-half.
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.finishDictation(wav: wav)

            XCTAssertEqual(m.history.count, 1)
            XCTAssertEqual(m.history.first?.text, "надиктованный текст")
            XCTAssertNil(m.history.first?.sourcePath)               // dictation → no re-transcribable source
            XCTAssertFalse(m.canRetranscribe(m.history.first!))     // → re-transcribe stays disabled
            XCTAssertEqual(fake.transcribeCalls, 1)
            if case .idle = m.phase {} else { XCTFail("phase should be .idle") }
        }
    }

    // MARK: Hybrid streaming save (refine the instant streamed text with a full decode)

    /// The streamed text is saved instantly, then the full decode REPLACES it in place and the refining
    /// badge clears.
    @MainActor func testRefineDictationReplacesStreamedWithFullDecode() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "полный точный декод", language: "ru", segments: [], duration: 3)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.refineDictation(wav: wav, streamed: "стрим текст", id: UUID())

            XCTAssertEqual(m.history.count, 1)
            XCTAssertEqual(m.history.first?.text, "полный точный декод")   // refined to the full decode
            XCTAssertTrue(m.refiningDictations.isEmpty)                    // badge cleared
            XCTAssertNil(m.history.first?.sourcePath)                      // dictation → no source
            XCTAssertEqual(fake.transcribeCalls, 1)
        }
    }

    /// An empty full decode must NOT blank the instant result — the streamed text is kept.
    @MainActor func testRefineDictationKeepsStreamedWhenDecodeEmpty() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "   ", language: "ru", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.refineDictation(wav: wav, streamed: "стрим текст", id: UUID())

            XCTAssertEqual(m.history.count, 1)
            XCTAssertEqual(m.history.first?.text, "стрим текст")   // instant result kept
            XCTAssertTrue(m.refiningDictations.isEmpty)
        }
    }

    /// A failed full decode keeps the instant streamed result (already saved/copied/pasted) — nothing lost.
    @MainActor func testRefineDictationKeepsStreamedWhenDecodeFails() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(throwOnTranscribe: true)
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.refineDictation(wav: wav, streamed: "стрим текст", id: UUID())

            XCTAssertEqual(m.history.count, 1)
            XCTAssertEqual(m.history.first?.text, "стрим текст")   // survives a failed refine
            XCTAssertTrue(m.refiningDictations.isEmpty)
        }
    }

    /// A refining dictation holds the single-flight lane (isBusy) so no concurrent job (folder-watch, drop, a
    /// new dictation) starts mid-refine and the edit pencil stays hidden — the fix for the lane/clobber HIGHs.
    @MainActor func testRefiningDictationHoldsBusyLane() {
        let m = AppModel(engine: FakeEngine())
        m.history = []
        XCTAssertFalse(m.isBusy)
        let id = UUID()
        m.refiningDictations.insert(id)
        XCTAssertTrue(m.isBusy)            // refine in flight → busy
        m.refiningDictations.remove(id)
        XCTAssertFalse(m.isBusy)           // released
    }

    /// A refine holds the busy lane but must NOT trigger the quit "work will be lost" prompt — its streamed
    /// transcript is already on disk; only the optional accuracy upgrade is in flight.
    @MainActor func testRefineDoesNotTriggerQuitConfirm() {
        let m = AppModel(engine: FakeEngine())
        m.history = []
        XCTAssertFalse(m.shouldConfirmQuit)
        m.refiningDictations.insert(UUID())
        XCTAssertTrue(m.isBusy)                  // still blocks concurrent jobs…
        XCTAssertFalse(m.shouldConfirmQuit)      // …but quitting is safe (text already saved)
        m.recordingStartedAt = Date()
        XCTAssertTrue(m.shouldConfirmQuit)       // an actual recording DOES warn
    }

    /// keepDictationAudio must attach the audio even when the full decode came back empty (the record exists
    /// with the streamed text either way).
    @MainActor func testRefineDictationKeepsAudioWhenDecodeEmpty() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "   ", language: "ru", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            m.keepDictationAudio = true
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.refineDictation(wav: wav, streamed: "стрим текст", id: UUID())

            XCTAssertEqual(m.history.first?.text, "стрим текст")   // streamed kept (empty decode)
            XCTAssertNotNil(m.history.first?.audioFile)            // audio kept anyway
        }
    }

    @MainActor func testDictationEmptyTextDropsRecord() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "   ", language: "ru", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.finishDictation(wav: wav)

            XCTAssertTrue(m.history.isEmpty)                        // blank dictation → no note inserted
            if case .idle = m.phase {} else { XCTFail("phase should be .idle") }
        }
    }

    @MainActor func testDictationBypassesWavConverter() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "ok", language: "ru", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            m.decoder = ClosureAudioDecoder(decode: { _ in throw AudioDecodingError.noDecoderAvailable })   // would fail if dictation used it
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.finishDictation(wav: wav)

            XCTAssertEqual(m.history.count, 1)                      // succeeded → the decoder was never called
            XCTAssertEqual(m.history.first?.text, "ok")
        }
    }

    @MainActor func testDictationSingleFlightGate() {
        let m = AppModel(engine: FakeEngine())
        m.history = []
        XCTAssertTrue(m.canDictate)            // idle → can start
        m.phase = .transcribing("x")
        XCTAssertFalse(m.canDictate)           // a job is running → blocked
        m.phase = .idle
        m.recordingStartedAt = Date()
        XCTAssertTrue(m.isRecordingDictation)
        XCTAssertTrue(m.isBusy)                // recording folds into isBusy (blocks drops/quick actions)
        XCTAssertFalse(m.canDictate)           // already recording → can't start another
    }

    /// While the mic-permission prompt is up, the lane is held (no drop/second-start races in) but the
    /// recording UI is NOT shown — capture (and its chip/timer/"Listening…") only begins after the grant.
    @MainActor func testRequestingMicHoldsLaneWithoutRecordingUI() {
        let m = AppModel(engine: FakeEngine())
        m.history = []
        XCTAssertTrue(m.canDictate)
        m.requestingMic = true
        XCTAssertTrue(m.isBusy)                  // permission check holds the lane…
        XCTAssertFalse(m.canDictate)             // …so nothing else can start
        XCTAssertFalse(m.isRecordingDictation)   // …but no "recording" UI yet (recordingStartedAt still nil)
        m.requestingMic = false
        XCTAssertFalse(m.isBusy)
    }

    @MainActor func testDictationFailureIsToastOnlyNotChip() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(throwOnTranscribe: true)
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.finishDictation(wav: wav)

            XCTAssertTrue(m.history.isEmpty)                 // failed dictation → nothing inserted
            // Toast-only: phase stays .idle (NOT .failed), so no stale "Try again" chip can replay an old drop.
            if case .idle = m.phase {} else { XCTFail("dictation failure should leave phase .idle, not .failed") }
        }
    }

    @MainActor func testDictationStopBeforeCaptureIsSilent() {
        let m = AppModel(engine: FakeEngine())
        m.history = []
        m.recordingStartedAt = Date()      // claimed, but the recorder isn't created yet (permission window)
        XCTAssertNil(m.recorder)
        m.stopAndTranscribeDictation()     // stop pressed pre-capture → silent cancel, no "empty" error
        XCTAssertNil(m.recordingStartedAt)
        XCTAssertFalse(m.isRecordingDictation)
        XCTAssertTrue(m.history.isEmpty)
        if case .idle = m.phase {} else { XCTFail("phase should stay .idle on a pre-capture cancel") }
    }

    @MainActor func testDictationPasteDisabledNeverPastes() async {
        await withTemporaryHistoryStoreAsync {
            var pasteCalls = 0
            var clipboard: String?
            let fake = FakeEngine(results: [EngineResult(text: "вставь меня", language: "ru", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = true
            m.dictationPasteIntoFrontmost = false
            m.attemptPaste = { pasteCalls += 1; return true }
            m.copyToClipboard = { clipboard = $0 }          // capture the seam (deterministic; no live system pasteboard)
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.finishDictation(wav: wav)

            XCTAssertEqual(pasteCalls, 0)                    // paste off → never synthesizes ⌘V
            XCTAssertEqual(m.history.first?.text, "вставь меня")
            XCTAssertEqual(clipboard, "вставь меня")         // text on the clipboard
        }
    }

    @MainActor func testDictationPasteEnabledAttemptsAndSetsClipboard() async {
        await withTemporaryHistoryStoreAsync {
            var pasteCalls = 0
            var clipboard: String?
            let fake = FakeEngine(results: [EngineResult(text: "наберись", language: "ru", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false                              // even with autoCopy off, paste must put text on the clipboard
            m.dictationPasteIntoFrontmost = true
            m.attemptPaste = { pasteCalls += 1; return true }   // simulate Accessibility-trusted + pasted
            m.copyToClipboard = { clipboard = $0 }          // capture the seam (deterministic; no live system pasteboard)
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.finishDictation(wav: wav)

            XCTAssertEqual(pasteCalls, 1)
            XCTAssertEqual(m.history.first?.text, "наберись")
            XCTAssertEqual(clipboard, "наберись")            // clipboard set for the ⌘V
        }
    }

    @MainActor func testDictationPasteUntrustedFallsBackToClipboard() async {
        await withTemporaryHistoryStoreAsync {
            var pasteCalls = 0
            var clipboard: String?
            let fake = FakeEngine(results: [EngineResult(text: "запас", language: "ru", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            m.dictationPasteIntoFrontmost = true
            m.attemptPaste = { pasteCalls += 1; return false }   // not Accessibility-trusted → no paste, graceful fallback
            m.copyToClipboard = { clipboard = $0 }          // capture the seam (deterministic; no live system pasteboard)
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.finishDictation(wav: wav)

            XCTAssertEqual(pasteCalls, 1)                    // attempted, returned false
            XCTAssertEqual(m.history.first?.text, "запас")   // record still saved
            XCTAssertEqual(clipboard, "запас")               // text remains on the clipboard
        }
    }

    func testDictationHotkeyRouting() {
        // Toggle mode: act on key-UP only.
        XCTAssertEqual(AppModel.dictationAction(for: .down, mode: .toggle), .ignore)
        XCTAssertEqual(AppModel.dictationAction(for: .up, mode: .toggle), .toggle)
        // Hold-to-talk: start on key-DOWN, stop on key-UP.
        XCTAssertEqual(AppModel.dictationAction(for: .down, mode: .hold), .start)
        XCTAssertEqual(AppModel.dictationAction(for: .up, mode: .hold), .stop)
    }

    func testDictationModeDefaultsToToggle() {
        XCTAssertEqual(DictationMode(rawValue: "") ?? .toggle, .toggle)
        XCTAssertEqual(DictationMode(rawValue: "hold"), .hold)
        XCTAssertEqual(DictationMode.allCases.count, 2)
    }

    // MARK: VAD silence detector

    func testSilenceDetectorArmsAfterSpeechThenStops() {
        var d = SilenceDetector(threshold: 0.01, silenceToStop: 1.0, minSpeechToArm: 0.5)
        XCTAssertFalse(d.feed(rms: 0.2, dt: 0.3))   // 0.3 s speech
        XCTAssertFalse(d.feed(rms: 0.2, dt: 0.3))   // 0.6 s speech → armed
        XCTAssertFalse(d.feed(rms: 0.0, dt: 0.5))   // 0.5 s silence
        XCTAssertTrue(d.feed(rms: 0.0, dt: 0.5))    // 1.0 s silence → stop
    }

    func testSilenceDetectorNeverStopsBeforeSpeech() {
        var d = SilenceDetector(threshold: 0.01, silenceToStop: 0.5, minSpeechToArm: 0.4)
        for _ in 0..<10 { XCTAssertFalse(d.feed(rms: 0.0, dt: 0.5)) }   // pure silence → never arms
    }

    func testSilenceDetectorResetsSilenceOnRenewedSpeech() {
        var d = SilenceDetector(threshold: 0.01, silenceToStop: 1.0, minSpeechToArm: 0.2)
        XCTAssertFalse(d.feed(rms: 0.5, dt: 0.3))   // armed
        XCTAssertFalse(d.feed(rms: 0.0, dt: 0.6))   // 0.6 s silence
        XCTAssertFalse(d.feed(rms: 0.5, dt: 0.1))   // speech resets the silence run
        XCTAssertFalse(d.feed(rms: 0.0, dt: 0.6))   // 0.6 s again (not 1.2)
        XCTAssertTrue(d.feed(rms: 0.0, dt: 0.5))    // 1.1 s ≥ 1.0 → stop
    }

    func testSilenceDetectorIgnoresNonPositiveDt() {
        var d = SilenceDetector(threshold: 0.01, silenceToStop: 0.1, minSpeechToArm: 0.0)
        XCTAssertFalse(d.feed(rms: 0.0, dt: 0))     // dt <= 0 → no-op
    }

    // MARK: AVFoundation-direct decode path (BUNDLE_FFMPEG P0)

    func testAvDecodableMirrorsDirectlyPlayable() {
        // v1 is the exact mirror of the prod-proven playback set — keep them in lock-step.
        XCTAssertEqual(AppModel.avDecodable, AudioStore.directlyPlayable)
    }

    func testAvDecodableIsSubsetOfAudioExts() {
        XCTAssertTrue(AppModel.avDecodable.isSubset(of: AppModel.audioExts))
    }

    func testAvDecodableExcludesDecoderOnlyFormats() {
        for ext in ["ogg", "oga", "opus", "3gp", "flac"] {
            XCTAssertFalse(AppModel.avDecodable.contains(ext), "\(ext) must route through the decoder")
        }
    }

    /// `AudioDuration` (the AVFoundation probe the engine + chunking gate use) must return
    /// nil for a path AVAudioFile can't open, so callers fall back instead of trusting a bogus length.
    func testAudioDurationNilForNonAudio() {
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("parla-not-audio-\(UUID().uuidString).bin")
        try? Data([0x00, 0x01, 0x02, 0x03, 0x04]).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        XCTAssertNil(AudioDuration.seconds(ofFileAt: junk.path))
        XCTAssertNil(AudioDuration.seconds(ofFileAt: "/no/such/file.wav"))
    }

    /// An AVFoundation format (.m4a) must NOT hit the decoder — the source path goes straight to the engine.
    @MainActor func testTranscribeSkipsConverterForAvFormat() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "ok", language: "en", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            // If the converter ran, the engine would receive THIS sentinel instead of the source path.
            m.decoder = ClosureAudioDecoder(decode: { _ in URL(fileURLWithPath: "/tmp/CONVERTER-RAN.wav") })
            let src = makeTempSource("voice.m4a")
            defer { try? FileManager.default.removeItem(at: src) }

            await m.transcribe(urls: [src])

            XCTAssertEqual(fake.transcribedPaths.first, src.path)                      // original handed straight to the engine
            XCTAssertFalse(fake.transcribedPaths.contains("/tmp/CONVERTER-RAN.wav"))   // the decoder never ran
        }
    }

    /// A non-AVFoundation format (.opus) must still go through the native decoder.
    @MainActor func testTranscribeUsesConverterForOpus() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "ok", language: "en", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            m.decoder = ClosureAudioDecoder(decode: { _ in URL(fileURLWithPath: "/tmp/fake.wav") })
            let src = makeTempSource("voice.opus")   // .opus ∉ avDecodable → must route through the decoder
            defer { try? FileManager.default.removeItem(at: src) }

            await m.transcribe(urls: [src])

            XCTAssertEqual(fake.transcribedPaths.first, "/tmp/fake.wav")   // engine got the converted WAV
        }
    }

    // MARK: TTS — voice synthesis P1a (seam + system voice)

    /// Pure voice-language filter: 2-letter-prefix match, empty → all, no-match → empty.
    func testVoiceSelectionFilter() {
        let voices = [
            VoiceDescriptor(id: "a", name: "Milena", language: "ru-RU", isSystem: true),
            VoiceDescriptor(id: "b", name: "Lesya",  language: "uk-UA", isSystem: true),
            VoiceDescriptor(id: "c", name: "Samantha", language: "en-US", isSystem: true),
            VoiceDescriptor(id: "d", name: "Daniel", language: "en-GB", isSystem: true),
        ]
        XCTAssertEqual(VoiceSelection.filter(voices, language: "ru").map(\.id), ["a"])          // ru → ru-RU
        XCTAssertEqual(VoiceSelection.filter(voices, language: "ru-RU").map(\.id), ["a"])       // full tag → prefix
        XCTAssertEqual(VoiceSelection.filter(voices, language: "en").map(\.id), ["c", "d"])     // both en variants
        XCTAssertEqual(VoiceSelection.filter(voices, language: "").count, 4)                    // empty → all
        XCTAssertTrue(VoiceSelection.filter(voices, language: "de").isEmpty)                    // no match → none
    }

    /// The system backend exposes real voices structurally (every returned voice matches the language + isSystem).
    /// EN always exists on macOS, so it's a safe non-empty probe without pinning a specific voice name.
    func testSystemTTSVoices() {
        let en = SystemTTSService().voices(forLanguage: "en")
        XCTAssertFalse(en.isEmpty, "macOS always ships EN system voices")
        XCTAssertTrue(en.allSatisfy { $0.language.lowercased().hasPrefix("en") && $0.isSystem })
        XCTAssertEqual(SystemTTSService().availability(forLanguage: "en"), .ready)
        // A bogus language has no system voice → unsupported (drives the availability gate).
        XCTAssertEqual(SystemTTSService().availability(forLanguage: "zz"), .unsupported)
    }

    /// The test double filters its canned voices + reports the configured availability (no real synthesis).
    func testNoopTTS() async {
        let noop = NoopTTSService(availabilityToReturn: .ready,
                                  cannedVoices: [VoiceDescriptor(id: "x", name: "X", language: "ru-RU", isSystem: false)])
        XCTAssertEqual(noop.voices(forLanguage: "ru").map(\.id), ["x"])
        XCTAssertTrue(noop.voices(forLanguage: "en").isEmpty)
        XCTAssertEqual(noop.availability(forLanguage: "ru"), .ready)
        do { _ = try await noop.synthesize("hi", voice: VoiceDescriptor(id: "x", name: "X", language: "ru-RU", isSystem: false)); XCTFail("noop must not synthesize") }
        catch {}
    }

    // MARK: Export formats — SRT / VTT / JSON / TXT / MD (EXPORT_FORMATS P1)

    func testSRTTimecode() {
        XCTAssertEqual(srtTimecode(0), "00:00:00,000")
        XCTAssertEqual(srtTimecode(3661.5), "01:01:01,500")
        XCTAssertEqual(srtTimecode(-5), "00:00:00,000")        // negatives clamp
        XCTAssertEqual(srtTimecode(1.2345), "00:00:01,235")    // rounds, not floors (1234.5 → 1235)
    }

    func testVTTTimecode() {
        XCTAssertEqual(vttTimecode(0), "00:00:00.000")
        XCTAssertEqual(vttTimecode(3661.5), "01:01:01.500")
    }

    func testSubtitleTimecodeHandlesNonFinite() {
        // NaN/±inf must NOT trap Int(_:) and kill the export — clamp to zero
        XCTAssertEqual(srtTimecode(.nan), "00:00:00,000")
        XCTAssertEqual(srtTimecode(.infinity), "00:00:00,000")
        XCTAssertEqual(vttTimecode(-.infinity), "00:00:00.000")
    }

    func testCollapseBlankLines() {
        XCTAssertEqual(collapseBlankLines("a\n\nb"), "a\nb")       // blank line → single break
        XCTAssertEqual(collapseBlankLines("a\n \nb"), "a\nb")      // whitespace-only line too
        XCTAssertEqual(collapseBlankLines("a\n\n\nb"), "a\nb")     // run of blanks
        XCTAssertEqual(collapseBlankLines("a\nb"), "a\nb")         // single break preserved
        XCTAssertEqual(collapseBlankLines("solo"), "solo")
    }

    func testExportEditedCueHasNoBlankLine() {
        // an edited transcript with a paragraph break must not break SRT/VTT cue framing
        let item = makeItem(text: "line one\n\nline two", segments: [], edited: true)
        XCTAssertEqual(exportSRT(item), "1\n00:00:00,000 --> 00:00:01,000\nline one\nline two\n\n")
        XCTAssertFalse(exportSRT(item).contains("line one\n\nline two"))
        XCTAssertTrue(exportVTT(item).contains("line one\nline two\n"))
    }

    func testExportSRT() {
        let item = makeItem(text: "full", segments: [
            Segment(start: 0, end: 2, text: "first"),
            Segment(start: 2, end: 4, text: "second"),
        ])
        XCTAssertEqual(exportSRT(item),
            "1\n00:00:00,000 --> 00:00:02,000\nfirst\n\n" +
            "2\n00:00:02,000 --> 00:00:04,000\nsecond\n\n")
    }

    func testExportSRTSkipsEmptySegments() {
        let item = makeItem(text: "full", segments: [
            Segment(start: 0, end: 1, text: "a"),
            Segment(start: 1, end: 2, text: ""),       // dropped
            Segment(start: 2, end: 3, text: "b"),
        ])
        let srt = exportSRT(item)
        XCTAssertTrue(srt.contains("1\n00:00:00,000 --> 00:00:01,000\na\n\n"))
        XCTAssertTrue(srt.contains("2\n00:00:02,000 --> 00:00:03,000\nb\n\n"))
        XCTAssertFalse(srt.contains("3\n"))            // indices stay contiguous 1,2 (not 1,3)
    }

    func testExportVTT() {
        let item = makeItem(text: "full", segments: [Segment(start: 0, end: 2, text: "hi")])
        let vtt = exportVTT(item)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(vtt.contains("00:00:00.000 --> 00:00:02.000\nhi\n"))
        XCTAssertFalse(vtt.contains("\n1\n"))          // no integer cue index in VTT
    }

    func testExportJSONRoundtrips() throws {
        let item = makeItem(text: "data", segments: [Segment(start: 0, end: 1, text: "x")], edited: true)
        let data = try exportJSON(item)
        let back = try JSONDecoder().decode(TranscriptItem.self, from: data)
        XCTAssertEqual(back, item)                      // real Codable round-trip (default date enc → exact)
        XCTAssertEqual(try exportJSON(item), data)      // deterministic bytes (sorted keys)
    }

    func testExportPlainTXTFlatVsTimestamped() {
        let item = makeItem(text: "привет мир", segments: [
            Segment(start: 0, end: 1, text: "привет"),
            Segment(start: 1, end: 2, text: "мир"),
        ])
        XCTAssertEqual(exportPlainTXT(item, timestamps: false), "привет мир")
        XCTAssertEqual(exportPlainTXT(item, timestamps: true), "[00:00] привет\n[00:01] мир")
    }

    func testExportMarkdownSingleItem() {
        let item = makeItem(name: "talk.ogg", text: "body", lang: "ru", model: "openai_whisper-large-v3")
        let md = exportMarkdown(item)
        XCTAssertTrue(md.hasPrefix("## talk.ogg\n"))
        XCTAssertTrue(md.contains("· RU · Large v3"))
        XCTAssertTrue(md.contains("\n\nbody\n"))
        XCTAssertFalse(md.contains("---"))             // no between-records separator for a single item
    }

    // MARK: insights in export (opt-in; SRT skipped, JSON already carries them)

    /// The insight header is fully Optional-gated: a note with NO insight fields contributes nothing, so an
    /// insight-less export stays byte-identical to pre-P4 (this is what keeps the existing byte-pin tests valid).
    func testInsightBlockEmptyWhenNoInsights() {
        let bare = makeItem(text: "body")   // no title/summary/keywords/actions
        XCTAssertEqual(insightBlock(bare, markdown: true), "")
        XCTAssertEqual(insightBlock(bare, markdown: false), "")
    }

    func testExportMarkdownIncludesInsights() {
        var it = makeItem(name: "talk.ogg", text: "body text", lang: "ru", model: "openai_whisper-large-v3")
        it.title = "Мой заголовок"; it.summary = "Краткая сводка"; it.keywords = ["один", "два"]
        it.actions = [ActionItem(text: "Позвонить"), ActionItem(text: "Готово", done: true)]
        let md = exportMarkdown(it, content: .withInsights)
        XCTAssertTrue(md.contains("Мой заголовок"))
        XCTAssertTrue(md.contains("> Краткая сводка"))     // markdown blockquote summary
        XCTAssertTrue(md.contains("один, два"))            // keywords joined
        XCTAssertTrue(md.contains("- [ ] Позвонить"))      // GFM checkbox (open)
        XCTAssertTrue(md.contains("- [x] Готово"))         // GFM checkbox (done)
        XCTAssertTrue(md.hasSuffix("body text\n"))         // body still last
        // Optional-gate: without the flag the output is the pre-P4 shape (no insight values).
        let off = exportMarkdown(it, content: .transcript)
        XCTAssertFalse(off.contains("Краткая сводка"))
        XCTAssertFalse(off.contains("- [ ]"))
        XCTAssertTrue(off.hasPrefix("## talk.ogg\n"))
        XCTAssertTrue(off.hasSuffix("\n\nbody text\n"))
    }

    func testExportPlainTXTIncludesInsights() {
        var it = makeItem(text: "body text", lang: "ru")
        it.title = "Заголовок"; it.summary = "Сводка"; it.actions = [ActionItem(text: "Готово", done: true)]
        let txt = exportPlainTXT(it, timestamps: false, content: .withInsights)
        XCTAssertTrue(txt.contains("Сводка"))
        XCTAssertTrue(txt.contains("- [x] Готово"))
        XCTAssertTrue(txt.hasSuffix("body text"))   // block precedes the body
        // Optional-gate: false → byte-identical to the plain transcript.
        XCTAssertEqual(exportPlainTXT(it, timestamps: false, content: .transcript), "body text")
    }

    func testExportVTTHasNoteBlock() {
        var v = makeItem(name: "talk.ogg", text: "full", segments: [Segment(start: 0, end: 2, text: "привет")], lang: "ru")
        v.title = "Тайтл"; v.summary = "Сводка"
        let vtt = exportVTT(v, content: .withInsights)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\nNOTE\n"))                      // spec-valid comment block
        XCTAssertTrue(vtt.contains("Сводка"))
        XCTAssertTrue(vtt.contains("00:00:00.000 --> 00:00:02.000\nпривет"))  // cues still parse after the NOTE
        // Optional-gate: false → byte-identical to the plain WebVTT (no NOTE).
        let off = exportVTT(v, content: .transcript)
        XCTAssertFalse(off.contains("NOTE"))
        XCTAssertTrue(off.hasPrefix("WEBVTT\n\n00:00:00.000"))
        XCTAssertEqual(off, exportVTT(v))   // default is false
    }

    func testExportSRTNeverCarriesInsights() {
        var s = makeItem(text: "full", segments: [Segment(start: 0, end: 1, text: "x")], lang: "ru")
        s.title = "Тайтл"; s.summary = "Сводкатекст"; s.actions = [ActionItem(text: "Задача")]
        // SubRip has no comment syntax → insights are deliberately never injected (a header would break players).
        XCTAssertEqual(exportString(s, as: .srt, content: .withInsights),
                       exportString(s, as: .srt, content: .transcript))
        XCTAssertFalse(exportString(s, as: .srt, content: .withInsights).contains("Сводкатекст"))
    }

    func testExportJSONCarriesInsights() throws {
        var j = makeItem(text: "data", segments: [Segment(start: 0, end: 1, text: "x")], lang: "ru")
        j.title = "Заголовок"; j.summary = "Сводка"; j.keywords = ["к1", "к2"]
        j.actions = [ActionItem(text: "Задача", done: true)]
        let back = try JSONDecoder().decode(TranscriptItem.self, from: exportJSON(j))
        XCTAssertEqual(back.title, "Заголовок")          // JSON = the full record → insights ride along
        XCTAssertEqual(back.summary, "Сводка")
        XCTAssertEqual(back.keywords, ["к1", "к2"])
        XCTAssertEqual(back.actions?.map(\.text), ["Задача"])
        XCTAssertEqual(back.actions?.first?.done, true)
        XCTAssertEqual(back, j)                           // full round-trip (no drift)
    }

    /// A long note with per-chapter summaries exports a chapter digest ABOVE the full transcript (chapters ADD,
    /// never replace). Gated by the content mode; absent for short / summary-less notes.
    func testExportLongNoteHasChapterDigest() {
        var it = makeItem(name: "talk.ogg", text: "полный текст записи", segments: [
            Segment(start: 0, end: 5, text: "первая"),
            Segment(start: 130, end: 135, text: "вторая"),
        ], lang: "ru")
        it.durationSec = 700
        it.chapterSummaries = [ChapterSummary(startSec: 0, endSec: 120, summary: "сум один"),
                               ChapterSummary(startSec: 120, endSec: 240, summary: "сум два")]
        let md = exportMarkdown(it, content: .withInsights)
        XCTAssertTrue(md.contains("### [00:00"))               // chapter heading (range label)
        XCTAssertTrue(md.contains("> сум один"))
        XCTAssertTrue(md.contains("> сум два"))
        XCTAssertTrue(md.contains("полный текст записи"))      // full transcript still present (ADD, not replace)
        XCTAssertFalse(exportMarkdown(it, content: .transcript).contains("### ["))   // gated by the flag
        // A note without chapter summaries → no chapter sections even with the flag.
        let bare = makeItem(text: "коротыш", lang: "ru")
        XCTAssertFalse(exportMarkdown(bare, content: .withInsights).contains("### ["))
    }

    /// "Summary only" export (P4 punch-list 7): emits the insight header (and chapter digest) WITHOUT the
    /// transcript body. ".withInsights" keeps both.
    func testExportInsightsOnlyDropsBody() {
        var it = makeItem(name: "talk.ogg", text: "полный текст записи здесь", lang: "ru")
        it.summary = "Сводка тут"; it.keywords = ["к1"]
        let md = exportMarkdown(it, content: .insightsOnly)
        XCTAssertTrue(md.contains("Сводка тут"))
        XCTAssertFalse(md.contains("полный текст записи здесь"))   // body dropped
        let txt = exportPlainTXT(it, timestamps: false, content: .insightsOnly)
        XCTAssertTrue(txt.contains("Сводка тут"))
        XCTAssertFalse(txt.contains("полный текст записи здесь"))
        XCTAssertTrue(exportMarkdown(it, content: .withInsights).contains("полный текст записи здесь"))   // both kept
    }

    func testExportFormatSupportsInsightsOnly() {
        XCTAssertTrue(ExportFormat.txt.supportsInsightsOnly)
        XCTAssertTrue(ExportFormat.markdown.supportsInsightsOnly)
        XCTAssertFalse(ExportFormat.srt.supportsInsightsOnly)     // subtitles need the body
        XCTAssertFalse(ExportFormat.vtt.supportsInsightsOnly)
        XCTAssertFalse(ExportFormat.json.supportsInsightsOnly)    // JSON = full record
    }

    /// Truncated summaries (token-cap cutoff) are trimmed back to the last complete sentence — never a dangling word.
    func testCompleteSentences() {
        XCTAssertEqual(completeSentences("Привет. Как дел"), "Привет.")              // drop the dangling fragment
        XCTAssertEqual(completeSentences("Готово."), "Готово.")                      // already clean → unchanged
        XCTAssertEqual(completeSentences("Раз. Два! Три? Четыре"), "Раз. Два! Три?") // trim to the last terminal
        XCTAssertEqual(completeSentences("Хвост…"), "Хвост…")                        // ellipsis is a clean end
        XCTAssertEqual(completeSentences("без точек вообще"), "без точек вообще")    // no boundary → leave as-is
        XCTAssertEqual(completeSentences("Он сказал «да»."), "Он сказал «да».")      // closer after terminal → clean
        XCTAssertEqual(completeSentences("  пробелы.  "), "пробелы.")                // trims surrounding whitespace
    }

    func testExportEditedRecordDegrades() {
        // text ≠ segments → one full-text cue [0, durationSec=1], never the stale segment timecodes
        let item = makeItem(text: "edited full text",
                            segments: [Segment(start: 0, end: 1, text: "stale"),
                                       Segment(start: 1, end: 2, text: "old")],
                            edited: true)
        XCTAssertEqual(exportSRT(item), "1\n00:00:00,000 --> 00:00:01,000\nedited full text\n\n")
        XCTAssertTrue(exportVTT(item).contains("00:00:00.000 --> 00:00:01.000\nedited full text\n"))
        XCTAssertFalse(exportSRT(item).contains("stale"))
    }

    func testExportEmptySegments() {
        // no segments, not edited → degrade to one full-text cue [0, duration]
        let item = makeItem(text: "только текст", segments: [])
        XCTAssertEqual(exportSRT(item), "1\n00:00:00,000 --> 00:00:01,000\nтолько текст\n\n")
        // truly empty (no text either) → empty SRT, valid-but-empty VTT — never 0-cue garbage
        let blank = makeItem(text: "", segments: [])
        XCTAssertEqual(exportSRT(blank), "")
        XCTAssertEqual(exportVTT(blank), "WEBVTT\n\n")
    }

    func testExportFormatMetadata() {
        XCTAssertEqual(ExportFormat.allCases.count, 5)
        let exts = ExportFormat.allCases.map(\.fileExtension)
        XCTAssertEqual(Set(exts).count, exts.count)    // unique extensions
        XCTAssertEqual(ExportFormat.srt.fileExtension, "srt")
        XCTAssertEqual(ExportFormat.markdown.fileExtension, "md")
        XCTAssertTrue(ExportFormat.json.supportsWholeHistory)
        XCTAssertFalse(ExportFormat.srt.supportsWholeHistory)
        XCTAssertFalse(ExportFormat.vtt.supportsWholeHistory)
        XCTAssertTrue(ExportFormat.allCases.allSatisfy { !$0.displayName.isEmpty })
    }

    func testSRTClampsEndBeforeStart() {
        let item = makeItem(text: "x", segments: [Segment(start: 5, end: 2, text: "reversed")])
        // end clamped to start → never a reversed `-->` range
        XCTAssertEqual(exportSRT(item), "1\n00:00:05,000 --> 00:00:05,000\nreversed\n\n")
    }

    // MARK: WhisperKit token cleanup (transcript display correctness)

    func testStripWhisperTokens() {
        XCTAssertEqual(stripWhisperTokens("<|startoftranscript|><|ru|><|transcribe|><|0.00|> привет мир<|8.52|>"), "привет мир")
        XCTAssertEqual(stripWhisperTokens("чисто без токенов"), "чисто без токенов")   // no-op on clean text
        XCTAssertEqual(stripWhisperTokens("<|endoftext|>"), "")                          // tokens-only → empty
        XCTAssertEqual(stripWhisperTokens("a<|1.0|>  b"), "a b")                         // collapses doubled spaces
        XCTAssertEqual(stripWhisperTokens("  <|x|> trim "), "trim")
    }

    func testSegmentCleanText() {
        XCTAssertEqual(Segment(start: 0, end: 1, text: "<|0.00|> привет<|8.52|>").cleanText, "привет")
        XCTAssertEqual(Segment(start: 0, end: 1, text: "чисто").cleanText, "чисто")
    }

    func testDisplayStripsWhisperTokens() {
        let item = makeItem(text: "привет мир", segments: [
            Segment(start: 0, end: 1, text: "<|0.00|> привет<|1.0|>"),
            Segment(start: 1, end: 2, text: "<|1.0|> мир<|2.0|>"),
        ])
        XCTAssertEqual(item.display(timestamps: true), "[00:00] привет\n[00:01] мир")
    }

    func testExportStripsWhisperTokens() {
        let item = makeItem(text: "full", segments: [
            Segment(start: 0, end: 2, text: "<|startoftranscript|><|0.00|> hello<|2.0|>"),
        ])
        XCTAssertEqual(exportSRT(item), "1\n00:00:00,000 --> 00:00:02,000\nhello\n\n")
        XCTAssertTrue(exportVTT(item).contains("hello"))
        XCTAssertFalse(exportVTT(item).contains("startoftranscript"))
    }

    // MARK: Long-audio chunking — planning + stitching + chapters (AudioChunker)

    func testChunkCount() {
        XCTAssertEqual(AudioChunker.chunkCount(durationSec: 0), 1)                        // empty → 1
        XCTAssertEqual(AudioChunker.chunkCount(durationSec: 120, chunkLength: 120), 1)    // exact 1
        XCTAssertEqual(AudioChunker.chunkCount(durationSec: 121, chunkLength: 120), 2)    // +1s → 2
        XCTAssertEqual(AudioChunker.chunkCount(durationSec: 240, chunkLength: 120), 2)    // exact 2
        XCTAssertEqual(AudioChunker.chunkCount(durationSec: 2400, chunkLength: 120), 20)  // 40 min → 20
    }

    func testIsLong() {
        XCTAssertFalse(AudioChunker.isLong(durationSec: 600))   // exactly 10 min is NOT long (strict >)
        XCTAssertTrue(AudioChunker.isLong(durationSec: 601))
        XCTAssertFalse(AudioChunker.isLong(durationSec: 0))
    }

    func testShouldChunkIsBatchIndependent() {
        XCTAssertTrue(AudioChunker.shouldChunk(durationSec: 700, chunkingAvailable: true))    // long + chunking → chunk (even in a batch)
        XCTAssertFalse(AudioChunker.shouldChunk(durationSec: 700, chunkingAvailable: false))  // no chunking → single-pass
        XCTAssertFalse(AudioChunker.shouldChunk(durationSec: 300, chunkingAvailable: true))   // short → single-pass
    }

    func testOffsetSegments() {
        let segs = [Segment(start: 0, end: 5, text: "a"), Segment(start: 5, end: 10, text: "b")]
        let offset = AudioChunker.offsetSegments(segs, chunkIndex: 2, chunkLength: 120)
        XCTAssertEqual(offset[0].start, 240)   // 2 * 120
        XCTAssertEqual(offset[0].end, 245)
        XCTAssertEqual(offset[1].start, 245)
        XCTAssertEqual(offset[0].text, "a")    // text unchanged
    }

    func testStitch() {
        let chunk0 = [Segment(start: 0, end: 60, text: "c0a"), Segment(start: 60, end: 119, text: "c0b")]
        let chunk1 = [Segment(start: 0, end: 60, text: "c1a")]
        let stitched = AudioChunker.stitch(chunkSegments: [chunk0, chunk1], chunkLength: 120)
        XCTAssertEqual(stitched.count, 3)
        XCTAssertEqual(stitched.map(\.text), ["c0a", "c0b", "c1a"])   // sorted by global start
        XCTAssertEqual(stitched[2].start, 120)                        // chunk1's local 0 → global 120
    }

    func testFailedChunkSegmentIsZeroWidthMarker() {
        let seg = AudioChunker.failedChunkSegment(label: "(chunk 3 failed)")
        XCTAssertEqual(seg.start, 0)
        XCTAssertEqual(seg.end, 0)                               // zero width → no fake 2-min span
        XCTAssertEqual(seg.text, "(chunk 3 failed)")
        // after stitching it lands at the chunk's start offset, still zero width
        let placed = AudioChunker.offsetSegments([seg], chunkIndex: 2, chunkLength: 120)[0]
        XCTAssertEqual(placed.start, 240)
        XCTAssertEqual(placed.end, 240)
    }

    func testResolveChunkedLanguage() {
        // first non-empty chunk language wins → Auto-detected language survives on long files
        XCTAssertEqual(AudioChunker.resolveLanguage(chunkLanguages: ["", "ru", "en"], requested: nil), "ru")
        // nothing detected (all chunks failed/silent) → fall back to the requested language
        XCTAssertEqual(AudioChunker.resolveLanguage(chunkLanguages: ["", ""], requested: "uk"), "uk")
        // nothing at all → empty (never crashes, mirrors single-pass default)
        XCTAssertEqual(AudioChunker.resolveLanguage(chunkLanguages: [], requested: nil), "")
    }

    func testChapters() {
        let segs = [
            Segment(start: 0, end: 60, text: "a"),
            Segment(start: 90, end: 119, text: "b"),     // same 0–120 window as "a"
            Segment(start: 130, end: 180, text: "c"),    // 120–240 window
        ]
        let chs = AudioChunker.chapters(from: segs, size: 120)
        XCTAssertEqual(chs.count, 2)
        XCTAssertEqual(chs[0].segments.map(\.text), ["a", "b"])
        XCTAssertEqual(chs[0].startSec, 0)
        XCTAssertEqual(chs[0].rangeLabel, "[00:00–02:00]")
        XCTAssertEqual(chs[1].segments.map(\.text), ["c"])
        XCTAssertEqual(chs[1].startSec, 120)
        XCTAssertEqual(chs[1].index, 1)
    }

    func testChaptersEmpty() {
        XCTAssertTrue(AudioChunker.chapters(from: [], size: 120).isEmpty)
    }

    // MARK: FolderWatcher teardown stress

    /// Exercises the passRetained/release teardown deterministically (no event-timing dependency):
    /// a UAF or over-release in start()/stop() would trap, so reaching the end is the assertion.
    @MainActor func testFolderWatcherStartStopStressNoCrash() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let w = FolderWatcher(folder: dir, recursive: true, debounce: 0.05) {}
        for _ in 0..<8 { w.start(); w.stop() }   // each start +1 (passRetained), each stop releases the stream → balanced
        w.start(); w.stop()
        w.stop()                                  // double stop is a safe no-op
        XCTAssertTrue(true)
    }

    @MainActor func testFolderWatcherPollingStartStopNoCrash() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let w = FolderWatcher(folder: dir, recursive: false, usePolling: true, debounce: 0.05) {}
        w.start()   // schedules the poll timer on main
        w.stop()    // invalidates it
        XCTAssertTrue(true)
    }

    // MARK: AudioStore round-trip

    func testAudioStorePlayableURLPrefersRendition() {
        withTemporaryHistoryStore {
            let id = UUID()
            let folder = AudioStore.folder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let orig = folder.appendingPathComponent("\(id).m4a")
            let rendition = folder.appendingPathComponent("\(id)-r.m4a")
            try? Data("o".utf8).write(to: orig)
            try? Data("r".utf8).write(to: rendition)
            var item = makeItem(text: "t")
            item.audioFile = orig.lastPathComponent
            item.audioPlayable = rendition.lastPathComponent

            // Prefers the m4a rendition (audioPlayable) when present…
            XCTAssertEqual(AudioStore.playableURL(for: item)?.lastPathComponent, rendition.lastPathComponent)
            // …and falls back to the original copy when the rendition is gone.
            try? FileManager.default.removeItem(at: rendition)
            XCTAssertEqual(AudioStore.playableURL(for: item)?.lastPathComponent, orig.lastPathComponent)
        }
    }

    func testAudioStorePruneOrphansRemovesUnreferenced() {
        withTemporaryHistoryStore {
            let folder = AudioStore.folder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let kept = UUID(), orphan = UUID()
            let keptFile = folder.appendingPathComponent("\(kept).m4a")
            let orphanFile = folder.appendingPathComponent("\(orphan).m4a")
            try? Data("k".utf8).write(to: keptFile)
            try? Data("o".utf8).write(to: orphanFile)
            var item = makeItem(text: "t")
            item.audioFile = keptFile.lastPathComponent

            AudioStore.pruneOrphans(keeping: [item])

            XCTAssertTrue(FileManager.default.fileExists(atPath: keptFile.path))     // referenced → kept
            XCTAssertFalse(FileManager.default.fileExists(atPath: orphanFile.path))  // unreferenced → removed
        }
    }

    // Full-review D6/S4 + D8: pruneImportedSource does a RECURSIVE removeItem, guarded ONLY by a prefix check that it
    // stays within Application Support/Parla/imports/. Pin BOTH branches — a weakened guard would delete a dir OUTSIDE
    // imports/ (a macOS original's parent, an AV-native drop). Not injectable, so this uses the real app-support
    // imports root under a unique UUID it creates + removes — it never touches real history/imports content.
    func testPruneImportedSourceOnlyDeletesUnderImports() throws {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let importsRoot = support.appendingPathComponent("Parla/imports", isDirectory: true)

        // (1) A Parla-managed import dir → the whole <uuid> dir is removed.
        let importDir = importsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: importDir, withIntermediateDirectories: true)
        let importFile = importDir.appendingPathComponent("voice.ogg")
        try Data("x".utf8).write(to: importFile)
        defer { try? fm.removeItem(at: importDir) }
        AppModel.pruneImportedSource(importFile.path)
        XCTAssertFalse(fm.fileExists(atPath: importDir.path), "a Parla-managed import dir is removed")

        // (2) SAFETY: a source OUTSIDE imports/ (macOS original / AV-native drop) → the dir is NEVER touched.
        let outside = fm.temporaryDirectory.appendingPathComponent("orig-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent("original.ogg")
        try Data("x".utf8).write(to: outsideFile)
        defer { try? fm.removeItem(at: outside) }
        AppModel.pruneImportedSource(outsideFile.path)
        XCTAssertTrue(fm.fileExists(atPath: outside.path), "a source outside imports/ is never deleted (guard holds)")
        XCTAssertTrue(fm.fileExists(atPath: outsideFile.path))

        // (3) nil path → no crash, no-op.
        AppModel.pruneImportedSource(nil)
    }

    // Full-review D6/S4 + D8: the launch orphan sweep removes only UNreferenced import dirs — a saved note's copy is
    // KEPT (re-transcribe/replay need it), an abandoned failed/cancelled/crashed copy is swept. Recursive delete → pin.
    func testPruneImportedOrphansRemovesOnlyUnreferenced() throws {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("Parla/imports", isDirectory: true)

        let keptDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let orphanDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: keptDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        let keptFile = keptDir.appendingPathComponent("voice.ogg")
        try Data("x".utf8).write(to: keptFile)
        try Data("x".utf8).write(to: orphanDir.appendingPathComponent("orphan.ogg"))
        defer { try? fm.removeItem(at: keptDir); try? fm.removeItem(at: orphanDir) }

        var item = makeItem(text: "t")
        item.sourcePath = keptFile.path

        // now = a week and a day past the dirs' mtime → both are past the grace period, so only the
        // reference-check decides. (The grace period itself is pinned by the two tests below.)
        AppModel.pruneImportedOrphans(keeping: [item], now: Date().addingTimeInterval(694_800))

        XCTAssertTrue(fm.fileExists(atPath: keptDir.path), "a saved note's import copy is kept")
        XCTAssertFalse(fm.fileExists(atPath: orphanDir.path), "an unreferenced import copy is swept")
    }

    /// THE data-loss guard. A drop stopped by a Pro gate (batch, or the free length cap) produces no note, so its
    /// import copy is "unreferenced" — while being the user's ONLY copy, because `ShareInbox.drain` has already
    /// cleared the share inbox. Two voice notes shared from Telegram by a free user were paywalled and then, on
    /// the next launch, deleted; buying Pro afterwards could not bring them back.
    func testPruneImportedOrphansKeepsARecentUnreferencedCopyPendingAnUpgradeOrRetry() throws {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("Parla/imports", isDirectory: true)
        let gatedDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: gatedDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: gatedDir.appendingPathComponent("voice.ogg"))
        defer { try? fm.removeItem(at: gatedDir) }

        AppModel.pruneImportedOrphans(keeping: [])   // just shared, just paywalled, nothing in history

        XCTAssertTrue(fm.fileExists(atPath: gatedDir.path),
                      "a copy imported moments ago is the user's only one — it must survive the launch sweep")
    }

    /// …but the grace period must expire, or a crash between copy and save leaks bytes forever.
    func testPruneImportedOrphansStillSweepsOnceTheGracePeriodHasPassed() throws {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("Parla/imports", isDirectory: true)
        let deadDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: deadDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: deadDir.appendingPathComponent("voice.ogg"))
        defer { try? fm.removeItem(at: deadDir) }

        AppModel.pruneImportedOrphans(keeping: [], now: Date().addingTimeInterval(694_800))   // 8 days on

        XCTAssertFalse(fm.fileExists(atPath: deadDir.path), "past the grace period an unreferenced copy is swept")
    }

    // MARK: A fresh transcript must be visible even when a search is active

    /// selectedItem is scoped to filteredHistory and falls back to its FIRST element, so transcribing while a
    /// query is active left the new note filtered out and the pane showing an unrelated older one. The deep-link
    /// and Related-navigation paths already clear the query first; the insert path did not. It also mattered
    /// beyond visibility: activeLanguageSuggestion gates on `selection`, not on what is displayed, so the
    /// nudge's «switch and re-transcribe» rendered above the wrong note and acted on the hidden one.
    @MainActor func testTranscribingWhileASearchIsActiveStillShowsTheNewNote() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "совершенно другой текст", language: "ru",
                                                         segments: [], duration: 1)])
            let m = AppModel(engine: fake, ai: NoopAIService(), embedder: FakeEmbedder())
            m.postNotification = { _, _ in }; m.soundOnComplete = false
            m.isProUser = { true }; m.mediaDuration = { _ in 1 }
            m.history = [self.makeItem(name: "old.m4a", text: "старая заметка про бухгалтерию", lang: "ru")]
            m.searchQuery = "бухгалтерию"          // the old note matches; the new one will not

            await m.transcribe(urls: [URL(fileURLWithPath: "/tmp/parla-new.m4a")])

            XCTAssertEqual(m.history.count, 2, "precondition: the transcript was saved")
            XCTAssertEqual(m.selectedItem?.id, m.history.first?.id,
                           "the pane shows the note that was just transcribed, not an older search hit")
            XCTAssertEqual(m.searchQuery, "", "the stale query is cleared, as on the deep-link path")
        }
    }

    // MARK: Privacy manifest — it must match the code that actually ships in the iOS bundle

    /// The manifest is a CLAIM about the binary, and Apple rejects the upload (ITMS-91053) when the claim is
    /// short. It said "no FileTimestamp" while ShareInbox already read .contentModificationDateKey, and the
    /// comment asserting the absence was wrong when it was written. Prose cannot be trusted to stay true, so
    /// this derives the answer from the sources the iOS target actually compiles.
    ///
    /// Scope note: the iOS app target is apps/ios/Sources + apps/ios/Shared + ParlaCore. Sources/Parla is the
    /// macOS app and is NOT in this bundle, so its own timestamp use does not belong here.
    func testPrivacyManifestDeclaresEveryRequiredReasonAPIThatShipsInTheIOSBundle() throws {
        let manifest = try String(contentsOf: repoRoot.appendingPathComponent("apps/ios/PrivacyInfo.xcprivacy"),
                                  encoding: .utf8)
        let fm = FileManager.default
        var code = ""
        for dir in ["apps/ios/Sources", "apps/ios/Shared", "Sources/ParlaCore"] {
            let root = repoRoot.appendingPathComponent(dir)
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "swift" {
                code += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
        XCTAssertFalse(code.isEmpty, "precondition: the iOS bundle's sources were found")

        // (marker in code, Apple's manifest category)
        let required: [(String, String)] = [
            ("contentModificationDateKey", "NSPrivacyAccessedAPICategoryFileTimestamp"),
            ("creationDateKey", "NSPrivacyAccessedAPICategoryFileTimestamp"),
            ("volumeAvailableCapacity", "NSPrivacyAccessedAPICategoryDiskSpace"),
            ("systemUptime", "NSPrivacyAccessedAPICategorySystemBootTime"),
            ("activeInputModes", "NSPrivacyAccessedAPICategoryActiveKeyboards"),
        ]
        for (marker, category) in required where code.contains(marker) {
            XCTAssertTrue(manifest.contains(category),
                          "\(marker) ships in the iOS bundle but the manifest does not declare \(category)")
        }
        // UserDefaults is used unconditionally and must always be declared.
        XCTAssertTrue(manifest.contains("NSPrivacyAccessedAPICategoryUserDefaults"))
        // And the promises the product is built on.
        XCTAssertTrue(manifest.contains("<key>NSPrivacyTracking</key>\n    <false/>"), "no tracking, ever")
    }

    // MARK: Hold-to-talk — a key-up during the mic prompt must not be swallowed

    /// First hold-to-talk use: startDictation suspends on the system mic-permission prompt, so
    /// `recordingStartedAt` — and therefore `isRecordingDictation` — is still nil. The user has to LET GO of the
    /// hotkey to click Allow, and that key-up hit `guard isRecordingDictation else { return }` and vanished. The
    /// suspended start then committed the recorder anyway: the mic went live with nothing held and recorded until
    /// the 120 s cap. A live microphone the user believes is off.
    @MainActor func testAStopDuringTheMicPromptIsRememberedNotDropped() {
        let m = AppModel(engine: FakeEngine(), ai: NoopAIService(), embedder: FakeEmbedder())
        m.requestingMic = true          // the prompt is up; startDictation is suspended on ensureMicAccess()
        XCTAssertFalse(m.isRecordingDictation, "precondition: capture has NOT begun yet")

        m.stopAndTranscribeDictation()  // the user releases the key to click Allow

        XCTAssertTrue(m.dictationStopRequested,
                      "the key-up must be recorded so the resuming start abandons instead of opening the mic")
    }

    /// …and it must stay a no-op when nothing is pending, or an idle stop would poison the NEXT dictation.
    @MainActor func testAStopWhenNothingIsPendingChangesNothing() {
        let m = AppModel(engine: FakeEngine(), ai: NoopAIService(), embedder: FakeEmbedder())
        m.stopAndTranscribeDictation()
        XCTAssertFalse(m.dictationStopRequested)
        XCTAssertFalse(m.requestingMic)
    }

    // MARK: Free-tier batch gate — the queue-depth half

    /// batchIsGated only ever inspected the size of ONE drop, and nothing inspected queue depth. A free user
    /// therefore got an unlimited unattended batch by dropping files one at a time — the exact feature the
    /// paywall sells («Queue many files at once»), advertised back at them by the "+N queued" badge.
    @MainActor func testAFreeUserCannotStackASecondJobBehindARunningOne() {
        let m = AppModel(engine: FakeEngine(), ai: NoopAIService(), embedder: FakeEmbedder())
        m.isProUser = { false }
        m.transcriptionQueue = [TranscriptionJob(urls: [URL(fileURLWithPath: "/tmp/a.m4a")])]   // one already waiting

        m.enqueueManual([URL(fileURLWithPath: "/tmp/b.m4a")])

        XCTAssertEqual(m.transcriptionQueue.count, 1, "the second job is refused, not queued")
        XCTAssertEqual(m.paywallReason, .featureLocked(.batch), "…and the user is told why")
    }

    @MainActor func testAProUserCanStackJobs() {
        let m = AppModel(engine: FakeEngine(), ai: NoopAIService(), embedder: FakeEmbedder())
        m.isProUser = { true }
        m.downloadingModel = "x"   // hold the lane shut so the enqueue is observable before it drains
        m.transcriptionQueue = [TranscriptionJob(urls: [URL(fileURLWithPath: "/tmp/a.m4a")])]

        m.enqueueManual([URL(fileURLWithPath: "/tmp/b.m4a")])

        XCTAssertEqual(m.transcriptionQueue.count, 2, "Pro queues freely")
        XCTAssertNil(m.paywallReason)
    }

    /// The gate keys on real transcription work, NOT on `isBusy`: `isBusy` is also true while the MODEL is
    /// downloading, and making a free user wait for the model is not the batch feature they would be upsold for.
    @MainActor func testAModelDownloadDoesNotCountAsAQueuedJob() {
        let m = AppModel(engine: FakeEngine(), ai: NoopAIService(), embedder: FakeEmbedder())
        m.isProUser = { false }
        m.downloadingModel = "whisper"   // busy, but nothing is transcribing

        m.enqueueManual([URL(fileURLWithPath: "/tmp/a.m4a")])

        XCTAssertEqual(m.transcriptionQueue.count, 1, "the drop is accepted and simply waits for the model")
        XCTAssertNil(m.paywallReason)
    }

    /// The FIRST drop must never be gated — free is "one file at a time", not "no files".
    @MainActor func testAFreeUsersFirstDropIsNotGated() {
        let m = AppModel(engine: FakeEngine(), ai: NoopAIService(), embedder: FakeEmbedder())
        m.isProUser = { false }
        m.enqueueManual([URL(fileURLWithPath: "/tmp/a.m4a")])
        XCTAssertNil(m.paywallReason, "an idle free user dropping one file is the free tier working as sold")
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

    // MARK: History resilience — one corrupt record must NOT wipe the archive (data-loss fix)

    private func validRecordJSON(text: String) -> String {
        #"{"id":"\#(UUID().uuidString)","date":1,"sourceName":"a.ogg","language":"ru","durationSec":1,"model":"m","text":"\#(text)","segments":[]}"#
    }
    private var corruptSiblings: [URL] {
        let dir = HistoryStore.fileURL.deletingLastPathComponent()
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("history.corrupt-") } ?? []
    }

    func testFailableDecodableDropsBadElement() {
        let json = "[\(validRecordJSON(text: "hi")),{\"language\":\"ru\"}]"   // one valid + one missing required keys
        let arr = try? JSONDecoder().decode([FailableDecodable<TranscriptItem>].self, from: Data(json.utf8))
        XCTAssertEqual(arr?.compactMap(\.value).count, 1)
    }

    func testLoadSkipsCorruptRecordKeepsValidOnes() {
        withTemporaryHistoryStore {
            let json = "[\(validRecordJSON(text: "hi")),{\"language\":\"ru\"}]"
            try? Data(json.utf8).write(to: HistoryStore.fileURL)
            let items = HistoryStore.load()
            XCTAssertEqual(items.count, 1)               // valid record survived
            XCTAssertEqual(items.first?.text, "hi")
            XCTAssertFalse(corruptSiblings.isEmpty)       // raw bytes quarantined for recovery
        }
    }

    func testLoadQuarantinesUnparseableFileAndReturnsEmpty() {
        withTemporaryHistoryStore {
            try? Data("this is not json at all".utf8).write(to: HistoryStore.fileURL)
            let items = HistoryStore.load()
            XCTAssertTrue(items.isEmpty)
            XCTAssertFalse(corruptSiblings.isEmpty)       // unparseable bytes preserved, not silently lost
        }
    }

    func testLoadEmptyArrayIsNotQuarantined() {
        withTemporaryHistoryStore {
            try? Data("[]".utf8).write(to: HistoryStore.fileURL)
            let items = HistoryStore.load()
            XCTAssertTrue(items.isEmpty)
            XCTAssertTrue(corruptSiblings.isEmpty)        // a legitimately-empty history is NOT corruption
        }
    }

    // MARK: Sidecar identity + migration completeness (C, D)

    func testSidecarMatchesBySourcePathNotName() {
        var a = makeItem(name: "voice.ogg", text: "AAA"); a.sourcePath = "/a/voice.ogg"
        var b = makeItem(name: "voice.ogg", text: "BBB"); b.sourcePath = "/b/voice.ogg"
        let history = [b, a]   // same filename, different folders; newest first (would mis-match by name)
        XCTAssertEqual(AppModel.sidecarTarget(in: history, for: URL(fileURLWithPath: "/b/voice.ogg"))?.text, "BBB")
        XCTAssertEqual(AppModel.sidecarTarget(in: history, for: URL(fileURLWithPath: "/a/voice.ogg"))?.text, "AAA")
        XCTAssertNil(AppModel.sidecarTarget(in: history, for: URL(fileURLWithPath: "/c/voice.ogg")))
    }

    func testSidecarURLKeepsAudioExtension() {
        // voice.ogg → voice.ogg.txt (not voice.txt): distinct per audio file, can't hit a user's voice.txt
        XCTAssertEqual(AppModel.sidecarURL(for: URL(fileURLWithPath: "/w/voice.ogg")).lastPathComponent, "voice.ogg.txt")
        // same basename, different audio extension → DISTINCT sidecars (no last-writer-wins collision)
        XCTAssertNotEqual(AppModel.sidecarURL(for: URL(fileURLWithPath: "/w/voice.ogg")),
                          AppModel.sidecarURL(for: URL(fileURLWithPath: "/w/voice.opus")))
    }

    func testSidecarPlanNeverClobbersExisting() {
        // target already exists (a user's own file) → skip, return nil (no overwrite)
        XCTAssertNil(AppModel.sidecarPlan(text: "transcript", targetExists: true))
        // no file there → write the transcript
        XCTAssertEqual(AppModel.sidecarPlan(text: "transcript", targetExists: false), Data("transcript".utf8))
    }

    func testStoreFileURLSeamsSwapAndRestore() {
        // The nonisolated(unsafe) test seams (Swift 6 flip) must still swap + restore verbatim —
        // withTemporaryHistoryStore and every orchestration test rely on this contract.
        let origHistory = HistoryStore.fileURL
        let origProcessed = ProcessedStore.fileURL
        let tmpH = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let tmpP = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        HistoryStore.fileURL = tmpH
        ProcessedStore.fileURL = tmpP
        XCTAssertEqual(HistoryStore.fileURL, tmpH)
        XCTAssertEqual(ProcessedStore.fileURL, tmpP)
        HistoryStore.fileURL = origHistory
        ProcessedStore.fileURL = origProcessed
        XCTAssertEqual(HistoryStore.fileURL, origHistory)
        XCTAssertEqual(ProcessedStore.fileURL, origProcessed)
    }

    func testMigrateClearsStaleStagingAndCopiesFresh() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mig-\(UUID().uuidString)")
        let legacy = root.appendingPathComponent("history.json")
        let target = root.appendingPathComponent("Parla/history.json")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("real".utf8).write(to: legacy)
        let stale = target.appendingPathExtension("migrating")
        try Data("garbage from a prior crash".utf8).write(to: stale)   // leftover partial copy
        defer { try? fm.removeItem(at: root) }

        HistoryStore.migrate(target: target, legacy: legacy)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "real")   // fresh copy, not the stale partial
        XCTAssertFalse(fm.fileExists(atPath: stale.path))                          // staging cleaned up after rename
    }

    func testMigrateDirCopiesWhenTargetMissingAndIsIdempotent() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mig-\(UUID().uuidString)")
        let legacy = root.appendingPathComponent("audio", isDirectory: true)
        let target = root.appendingPathComponent("Parla/audio", isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: legacy.appendingPathComponent("a.m4a"))
        defer { try? fm.removeItem(at: root) }

        HistoryStore.migrateDir(target: target, legacy: legacy)
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("a.m4a").path))   // dir copied
        HistoryStore.migrateDir(target: target, legacy: legacy)                              // re-run = no-op
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("a.m4a").path))
    }

    func testMigrateDirNoopWhenLegacyMissing() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mig-\(UUID().uuidString)")
        let target = root.appendingPathComponent("Parla/audio", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        HistoryStore.migrateDir(target: target, legacy: root.appendingPathComponent("nope", isDirectory: true))
        XCTAssertFalse(fm.fileExists(atPath: target.path))   // nothing to copy → no target created
    }

    // MARK: Quick-win defaults (timestamps ON, sound ON)

    @MainActor func testShowTimestampsDefaultsOnForFreshStore() {
        UserDefaults.standard.removeObject(forKey: AppModel.Keys.timestamps)
        XCTAssertTrue(AppModel().showTimestamps)   // reveal the click-to-seek SegmentList by default
    }

    @MainActor func testShowTimestampsRespectsExplicitFalse() {
        UserDefaults.standard.set(false, forKey: AppModel.Keys.timestamps)
        defer { UserDefaults.standard.removeObject(forKey: AppModel.Keys.timestamps) }
        XCTAssertFalse(AppModel().showTimestamps)   // an explicit OFF choice is preserved
    }

    @MainActor func testPinnedPlayerLayoutDefaultsOnAndPersists() {
        UserDefaults.standard.removeObject(forKey: AppModel.Keys.pinnedPlayer)
        XCTAssertTrue(AppModel().pinnedPlayerLayout)   // default ON — the pinned reading layout
        UserDefaults.standard.set(false, forKey: AppModel.Keys.pinnedPlayer)
        defer { UserDefaults.standard.removeObject(forKey: AppModel.Keys.pinnedPlayer) }
        XCTAssertFalse(AppModel().pinnedPlayerLayout)   // toggling OFF (rollback to classic) is preserved
    }

    func testShouldPlayCompletionSound() {
        // user-initiated run → always plays when enabled
        XCTAssertTrue(AppModel.shouldPlayCompletionSound(soundEnabled: true, isWatcherRun: false, watchQueueEmpty: false))
        XCTAssertFalse(AppModel.shouldPlayCompletionSound(soundEnabled: false, isWatcherRun: false, watchQueueEmpty: true))
        // watcher mid-burst (more queued) → silent; only the last of the burst beeps once
        XCTAssertFalse(AppModel.shouldPlayCompletionSound(soundEnabled: true, isWatcherRun: true, watchQueueEmpty: false))
        XCTAssertTrue(AppModel.shouldPlayCompletionSound(soundEnabled: true, isWatcherRun: true, watchQueueEmpty: true))
    }

    func testCompletionSoundIsHeadlessUnderTests() {
        XCTAssertTrue(CompletionSound.isHeadless)   // the sound can never beep during the test suite
    }

    @MainActor func testLastTranscriptText() {
        let m = AppModel(engine: FakeEngine())
        m.history = []
        XCTAssertEqual(m.lastTranscriptText, "")                          // empty history → "" (GetLastTranscript)
        m.history = [makeItem(text: "newest"), makeItem(text: "older")]
        XCTAssertEqual(m.lastTranscriptText, "newest")                    // history[0] is newest
    }

    // MARK: parla:// URL scheme (pure parser)

    func testParseParlaURL() {
        XCTAssertEqual(parseParlaURL(URL(string: "parla://transcribe?path=/a/v.ogg")!),
                       .transcribe(paths: ["/a/v.ogg"], dirs: []))
        XCTAssertEqual(parseParlaURL(URL(string: "parla://transcribe?path=/a/v.ogg&path=/b/w.mp3")!),
                       .transcribe(paths: ["/a/v.ogg", "/b/w.mp3"], dirs: []))   // repeatable path=
        XCTAssertEqual(parseParlaURL(URL(string: "parla://transcribe?dir=/Users/me/voices")!),
                       .transcribe(paths: [], dirs: ["/Users/me/voices"]))
        XCTAssertEqual(parseParlaURL(URL(string: "parla://transcribe?path=/a/my%20file.ogg")!),
                       .transcribe(paths: ["/a/my file.ogg"], dirs: []))         // percent-decoded
        XCTAssertEqual(parseParlaURL(URL(string: "parla://transcribe-last")!), .transcribeLast)
        XCTAssertEqual(parseParlaURL(URL(string: "parla://clipboard")!), .clipboard)
        XCTAssertEqual(parseParlaURL(URL(string: "parla://show")!), .show)
        XCTAssertEqual(parseParlaURL(URL(string: "parla://bogus")!), .unknown)   // unknown verb
        XCTAssertEqual(parseParlaURL(URL(string: "https://evil.com/x")!), .unknown)   // wrong scheme
        // iOS deep-link verbs: open a note by id, start dictation.
        let uuid = UUID()
        XCTAssertEqual(parseParlaURL(URL(string: "parla://note?id=\(uuid.uuidString)")!), .note(id: uuid))
        XCTAssertEqual(parseParlaURL(URL(string: "parla://note?id=not-a-uuid")!), .unknown)   // malformed id → unknown, no crash
        XCTAssertEqual(parseParlaURL(URL(string: "parla://note")!), .unknown)                 // missing id
        XCTAssertEqual(parseParlaURL(URL(string: "parla://dictate")!), .dictate)
    }

    func testParseViewTranscriptActivity() {
        let id = UUID()
        XCTAssertEqual(AppModel.parseViewTranscriptActivity(["id": id.uuidString]), id)   // Handoff
        XCTAssertNil(AppModel.parseViewTranscriptActivity(["id": "not-a-uuid"]))
        XCTAssertNil(AppModel.parseViewTranscriptActivity(["other": id.uuidString]))      // no id key
        XCTAssertNil(AppModel.parseViewTranscriptActivity(nil))
    }

    // MARK: First-run onboarding (pure decision logic)

    func testShouldShowOnboarding() {
        XCTAssertTrue(Onboarding.shouldShowOnboarding(didOnboard: false, hasHistory: false))   // fresh install
        XCTAssertFalse(Onboarding.shouldShowOnboarding(didOnboard: true, hasHistory: false))   // already onboarded
        XCTAssertFalse(Onboarding.shouldShowOnboarding(didOnboard: false, hasHistory: true))   // upgrader with history → skip
    }

    func testShouldShowFirstCompileHint() {
        XCTAssertTrue(Onboarding.shouldShowFirstCompileHint(isLoadingModel: true, didCompileModel: false))
        XCTAssertFalse(Onboarding.shouldShowFirstCompileHint(isLoadingModel: true, didCompileModel: true))   // compiled once already
        XCTAssertFalse(Onboarding.shouldShowFirstCompileHint(isLoadingModel: false, didCompileModel: false)) // not loading a model
    }

    func testRecommendedModelPrefersRecommendedTier() {
        let tiers = [
            ModelTier(title: "Tiny", hint: "", estimate: "", name: "openai_whisper-tiny", recommended: false),
            ModelTier(title: "Turbo", hint: "", estimate: "", name: "openai_whisper-large-v3-v20240930", recommended: true),
            ModelTier(title: "Large", hint: "", estimate: "", name: "openai_whisper-large-v3", recommended: false),
        ]
        XCTAssertEqual(Onboarding.recommendedModel(from: tiers), "openai_whisper-large-v3-v20240930")  // the recommended one wins
        XCTAssertEqual(Onboarding.recommendedModel(from: [tiers[0]]), "openai_whisper-tiny")           // none recommended → first
        XCTAssertNil(Onboarding.recommendedModel(from: []))                                            // empty → nil
    }

    @MainActor func testSoundOnCompleteDefaultsOn() {
        UserDefaults.standard.removeObject(forKey: AppModel.Keys.sound)
        XCTAssertTrue(AppModel().soundOnComplete)
    }

    // MARK: Error chip recovery (dismiss + retry)

    @MainActor func testDismissErrorClearsFailedPhase() {
        let m = AppModel()
        m.phase = .failed("boom")
        m.dismissError()
        if case .idle = m.phase {} else { XCTFail("dismissError should clear .failed → .idle") }
        m.phase = .preparing("y")
        m.dismissError()
        if case .preparing = m.phase {} else { XCTFail("dismissError must not touch a non-failed phase") }
    }

    @MainActor func testShouldConfirmQuitTracksInFlightWork() {
        let m = AppModel()
        XCTAssertFalse(m.shouldConfirmQuit)                 // idle → safe to quit, no prompt
        m.phase = .transcribing("x")
        XCTAssertTrue(m.shouldConfirmQuit)                  // job running → confirm before quitting
        m.phase = .idle
        m.downloadingModel = "openai_whisper-tiny"
        XCTAssertTrue(m.shouldConfirmQuit)                  // model download in flight → confirm
    }

    @MainActor func testCanRetryLastReflectsLastAttempt() {
        let m = AppModel()
        m.lastAttemptedURLs = []
        XCTAssertFalse(m.canRetryLast)                                   // nothing attempted yet
        m.lastAttemptedURLs = [URL(fileURLWithPath: "/tmp/x.ogg")]
        XCTAssertTrue(m.canRetryLast)                                    // idle + has an input → retryable
    }

    // MARK: Folder watching (feature 04)

    func testFolderScanIgnoresUnstable() {
        let a = stat("a.ogg", 100, 1000)
        let bPrev = stat("b.ogg", 100, 1000)
        let bNow  = stat("b.ogg", 200, 1000)   // size grew → file is still being written
        let (ready, next) = FolderScan.newStableFiles(
            current: [a, bNow],
            lastSeen: ["/watch/a.ogg": a, "/watch/b.ogg": bPrev],
            processed: [])
        XCTAssertEqual(ready.map { $0.url.lastPathComponent }, ["a.ogg"])   // only the stable a
        XCTAssertEqual(next["/watch/b.ogg"], bNow)                          // b deferred to the next pass
    }

    func testFolderScanFirstSightNotReady() {
        let a = stat("a.ogg", 100, 1000)
        let (ready, next) = FolderScan.newStableFiles(current: [a], lastSeen: [:], processed: [])
        XCTAssertTrue(ready.isEmpty)               // seen for the first time — not ready yet
        XCTAssertEqual(next["/watch/a.ogg"], a)    // but remembered
    }

    func testFolderScanSkipsProcessed() {
        let a = stat("a.ogg", 100, 1000)
        let (ready, _) = FolderScan.newStableFiles(current: [a], lastSeen: ["/watch/a.ogg": a], processed: [a.dedupKey])
        XCTAssertTrue(ready.isEmpty)   // dedupKey already processed → skip
    }

    func testFolderScanReadyIsSorted() {
        let c = stat("c.ogg", 1, 1), a = stat("a.ogg", 1, 1), b = stat("b.ogg", 1, 1)
        let lastSeen = ["/watch/c.ogg": c, "/watch/a.ogg": a, "/watch/b.ogg": b]
        let (ready, _) = FolderScan.newStableFiles(current: [c, a, b], lastSeen: lastSeen, processed: [])
        XCTAssertEqual(ready.map { $0.url.lastPathComponent }, ["a.ogg", "b.ogg", "c.ogg"])
    }

    func testDedupKeyChangesWithContent() {
        let base = stat("a.ogg", 100, 1000)
        XCTAssertEqual(base.dedupKey, stat("a.ogg", 100, 1000).dedupKey)       // same triple → same key
        XCTAssertNotEqual(base.dedupKey, stat("a.ogg", 200, 1000).dedupKey)    // different size
        XCTAssertNotEqual(base.dedupKey, stat("a.ogg", 100, 2000).dedupKey)    // different mtime
    }

    func testCapProcessedFIFO() {
        XCTAssertEqual(FolderScan.capProcessed(["1", "2", "3", "4"], max: 2), ["3", "4"])  // oldest discarded
        XCTAssertEqual(FolderScan.capProcessed(["1"], max: 2), ["1"])                      // under the limit — unchanged
        XCTAssertEqual(FolderScan.capProcessed(["1", "2"], max: 0), [])
    }

    func testProcessedStoreRoundtrip() {
        let original = ProcessedStore.fileURL
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ParlaPS-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ProcessedStore.fileURL = dir.appendingPathComponent("processed.json")
        defer { ProcessedStore.fileURL = original; try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(ProcessedStore.load(), [])                    // no file → empty, no crash
        ProcessedStore.save(["k1", "k2", "k3"])
        XCTAssertEqual(ProcessedStore.load(), ["k1", "k2", "k3"])   // order preserved (needed for FIFO)
    }

    func testScanFolderRecursiveVsFlat() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: tmp.appendingPathComponent("a.ogg"))
        try Data("x".utf8).write(to: tmp.appendingPathComponent("note.txt"))
        try Data("x".utf8).write(to: tmp.appendingPathComponent("sub/b.mp3"))

        let flat = AppModel.scanFolder(tmp, recursive: false).map { $0.url.lastPathComponent }
        XCTAssertEqual(flat, ["a.ogg"])                                                  // no subfolders, no note.txt
        let rec = Set(AppModel.scanFolder(tmp, recursive: true).map { $0.url.lastPathComponent })
        XCTAssertEqual(rec, ["a.ogg", "b.mp3"])
    }

    func testScanFolderCapturesSizeAndMtime() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1234).write(to: tmp.appendingPathComponent("a.ogg"))
        let stats = AppModel.scanFolder(tmp, recursive: false)
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats.first?.size, 1234)
        XCTAssertNotNil(stats.first?.mtime)
    }

    func testNewStableFilesEndToEnd() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 500).write(to: tmp.appendingPathComponent("a.ogg"))

        // first pass: file seen for the first time → not ready
        let pass1 = AppModel.scanFolder(tmp, recursive: false)
        let (ready1, seen1) = FolderScan.newStableFiles(current: pass1, lastSeen: [:], processed: [])
        XCTAssertTrue(ready1.isEmpty)
        // second pass with no changes → ready (two-pass stability guarantee, no FSEvents)
        let pass2 = AppModel.scanFolder(tmp, recursive: false)
        let (ready2, _) = FolderScan.newStableFiles(current: pass2, lastSeen: seen1, processed: [])
        XCTAssertEqual(ready2.map { $0.url.lastPathComponent }, ["a.ogg"])
    }

    // MARK: Re-transcribe (feature 01)

    /// Key backward compat: an old history.json without sourcePath/sourceBookmark decodes.
    func testCodableBackwardCompatSourceFields() throws {
        let legacy = #"[{"id":"\#(UUID().uuidString)","date":740000000,"sourceName":"a.ogg","language":"ru","durationSec":1,"model":"openai_whisper-tiny","text":"привет","segments":[]}]"#
        let items = try JSONDecoder().decode([TranscriptItem].self, from: Data(legacy.utf8))
        XCTAssertNil(items.first?.sourcePath)        // missing key → nil, NOT a throw
        XCTAssertNil(items.first?.sourceBookmark)
        XCTAssertFalse(items.first?.hasResolvableSource ?? true)
    }

    func testCodableRoundtripWithSource() throws {
        var item = makeItem(text: "txt")
        item.sourcePath = "/tmp/x.ogg"
        item.sourceBookmark = Data([1, 2, 3])
        let data = try JSONEncoder().encode([item])
        let back = try JSONDecoder().decode([TranscriptItem].self, from: data)
        XCTAssertEqual(back.first?.sourcePath, "/tmp/x.ogg")
        XCTAssertEqual(back.first?.sourceBookmark, Data([1, 2, 3]))
    }

    func testResolveSourceFoundByPath() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ogg")
        try Data("x".utf8).write(to: tmp)
        defer { try? fm.removeItem(at: tmp) }
        var item = makeItem(text: "t")
        item.sourcePath = tmp.path
        XCTAssertEqual(item.resolveSource(), .found(URL(fileURLWithPath: tmp.path), scoped: false))
        XCTAssertTrue(item.hasResolvableSource)
    }

    func testResolveSourceMissingWhenPathGone() {
        var item = makeItem(text: "t")
        item.sourcePath = "/nope/\(UUID().uuidString).ogg"
        XCTAssertEqual(item.resolveSource(), .missing)
        XCTAssertFalse(item.hasResolvableSource)
    }

    func testResolveSourceMissingWhenNilPath() {
        let item = makeItem(text: "t")   // sourcePath == nil (as in a legacy entry)
        XCTAssertEqual(item.resolveSource(), .missing)
        XCTAssertFalse(item.hasResolvableSource)
    }

    func testMakeAndResolveBookmarkFallback() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ogg")
        try Data("x".utf8).write(to: tmp)
        defer { try? fm.removeItem(at: tmp) }
        let bm = makeSourceBookmark(tmp)
        XCTAssertNotNil(bm)
        var item = makeItem(text: "t")
        item.sourcePath = nil            // path absent — should be found via bookmark
        item.sourceBookmark = bm
        if case .found(let url, _) = item.resolveSource() {
            XCTAssertTrue(fm.fileExists(atPath: url.path))
            XCTAssertEqual(url.lastPathComponent, tmp.lastPathComponent)
        } else {
            XCTFail("должен найтись по bookmark")
        }
    }

    @MainActor func testRetranscribeSameModelIsNoop() {
        withTemporaryHistoryStore {
            let m = AppModel()
            var item = makeItem(text: "оригинал", model: "openai_whisper-tiny")
            item.sourcePath = "/tmp/whatever.ogg"
            m.history = [item]
            m.retranscribe(item, with: "openai_whisper-tiny")   // same model → no-op, neither history nor phase
            XCTAssertEqual(m.history.first?.text, "оригинал")
            if case .idle = m.phase {} else { XCTFail("phase должна остаться .idle") }
        }
    }

    @MainActor func testRetranscribeClearsLastAttemptedSoChipWontReplayOldDrop() {
        withTemporaryHistoryStore {
            let m = AppModel(engine: FakeEngine())
            m.lastAttemptedURLs = [URL(fileURLWithPath: "/tmp/old-drop.ogg")]   // a prior manual drop
            XCTAssertTrue(m.canRetryLast)
            var item = makeItem(text: "orig", model: "openai_whisper-tiny")
            item.sourcePath = "/tmp/missing-\(UUID().uuidString).ogg"           // re-transcribe will fail to resolve
            m.history = [item]
            m.retranscribe(item, with: "openai_whisper-base")                   // different model → proceeds + clears
            XCTAssertTrue(m.lastAttemptedURLs.isEmpty)                          // chip's «Try again» can't replay the old drop
        }
    }

    @MainActor func testCanRetranscribe() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ogg")
        try Data("x".utf8).write(to: tmp)
        defer { try? fm.removeItem(at: tmp) }
        let m = AppModel()
        XCTAssertFalse(m.canRetranscribe(makeItem(text: "t")))   // no sourcePath → not allowed
        var present = makeItem(text: "t")
        present.sourcePath = tmp.path
        XCTAssertTrue(m.canRetranscribe(present))                // engine free + file present
    }

    // MARK: Audio player (feature 06)

    func testTranscriptItemDecodesWithoutAudioFile() throws {
        let legacy = #"[{"id":"\#(UUID().uuidString)","date":740000000,"sourceName":"a.ogg","language":"ru","durationSec":1,"model":"openai_whisper-tiny","text":"привет","segments":[]}]"#
        let items = try JSONDecoder().decode([TranscriptItem].self, from: Data(legacy.utf8))
        XCTAssertNil(items.first?.audioFile)        // no key → nil, NOT a throw
        XCTAssertNil(items.first?.audioPlayable)
        XCTAssertEqual(items.first?.text, "привет")
    }

    func testCodableRoundtripWithAudioFile() throws {
        var item = makeItem(text: "txt")
        item.audioFile = "X.ogg"
        item.audioPlayable = "X.m4a"
        let data = try JSONEncoder().encode([item])
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("audioFile") ?? false)
        let back = try JSONDecoder().decode([TranscriptItem].self, from: data)
        XCTAssertEqual(back.first?.audioFile, "X.ogg")
        XCTAssertEqual(back.first?.audioPlayable, "X.m4a")
    }

    func testAudioStoreFileName() {
        let id = UUID()
        XCTAssertEqual(AudioStore.fileName(for: id, sourceExtension: "OGG"), "\(id.uuidString).ogg")  // lowercased
        XCTAssertEqual(AudioStore.fileName(for: id, sourceExtension: "m4a"), "\(id.uuidString).m4a")
        XCTAssertEqual(AudioStore.fileName(for: id, sourceExtension: "MP3"), "\(id.uuidString).mp3")
        XCTAssertEqual(AudioStore.fileName(for: id, sourceExtension: ""),    "\(id.uuidString).bin")
    }

    func testAudioStoreCopyAndRemove() throws {
        withTemporaryHistoryStore {
            let fm = FileManager.default
            let src = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ogg")
            try? Data("audio".utf8).write(to: src)
            defer { try? fm.removeItem(at: src) }

            let id = UUID()
            let name = AudioStore.copy(from: src, id: id)
            XCTAssertNotNil(name)
            var item = makeItem(text: "t")
            item.audioFile = name
            XCTAssertNotNil(AudioStore.playableURL(for: item))   // copy in place
            AudioStore.remove(item)
            XCTAssertNil(AudioStore.playableURL(for: item))      // removed
        }
    }

    func testAudioStoreUrlMissingReturnsNil() {
        withTemporaryHistoryStore {
            var item = makeItem(text: "t")
            item.audioFile = "nope-\(UUID().uuidString).ogg"     // no such file
            XCTAssertNil(AudioStore.playableURL(for: item))
        }
    }

    func testActiveSegmentIndex() {
        let segs = [Segment(start: 0, end: 2, text: "a"),
                    Segment(start: 2, end: 5, text: "b"),
                    Segment(start: 10, end: 12, text: "c")]
        XCTAssertNil(activeSegmentIndex(segs, at: -1))          // before the first
        XCTAssertEqual(activeSegmentIndex(segs, at: 0), 0)
        XCTAssertEqual(activeSegmentIndex(segs, at: 1.9), 0)
        XCTAssertEqual(activeSegmentIndex(segs, at: 2), 1)      // exactly start → new segment
        XCTAssertEqual(activeSegmentIndex(segs, at: 6), 1)      // in a gap → stay on the last one that started
        XCTAssertEqual(activeSegmentIndex(segs, at: 11), 2)
        XCTAssertEqual(activeSegmentIndex(segs, at: 100), 2)    // past the end → last
        XCTAssertNil(activeSegmentIndex([], at: 1))             // no segments
    }

    // MARK: Quick transcribe — pasteboard + hotkey (feature 03)

    func testPasteboardParseFileScheme() {
        XCTAssertEqual(PasteboardReader.parse(strings: ["file:///Users/me/v.ogg"]).map(\.path),
                       ["/Users/me/v.ogg"])
    }
    func testPasteboardParsePosixPath() {
        XCTAssertEqual(PasteboardReader.parse(strings: ["/tmp/a.m4a"]).first?.lastPathComponent, "a.m4a")
    }
    func testPasteboardParseTrimsWhitespace() {
        XCTAssertEqual(PasteboardReader.parse(strings: ["  /tmp/b.wav \n"]).first?.lastPathComponent, "b.wav")
    }
    func testPasteboardParseRejectsNonPaths() {
        XCTAssertTrue(PasteboardReader.parse(strings: ["привет мир", "", "https://x.com/a.ogg"]).isEmpty)
    }
    func testPasteboardParseEmpty() {
        XCTAssertTrue(PasteboardReader.parse(strings: []).isEmpty)
    }

    func testAudioOnlyKeepsAudioDropsOther() {
        let urls = [URL(fileURLWithPath: "/t/a.ogg"), URL(fileURLWithPath: "/t/b.pdf"),
                    URL(fileURLWithPath: "/t/c.M4A"), URL(fileURLWithPath: "/t/d.txt")]
        XCTAssertEqual(PasteboardReader.audioOnly(urls).map { $0.lastPathComponent }, ["a.ogg", "c.M4A"])  // case-insensitive, audio only
    }
    func testAudioOnlyEmpty() {
        XCTAssertTrue(PasteboardReader.audioOnly([]).isEmpty)
    }

    // MARK: Audio cache auto-cleanup (LRU)

    func testEnforceAudioCapNoOpUnderCap() {
        let a = makeItem(text: "a"), b = makeItem(text: "b")
        let sizes = [a.id: Int64(100), b.id: Int64(100)]
        let evict = AudioStore.enforceAudioCap([b, a], capBytes: 1000, sizeOf: { sizes[$0.id] ?? 0 }, protected: [])
        XCTAssertTrue(evict.isEmpty)   // we fit → don't touch anything
    }

    func testEnforceAudioCapEvictsOldest() {
        let n = makeItem(text: "n"), m = makeItem(text: "m"), o = makeItem(text: "o")   // newest-first: [n, m, o]
        let sizes = [n.id: Int64(400), m.id: Int64(400), o.id: Int64(400)]               // 1200 > 1000
        let evict = AudioStore.enforceAudioCap([n, m, o], capBytes: 1000, sizeOf: { sizes[$0.id] ?? 0 }, protected: [])
        XCTAssertEqual(evict, [o.id])   // only the oldest, until it fits (1200-400=800 ≤ 1000)
    }

    func testEnforceAudioCapProtectsSelected() {
        let n = makeItem(text: "n"), m = makeItem(text: "m"), o = makeItem(text: "o")
        let sizes = [n.id: Int64(400), m.id: Int64(400), o.id: Int64(400)]
        let evict = AudioStore.enforceAudioCap([n, m, o], capBytes: 1000, sizeOf: { sizes[$0.id] ?? 0 }, protected: [o.id])
        XCTAssertEqual(evict, [m.id])   // o is protected (playing/selected) → evict the next oldest
    }

    func testEnforceAudioCapSkipsItemsWithoutAudio() {
        let n = makeItem(text: "n"), m = makeItem(text: "m"), o = makeItem(text: "o")
        let sizes = [n.id: Int64(600), o.id: Int64(600)]   // m has no audio (0 bytes)
        let evict = AudioStore.enforceAudioCap([n, m, o], capBytes: 1000, sizeOf: { sizes[$0.id] ?? 0 }, protected: [])
        XCTAssertEqual(evict, [o.id])   // 1200>1000 → evict o (600≤1000); m skipped (no audio)
    }

    func testEnforceAudioCapPartialWhenOnlyProtectedExceeds() {
        let big = makeItem(text: "big")
        let sizes = [big.id: Int64(2000)]   // a single entry exceeds the whole cap, but it's protected
        let evict = AudioStore.enforceAudioCap([big], capBytes: 1000, sizeOf: { sizes[$0.id] ?? 0 }, protected: [big.id])
        XCTAssertTrue(evict.isEmpty)   // don't yank audio out from under the player — partial compliance is OK
    }

    /// The one above is a ONE-item history, so it cannot tell correct behaviour apart from the bug: with nothing
    /// else present there is nothing to evict either way. Give the protected over-cap item some company and the
    /// real question appears — does an unreachable target make the loop strip everyone else?
    ///
    /// Live case: a Pro user imports a 1-hour video. `keepAudio` stores the full container AND a rendered .m4a,
    /// so one note can pass the 500 MB default cap on its own; `transcribe` has already selected it, so it is the
    /// protected one. The whole back catalogue must not lose its player audio because of that.
    func testEnforceAudioCapDoesNotStripEveryoneElseWhenTheProtectedItemAloneExceedsTheCap() {
        let big = makeItem(text: "big"), a = makeItem(text: "a"), b = makeItem(text: "b")
        let sizes = [big.id: Int64(2000), a.id: Int64(100), b.id: Int64(100)]   // big alone > cap
        let evict = AudioStore.enforceAudioCap([big, a, b], capBytes: 1000,
                                               sizeOf: { sizes[$0.id] ?? 0 }, protected: [big.id])
        XCTAssertTrue(evict.isEmpty,
                      "the cap is unreachable while big is protected — evicting a and b cannot help, it only destroys their playback audio")
    }

    /// The eviction must still do its job when the cap IS reachable without touching the protected item.
    func testEnforceAudioCapStillEvictsWhenTheCapIsReachableAroundTheProtectedItem() {
        let n = makeItem(text: "n"), m = makeItem(text: "m"), o = makeItem(text: "o")
        let sizes = [n.id: Int64(400), m.id: Int64(400), o.id: Int64(400)]   // 1200 > 1000, protected is only 400
        let evict = AudioStore.enforceAudioCap([n, m, o], capBytes: 1000,
                                               sizeOf: { sizes[$0.id] ?? 0 }, protected: [n.id])
        XCTAssertEqual(evict, [o.id], "dropping the oldest is enough to fit — do that, and stop")
    }

    // MARK: helpers

    private func stat(_ name: String, _ size: Int64, _ mtime: TimeInterval) -> WatchedFileStat {
        WatchedFileStat(url: URL(fileURLWithPath: "/watch/\(name)"), size: size,
                        mtime: Date(timeIntervalSince1970: mtime))
    }

    private func makeItem(name: String = "a.ogg", text: String, segments: [Segment] = [],
                          lang: String = "ru", model: String = "openai_whisper-tiny",
                          edited: Bool? = nil) -> TranscriptItem {
        var item = TranscriptItem(sourceName: name, language: lang, durationSec: 1, model: model,
                                  text: text, segments: segments)
        item.edited = edited
        return item
    }

    /// Run a block with a temporary history file — so that saveEdit/HistoryStore.save do NOT touch
    /// the user's real history in ~/Library/Application Support/Parla/.
    private func withTemporaryHistoryStore(_ body: () -> Void) {
        let original = HistoryStore.fileURL
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ParlaTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        HistoryStore.fileURL = dir.appendingPathComponent("history.json")
        defer {
            // Restores to the setUp baseline (itself a temp dir), so a detached Task that outlives this scope
            // can only ever touch temp data — the real store is unreachable for the whole test process. (No drain
            // needed: process-wide isolation in setUp is the real guard, not a timing race against a kicked Task.)
            HistoryStore.fileURL = original
            try? FileManager.default.removeItem(at: dir)
        }
        body()
    }

    /// Async sibling of withTemporaryHistoryStore — for `await transcribe(...)` orchestration tests.
    /// `@MainActor` so the @MainActor orchestration tests don't "send" the (non-Sendable) XCTestCase
    /// across isolation when they `await` it under Swift 6.
    @MainActor
    private func withTemporaryHistoryStoreAsync(_ body: @MainActor () async -> Void) async {
        let original = HistoryStore.fileURL
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ParlaTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        HistoryStore.fileURL = dir.appendingPathComponent("history.json")
        defer {
            // See sync variant: restores to the setUp temp baseline, so a detached refresh Task that outlives this
            // scope still can't reach the real store. Process-wide isolation in setUp is the guard, not a drain.
            HistoryStore.fileURL = original
            try? FileManager.default.removeItem(at: dir)
        }
        await body()
    }

    /// A real, directly-playable (.m4a) temp source so keepAudio's copy succeeds without ffmpeg.
    private func makeTempSource(_ name: String = "v.m4a") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try? Data("audio".utf8).write(to: url)
        return url
    }
}

// MARK: - Test double for the transcription backend


// MARK: - Memory pressure

extension ParlaLogicTests {

    /// `WhisperKit.unloadModels()` existed from day one and was called NOWHERE — the model stayed resident for
    /// the life of the process. The policy is now: give the weights back when the SYSTEM asks, never mid-job.
    @MainActor
    func testReleaseIdleMemoryUnloadsTheEngineWhenNothingIsRunning() async {
        let engine = FakeEngine()
        let m = AppModel(engine: engine, ai: FakeAIService(availabilityToReturn: .modelUnavailable))
        XCTAssertFalse(m.isBusy, "precondition: idle")

        await m.releaseIdleMemory()
        XCTAssertEqual(engine.unloadCalls, 1, "an idle app must hand the model's memory back under pressure")
    }

    /// The half that protects the user: unloading mid-job would abort or badly stall a running transcription.
    @MainActor
    func testReleaseIdleMemoryLeavesTheEngineAloneWhileBusy() async {
        let engine = FakeEngine()
        let m = AppModel(engine: engine, ai: FakeAIService(availabilityToReturn: .modelUnavailable))
        m.recordingStartedAt = Date()          // dictation in flight → isBusy
        XCTAssertTrue(m.isBusy, "precondition: busy")

        await m.releaseIdleMemory()
        XCTAssertEqual(engine.unloadCalls, 0, "never yank the model out from under a running job")

        m.recordingStartedAt = nil
        await m.releaseIdleMemory()
        XCTAssertEqual(engine.unloadCalls, 1, "…and release it once the job is done")
    }
}

/// Fake `TranscribingEngine`: returns canned results (or throws), counting calls. Single-flight in
/// tests (each engine call is awaited in turn), so the unchecked Sendable is safe.
/// Test helper: a Sendable box so a Task can be handed its own handle (for a self-cancelling test).
private final class TaskBox: @unchecked Sendable { var task: Task<Void, Never>? }

private final class FakeEngine: TranscribingEngine, @unchecked Sendable {
    private let results: [EngineResult]
    private let throwOnTranscribe: Bool
    private var idx = 0
    private(set) var ensureLoadedCalls = 0
    private(set) var transcribeCalls = 0
    private(set) var transcribedPaths: [String] = []   // the decode path handed to each transcribe call
    private(set) var transcribedSampleCounts: [Int] = []   // buffer sizes handed to the streaming seam
    private(set) var deletedModels: [String] = []
    private(set) var unloadCalls = 0
    var onTranscribe: (@Sendable (Int) -> Void)? = nil   // test hook: fired with the 1-based transcribe-call count (mid-decode)

    func unload() async { unloadCalls += 1 }

    init(results: [EngineResult] = [], throwOnTranscribe: Bool = false) {
        self.results = results
        self.throwOnTranscribe = throwOnTranscribe
    }

    func ensureLoaded(model: String, progress: @Sendable @escaping (ModelLoad) -> Void) async throws {
        ensureLoadedCalls += 1
    }

    func transcribe(wavPath: String, language: String?, model: String, translate: Bool) async throws -> EngineResult {
        transcribeCalls += 1
        transcribedPaths.append(wavPath)
        onTranscribe?(transcribeCalls)   // let a test cancel the enclosing task mid-decode
        if throwOnTranscribe { throw EngineError.notLoaded }
        let r = results.isEmpty ? EngineResult(text: "", language: "", segments: [], duration: 0)
                                : results[min(idx, results.count - 1)]
        idx += 1
        return r
    }

    func transcribe(samples: [Float], language: String?, model: String) async throws -> EngineResult {
        transcribeCalls += 1
        transcribedSampleCounts.append(samples.count)
        if throwOnTranscribe { throw EngineError.notLoaded }
        // Streaming windows pop the SAME canned queue as the file path, so a P3c orchestrator test can
        // hand each tick its own scripted EngineResult.
        let r = results.isEmpty ? EngineResult(text: "", language: "", segments: [], duration: 0)
                                : results[min(idx, results.count - 1)]
        idx += 1
        return r
    }

    func deleteModel(_ name: String) async throws { deletedModels.append(name) }
}

// MARK: - Test double for the AudioDecoding seam

/// Fake `AudioDecoding`: closures stand in for the ffmpeg subprocess so a test can script the decode
/// (return a sentinel path, or throw) without touching ffmpeg. Defaults are inert (passthrough / no chunking).
private struct ClosureAudioDecoder: AudioDecoding {
    var decode: @Sendable (URL) throws -> URL = { $0 }
    var split: @Sendable (URL, Double) throws -> [URL] = { _, _ in [] }
    var chunkingAvailable = false
    var render: @Sendable (URL, URL) throws -> Void = { _, _ in throw AudioDecodingError.noDecoderAvailable }
    func decodeToWav16k(_ src: URL) throws -> URL { try decode(src) }
    func splitIntoChunks(_ src: URL, chunkLength: Double) throws -> [URL] { try split(src, chunkLength) }
    var isChunkingAvailable: Bool { chunkingAvailable }
    func renderPlayableM4a(from src: URL, to dest: URL) throws { try render(src, dest) }
    func renderPlayableWav(from src: URL, to dest: URL) throws { try render(src, dest) }
}

// MARK: - Test double for the Local-AI seam

/// Fake `LocalLLMService`: reports a fixed availability and returns canned insights (or throws).
/// Value type → trivially Sendable, like the seam it stands in for.
private struct FakeAIService: LocalLLMService {
    var availabilityToReturn: AIAvailability = .ready
    var canned: AIInsights = AIInsights(title: "T", summary: "S", actions: [])
    var error: AIError? = nil   // when set, insights throws it — exercises the AI-failure-non-fatal invariant

    func availability(forLanguage language: String) -> AIAvailability { availabilityToReturn }
    func insights(forTranscript text: String, language: String) async throws -> AIInsights {
        if let error { throw error }
        return canned
    }
}

/// AI double that throws ONLY for inputs containing `failMarker` — to prove per-chapter best-effort
/// (one chapter fails, the others still get summaries). Always `.ready`.
private struct PerChapterAIService: LocalLLMService {
    let failMarker: String
    func availability(forLanguage language: String) -> AIAvailability { .ready }
    func insights(forTranscript text: String, language: String) async throws -> AIInsights {
        if text.contains(failMarker) { throw AIError.unavailable }
        return AIInsights(title: "T", summary: "ok", actions: [])
    }
}

/// AI double for the map→reduce test: the REDUCE input is the chapter summaries joined by NEWLINES (multi-line),
/// while each per-CHAPTER input is a single space-joined line → distinguish by the newline to return distinct results.
private struct ReduceAIService: LocalLLMService {
    func availability(forLanguage language: String) -> AIAvailability { .ready }
    func insights(forTranscript text: String, language: String) async throws -> AIInsights {
        text.contains("\n")
            ? AIInsights(title: "OverallТ", summary: "OVERALL", actions: [], keywords: ["ovk"])
            : AIInsights(title: "chT", summary: "chS", actions: [], keywords: [])
    }
}

/// AI double where the brief `insights` summary ("BRIEF") differs from the detailed `summarize` ("DETAILED…") —
/// proves the long-note summary path uses `summarize`, not the terse `insights`.
private struct DetailedSummaryAIService: LocalLLMService {
    func availability(forLanguage language: String) -> AIAvailability { .ready }
    func insights(forTranscript text: String, language: String) async throws -> AIInsights {
        AIInsights(title: "T", summary: "BRIEF", actions: [], keywords: ["k"])
    }
    func summarize(_ text: String, language: String) async throws -> String { "DETAILED whole-recording summary" }
}

/// Counts `summarize` calls — to prove the hierarchical reduce BATCHES + RECURSES on over-budget input (many calls)
/// vs a single pass when it fits. Single-flight in tests → unchecked Sendable is safe (same as FakeEngine).
private final class CountingSummaryAIService: LocalLLMService, @unchecked Sendable {
    private(set) var summarizeCalls = 0
    func availability(forLanguage language: String) -> AIAvailability { .ready }
    func insights(forTranscript text: String, language: String) async throws -> AIInsights {
        AIInsights(title: "T", summary: "S", actions: [])
    }
    func summarize(_ text: String, language: String) async throws -> String { summarizeCalls += 1; return "SUM" }
}

/// Fake `TextEmbedder`: returns a canned vector (or nil) and counts calls. Single-flight in tests
/// (each embed is awaited in turn), so the unchecked Sendable is safe — same pattern as FakeEngine.
private final class FakeEmbedder: TextEmbedder, @unchecked Sendable {
    private let vector: Embedding?
    private(set) var calls = 0
    init(vector: Embedding? = [1, 0, 0]) { self.vector = vector }
    func embed(_ text: String, language: String, kind: EmbedKind) async -> Embedding? { calls += 1; return vector }
    func tokenVectors(_ text: String, language: String) async -> [(range: Range<String.Index>, vector: Embedding)]? {
        guard let vector, !text.isEmpty else { return vector == nil ? nil : [] }
        return [(text.startIndex..<text.endIndex, vector)]   // one token spanning the whole string
    }
}

/// Embedder that (a) returns a text-dependent vector so a test can tell which text was embedded, and
/// (b) runs an injected hook DURING embed — to deterministically reproduce an edit landing mid-embed.
private final class HookEmbedder: TextEmbedder, @unchecked Sendable {
    var hook: (@MainActor @Sendable () -> Void)?
    private func vec(_ text: String) -> Embedding { text.contains("новый") ? [0, 1] : [1, 0] }
    func embed(_ text: String, language: String, kind: EmbedKind) async -> Embedding? {
        if let hook { await MainActor.run { hook() } }   // main actor is free (caller is awaiting us)
        return vec(text)
    }
    func tokenVectors(_ text: String, language: String) async -> [(range: Range<String.Index>, vector: Embedding)]? {
        text.isEmpty ? nil : [(text.startIndex..<text.endIndex, vec(text))]
    }
}
