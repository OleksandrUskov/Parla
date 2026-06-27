import XCTest
import os
import AVFoundation
import AppKit
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

    // MARK: Dictation (MIC_DICTATION P0)

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

    // MARK: Streaming engine seam (MIC_DICTATION P3a)

    /// The streaming seam decodes an in-memory Float buffer and threads results through the SAME mapping
    /// as the file path. The real WhisperKit decode is manual-only; this pins the seam's shape + that the
    /// orchestrator (P3c) gets a buffer-sized, canned-result double to drive.
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

    // MARK: Streaming reconciler (MIC_DICTATION P3c)

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

    func testLemmaSet() {
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
        for name in ["A.OGG", "b.M4A", "c.Opus", "d.flac", "e.webm", "f.mp4", "skip.txt"] {
            try Data("x".utf8).write(to: tmp.appendingPathComponent(name))
        }
        let found = Set(AppModel.audioFiles(in: tmp).map { $0.lastPathComponent })
        XCTAssertTrue(found.isSuperset(of: ["A.OGG", "b.M4A", "c.Opus", "d.flac", "e.webm", "f.mp4"]))
        XCTAssertFalse(found.contains("skip.txt"))
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

    // MARK: - Local-AI Layer P0 — Optional fields, displayTitle, seam gating

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
    /// reason Parla needs the embedding (P1) + MLX (P3) paths. Case/subtag-insensitive.
    func testFoundationModelsLanguageGate() {
        XCTAssertTrue(FoundationModelsService.maySupport(language: "en"))
        XCTAssertTrue(FoundationModelsService.maySupport(language: "EN-US"))
        XCTAssertFalse(FoundationModelsService.maySupport(language: "ru"))
        XCTAssertFalse(FoundationModelsService.maySupport(language: "uk"))
        XCTAssertFalse(FoundationModelsService.maySupport(language: "ru-RU"))
    }

    /// T7 (P0 slice): the generative LLM service NEVER serves ru/uk in P0 — true on every OS
    /// (FoundationModels can't; the MLX RU/UK backend lands in P3). RU/UK get value via SemanticIndex (P1).
    func testDefaultAIServiceNeverReadyForRussianUkrainian() {
        let ai = DefaultAIService()
        XCTAssertNotEqual(ai.availability(forLanguage: "ru"), .ready)
        XCTAssertNotEqual(ai.availability(forLanguage: "uk"), .ready)
        XCTAssertNotEqual(ai.availability(forLanguage: "ru-RU"), .ready)
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

    // MARK: - Local-AI Layer P1a — semantic core (cosine / topK / TextRank)

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

    // MARK: - Local-AI Layer P1c — EmbeddingStore + embedText + backfill

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
                m.history[i].aiModel = "extractive-v5"; m.history[i].title = "Авто"
                m.history[i].summary = "старое саммари"; m.history[i].keywords = ["старое"]
            }
            m.invalidateDerivedData(for: a.id)
            XCTAssertNil(m.embeddingIndex[a.id]); XCTAssertNil(m.lemmaIndex[a.id]); XCTAssertNil(EmbeddingStore.load()[a.id])
            XCTAssertNil(m.history.first?.aiModel)    // insights re-eligible
            XCTAssertNil(m.history.first?.title)      // auto-title cleared so it regenerates from new text
            XCTAssertNil(m.history.first?.summary)    // stale summary dropped (won't be overwritten if new text is short)
            XCTAssertNil(m.history.first?.keywords)   // stale keywords dropped
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

    @MainActor func testMorphologySearchMatchesInflections() {
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

    @MainActor func testMorphologySearchInflectedQuery() {
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

    @MainActor func testMorphologySearchIgnoresStoredLanguage() {
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

    func testSearchLemmaSetGatesLatinAndCorrectsIrregulars() {
        XCTAssertTrue(searchLemmaSet(of: "meeting running build").isEmpty)   // Latin → substring only (no flaky EN lemma)
        XCTAssertTrue(searchLemmaSet(of: "работе").contains("работа"))       // Cyrillic still lemmatized
        XCTAssertTrue(searchLemmaSet(of: "деньги").contains("деньга"))       // irregular override applied
        XCTAssertEqual(searchLemmaSet(of: "денег"), searchLemmaSet(of: "деньги"))   // both collapse to one lemma
        XCTAssertEqual(searchLemmaSet(of: "матери"), searchLemmaSet(of: "мать"))    // мать/матерь irregular unified
        XCTAssertEqual(searchLemmaSet(of: "дочери"), searchLemmaSet(of: "дочь"))    // дочь/дочерь irregular unified
    }

    @MainActor func testMorphologyMatchesDengiIrregular() {
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

    @MainActor func testEditInvalidatesSearchIndex() {
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

    // MARK: - Local-AI Layer P1d — extractive title/summary

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
            XCTAssertEqual(lt?.aiModel, "extractive-v5")
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

    // MARK: Audio-cache prune protection — TOCTOU (P0.2)

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

    // MARK: Transcribe orchestration with a fake engine (P0.1)

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

    // MARK: Dictation orchestration (MIC_DICTATION P1)

    @MainActor func testDictationInsertsHistoryRecord() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "надиктованный текст", language: "ru", segments: [], duration: 2)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            // 5-byte stub .wav → AudioConverter.duration is nil → the short-clip guard is skipped and the
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
            m.wavConverter = { _ in throw AudioConverter.Failure.ffmpegNotFound }   // would fail if dictation used it
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.finishDictation(wav: wav)

            XCTAssertEqual(m.history.count, 1)                      // succeeded → wavConverter was never called
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
            let fake = FakeEngine(results: [EngineResult(text: "вставь меня", language: "ru", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = true
            m.dictationPasteIntoFrontmost = false
            m.attemptPaste = { pasteCalls += 1; return true }
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.finishDictation(wav: wav)

            XCTAssertEqual(pasteCalls, 0)                    // paste off → never synthesizes ⌘V
            XCTAssertEqual(m.history.first?.text, "вставь меня")
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "вставь меня")   // text on the clipboard
        }
    }

    @MainActor func testDictationPasteEnabledAttemptsAndSetsClipboard() async {
        await withTemporaryHistoryStoreAsync {
            var pasteCalls = 0
            let fake = FakeEngine(results: [EngineResult(text: "наберись", language: "ru", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false                              // even with autoCopy off, paste must put text on the clipboard
            m.dictationPasteIntoFrontmost = true
            m.attemptPaste = { pasteCalls += 1; return true }   // simulate Accessibility-trusted + pasted
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.finishDictation(wav: wav)

            XCTAssertEqual(pasteCalls, 1)
            XCTAssertEqual(m.history.first?.text, "наберись")
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "наберись")   // clipboard set for the ⌘V
        }
    }

    @MainActor func testDictationPasteUntrustedFallsBackToClipboard() async {
        await withTemporaryHistoryStoreAsync {
            var pasteCalls = 0
            let fake = FakeEngine(results: [EngineResult(text: "запас", language: "ru", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            m.dictationPasteIntoFrontmost = true
            m.attemptPaste = { pasteCalls += 1; return false }   // not Accessibility-trusted → no paste, graceful fallback
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.finishDictation(wav: wav)

            XCTAssertEqual(pasteCalls, 1)                    // attempted, returned false
            XCTAssertEqual(m.history.first?.text, "запас")   // record still saved
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "запас")   // text remains on the clipboard
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

    // MARK: VAD silence detector (MIC_DICTATION P3 part 2)

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

    func testAvDecodableExcludesFfmpegOnlyFormats() {
        for ext in ["ogg", "oga", "opus", "amr", "webm", "3gp", "flac", "wma"] {
            XCTAssertFalse(AppModel.avDecodable.contains(ext), "\(ext) must route through ffmpeg")
        }
    }

    func testFfmpegArgsAreQuiet() {
        // The Tier-0 deadlock guard: without these flags ffmpeg floods stderr on a long file and hangs.
        for args in [AudioConverter.wavArgs(src: "/in", out: "/out"),
                     AudioConverter.m4aArgs(src: "/in", dest: "/out")] {
            XCTAssertTrue(args.contains("-hide_banner"))
            XCTAssertTrue(args.contains("-nostats"))
            guard let i = args.firstIndex(of: "-loglevel") else { return XCTFail("-loglevel missing") }
            XCTAssertEqual(args[i + 1], "error")
        }
    }

    /// An AVFoundation format (.m4a) must NOT spawn ffmpeg — the source path goes straight to the engine.
    @MainActor func testTranscribeSkipsConverterForAvFormat() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "ok", language: "en", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            // If the converter ran, the engine would receive THIS sentinel instead of the source path.
            m.wavConverter = { _ in URL(fileURLWithPath: "/tmp/CONVERTER-RAN.wav") }
            let src = makeTempSource("voice.m4a")
            defer { try? FileManager.default.removeItem(at: src) }

            await m.transcribe(urls: [src])

            XCTAssertEqual(fake.transcribedPaths.first, src.path)                      // original handed straight to the engine
            XCTAssertFalse(fake.transcribedPaths.contains("/tmp/CONVERTER-RAN.wav"))   // ffmpeg never ran
        }
    }

    /// A non-AVFoundation format (.opus) must still go through the ffmpeg converter.
    @MainActor func testTranscribeUsesConverterForOpus() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "ok", language: "en", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            m.wavConverter = { _ in URL(fileURLWithPath: "/tmp/fake.wav") }
            let src = makeTempSource("voice.opus")   // .opus ∉ avDecodable → must route through ffmpeg
            defer { try? FileManager.default.removeItem(at: src) }

            await m.transcribe(urls: [src])

            XCTAssertEqual(fake.transcribedPaths.first, "/tmp/fake.wav")   // engine got the converted WAV
        }
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
        XCTAssertTrue(AudioChunker.shouldChunk(durationSec: 700, ffmpegAvailable: true))    // long + ffmpeg → chunk (even in a batch)
        XCTAssertFalse(AudioChunker.shouldChunk(durationSec: 700, ffmpegAvailable: false))  // no ffmpeg → single-pass
        XCTAssertFalse(AudioChunker.shouldChunk(durationSec: 300, ffmpegAvailable: true))   // short → single-pass
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

    func testChunkArgsAreQuiet() {
        let args = AudioConverter.chunkArgs(src: "/in", segmentTime: 120, outPattern: "/out/chunk_%04d.wav")
        XCTAssertTrue(args.contains("-hide_banner"))       // Tier-0 deadlock guard
        XCTAssertTrue(args.contains("-nostats"))
        XCTAssertTrue(args.contains("segment"))            // segment muxer
        guard let i = args.firstIndex(of: "-segment_time") else { return XCTFail("-segment_time missing") }
        XCTAssertEqual(args[i + 1], "120")
    }

    func testFfmpegResolverPrefersBundled() {
        // bundled present + executable → wins over system (real executables that exist on macOS)
        XCTAssertEqual(AudioConverter.resolveFfmpeg(bundled: URL(fileURLWithPath: "/bin/sh"),
                                                    systemCandidates: ["/bin/echo"])?.path, "/bin/sh")
        // no bundled → first executable system candidate
        XCTAssertEqual(AudioConverter.resolveFfmpeg(bundled: nil,
                                                    systemCandidates: ["/nonexistent", "/bin/echo"])?.path, "/bin/echo")
        // bundled path not executable → falls through to system
        XCTAssertEqual(AudioConverter.resolveFfmpeg(bundled: URL(fileURLWithPath: "/nope"),
                                                    systemCandidates: ["/bin/echo"])?.path, "/bin/echo")
        // neither → nil
        XCTAssertNil(AudioConverter.resolveFfmpeg(bundled: URL(fileURLWithPath: "/nope"),
                                                  systemCandidates: ["/also/nope"]))
    }

    // MARK: FolderWatcher teardown stress (P1.1)

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

    // MARK: AudioStore round-trip (P1.2)

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

    // MARK: ffmpeg process drain — no deadlock on a stderr flood (long-file hang fix)

    /// A child that floods >64 KB to stderr then exits. The OLD "read stderr after waitUntilExit"
    /// pattern deadlocked here (pipe buffer fills → child blocks on write → waitUntilExit hangs).
    /// runCapturingStderr drains concurrently, so it must finish. Run on a thread with a timeout so
    /// a regression FAILS the test instead of hanging the suite forever.
    func testRunCapturingStderrDrainsFloodWithoutDeadlock() {
        let exp = expectation(description: "drain completes")
        let status = OSAllocatedUnfairLock<Int32>(initialState: -1)   // Sendable cross-thread handoff
        Thread.detachNewThread {
            let p = Process()                                          // created in-thread → not captured
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "i=0; while [ $i -lt 6000 ]; do echo 'xxxxxxxxxxxxxxxxxxxxxxxxxx' 1>&2; i=$((i+1)); done; exit 3"]
            let r = try? AudioConverter.runCapturingStderr(p)
            status.withLock { $0 = r?.status ?? -1 }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 15)
        XCTAssertEqual(status.withLock { $0 }, 3)   // completed (not deadlocked), exit code preserved
    }

    /// A wedged child (sleep 30) must be killed by the watchdog, not block readDataToEndOfFile forever.
    func testRunCapturingStderrWatchdogTerminatesHang() {
        let exp = expectation(description: "watchdog fires")
        let result = OSAllocatedUnfairLock<(status: Int32, elapsed: Double)>(initialState: (0, .greatestFiniteMagnitude))
        let start = Date()
        Thread.detachNewThread {
            let p = Process()                                          // created in-thread → not captured
            p.executableURL = URL(fileURLWithPath: "/bin/sleep")
            p.arguments = ["30"]
            let r = try? AudioConverter.runCapturingStderr(p, timeout: 0.4)
            result.withLock { $0 = (r?.status ?? 0, Date().timeIntervalSince(start)) }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
        let r = result.withLock { $0 }
        XCTAssertLessThan(r.elapsed, 5)        // killed ~0.4s, not 30s
        XCTAssertNotEqual(r.status, 0)         // terminated → non-zero
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

// MARK: - Test double for the transcription backend (P0.1 seam)

/// Fake `TranscribingEngine`: returns canned results (or throws), counting calls. Single-flight in
/// tests (each engine call is awaited in turn), so the unchecked Sendable is safe.
private final class FakeEngine: TranscribingEngine, @unchecked Sendable {
    private let results: [EngineResult]
    private let throwOnTranscribe: Bool
    private var idx = 0
    private(set) var ensureLoadedCalls = 0
    private(set) var transcribeCalls = 0
    private(set) var transcribedPaths: [String] = []   // the decode path handed to each transcribe call
    private(set) var transcribedSampleCounts: [Int] = []   // buffer sizes handed to the streaming seam
    private(set) var deletedModels: [String] = []

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

// MARK: - Test double for the Local-AI seam (P0)

/// Fake `LocalLLMService`: reports a fixed availability and returns canned insights (or throws).
/// Value type → trivially Sendable, like the seam it stands in for.
private struct FakeAIService: LocalLLMService {
    var availabilityToReturn: AIAvailability = .ready
    var canned: AIInsights = AIInsights(title: "T", summary: "S", actions: [])

    func availability(forLanguage language: String) -> AIAvailability { availabilityToReturn }
    func insights(forTranscript text: String, language: String) async throws -> AIInsights { canned }
    // A throwing/failure path is added in P2, when T5 (AI-failure-non-fatal) actually exercises it.
}

/// Fake `TextEmbedder`: returns a canned vector (or nil) and counts calls. Single-flight in tests
/// (each embed is awaited in turn), so the unchecked Sendable is safe — same pattern as FakeEngine.
private final class FakeEmbedder: TextEmbedder, @unchecked Sendable {
    private let vector: Embedding?
    private(set) var calls = 0
    init(vector: Embedding? = [1, 0, 0]) { self.vector = vector }
    func embed(_ text: String, language: String) async -> Embedding? { calls += 1; return vector }
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
    func embed(_ text: String, language: String) async -> Embedding? {
        if let hook { await MainActor.run { hook() } }   // main actor is free (caller is awaiting us)
        return vec(text)
    }
    func tokenVectors(_ text: String, language: String) async -> [(range: Range<String.Index>, vector: Embedding)]? {
        text.isEmpty ? nil : [(text.startIndex..<text.endIndex, vec(text))]
    }
}
