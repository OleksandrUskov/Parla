import XCTest
import os
import AVFoundation
import AppKit
@testable import ParlaCore
@testable import Parla

/// App-level behaviour: inline editing, optional fields and display titles, batch progress and notifications, defaults, the parla:// parser, onboarding, errors.
final class AppBehaviorTests: ParlaLogicTestCase {
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
    /// The property is "every batch notification is branded", not "it says one particular word". Written
    /// against a literal, this test went red on the rebrand and invited someone to just update the string —
    /// which would have kept the literal and lost the guard.
    func testSummaryTitleIsAlwaysTheAppName() {
        XCTAssertEqual(BatchNotifier.summary(succeeded: 1, failed: 0).title, Brand.name)
        XCTAssertEqual(BatchNotifier.summary(succeeded: 0, failed: 2).title, Brand.name)
        XCTAssertFalse(Brand.name.isEmpty, "an unbranded notification is indistinguishable from another app's")
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

    /// Was `XCTAssertTrue(CompletionSound.isHeadless)` — it pinned the MECHANISM (production asking whether it was
    /// running under test) rather than the GUARANTEE. The mechanism is gone; the guarantee is stronger and is what
    /// this now pins: the Core's side-effecting seams are inert until an app wires them, so nothing in the suite
    /// can beep, spawn a panel, or synthesize a keystroke — including from a call site nobody has written yet.
    @MainActor func testSideEffectingSeamsAreInertUntilAnAppWiresThem() {
        let m = AppModel(engine: FakeEngine())
        m.playCompletionSound(true)      // must be a no-op, not a beep
        m.playCompletionSound(false)
        m.showToast("не должно появиться", false)
        m.showToast("и это тоже", true)
        m.hideToast()
        XCTAssertFalse(m.attemptPaste(), "the Core must never synthesize a paste on its own")
        XCTAssertFalse(m.pasteIsSelfFrontmost(), "…and must not claim to know what is frontmost")
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


}
