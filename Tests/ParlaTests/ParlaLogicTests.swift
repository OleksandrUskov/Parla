import XCTest
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
        XCTAssertEqual(AppModel.bestDefault(from: ["openai_whisper-large-v3", "openai_whisper-tiny"]),
                       "openai_whisper-large-v3")
        XCTAssertEqual(AppModel.bestDefault(from: ["openai_whisper-small", "openai_whisper-base"]),
                       "openai_whisper-base")
        XCTAssertEqual(AppModel.bestDefault(from: ["openai_whisper-small"]), "openai_whisper-small")
        XCTAssertEqual(AppModel.bestDefault(from: []), "openai_whisper-base")
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
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "i=0; while [ $i -lt 6000 ]; do echo 'xxxxxxxxxxxxxxxxxxxxxxxxxx' 1>&2; i=$((i+1)); done; exit 3"]
        let exp = expectation(description: "drain completes")
        let box = NSMutableArray()   // thread-safe handoff of the status
        Thread.detachNewThread {
            let r = try? AudioConverter.runCapturingStderr(p)
            box.add(r?.status ?? -1)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 15)
        XCTAssertEqual((box.firstObject as? NSNumber)?.int32Value, 3)   // completed (not deadlocked), exit code preserved
    }

    /// A wedged child (sleep 30) must be killed by the watchdog, not block readDataToEndOfFile forever.
    func testRunCapturingStderrWatchdogTerminatesHang() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        let exp = expectation(description: "watchdog fires")
        let box = NSMutableArray()
        let start = Date()
        Thread.detachNewThread {
            let r = try? AudioConverter.runCapturingStderr(p, timeout: 0.4)
            box.add(r?.status ?? 0)
            box.add(Date().timeIntervalSince(start))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
        XCTAssertLessThan((box.lastObject as? NSNumber)?.doubleValue ?? .greatestFiniteMagnitude, 5)  // killed ~0.4s, not 30s
        XCTAssertNotEqual((box.firstObject as? NSNumber)?.int32Value, 0)                              // terminated → non-zero
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
            HistoryStore.fileURL = original
            try? FileManager.default.removeItem(at: dir)
        }
        body()
    }

    /// Async sibling of withTemporaryHistoryStore — for `await transcribe(...)` orchestration tests.
    private func withTemporaryHistoryStoreAsync(_ body: () async -> Void) async {
        let original = HistoryStore.fileURL
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ParlaTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        HistoryStore.fileURL = dir.appendingPathComponent("history.json")
        defer {
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

    func deleteModel(_ name: String) async throws { deletedModels.append(name) }
}
