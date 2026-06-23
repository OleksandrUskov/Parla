import XCTest
import AppKit
@testable import Parla

/// Юнит-тесты на чистую логику (без WhisperKit/аудио/UI):
/// имена и тиры моделей, история (схема/поиск/экспорт/миграция),
/// размеры/пути моделей, сбор аудиофайлов, форматирование, языки.
final class ParlaLogicTests: XCTestCase {

    // MARK: Имена моделей

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

    // MARK: Форматирование

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
        XCTAssertEqual(item.display(timestamps: true), "привет мир")   // нет сегментов → откат
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

    // MARK: История — поиск

    func testFilterHistory() {
        let items = [
            makeItem(name: "a.ogg", text: "привет мир"),
            makeItem(name: "b.ogg", text: "пока всем"),
            makeItem(name: "secret.ogg", text: "ничего"),
        ]
        XCTAssertEqual(filterHistory(items, query: "").count, 3)       // пустой запрос → всё
        XCTAssertEqual(filterHistory(items, query: "  ").count, 3)     // пробелы → всё
        XCTAssertEqual(filterHistory(items, query: "мир").count, 1)    // по тексту
        XCTAssertEqual(filterHistory(items, query: "ПРИВЕТ").count, 1) // регистронезависимо
        XCTAssertEqual(filterHistory(items, query: "secret").count, 1) // по имени файла
        XCTAssertEqual(filterHistory(items, query: "неттакого").count, 0)
    }

    // MARK: История — экспорт

    func testExportText() {
        let items = [makeItem(name: "a.ogg", text: "первый"), makeItem(name: "b.ogg", text: "второй")]
        let out = exportText(items)
        XCTAssertTrue(out.hasPrefix("# Parla"))
        XCTAssertTrue(out.contains("## a.ogg"))
        XCTAssertTrue(out.contains("первый"))
        XCTAssertTrue(out.contains("второй"))
        XCTAssertEqual(exportText([]).hasPrefix("# Parla"), true)
    }

    // MARK: История — миграция Murmur → Parla

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

        try Data("[1,2,3]".utf8).write(to: legacy)  // повторно — не перезатирает
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

    // MARK: Выбор дефолтной модели

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

    // MARK: Пути / размеры моделей

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

    // MARK: Сбор аудиофайлов из папки

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
        XCTAssertEqual(found, ["a.ogg", "b.mp3", "d.wav"])  // только аудио, отсортировано по имени
        XCTAssertFalse(found.contains("note.txt"))
        XCTAssertFalse(found.contains("image.png"))
    }

    // MARK: Языки

    func testLanguages() {
        XCTAssertGreaterThan(whisperLanguages.count, 20)
        XCTAssertEqual(whisperLanguages.first?.code, "")   // «Авто» первым
        XCTAssertTrue(whisperLanguages.contains { $0.code == "en" })
        XCTAssertTrue(whisperLanguages.contains { $0.code == "ru" })
        XCTAssertTrue(whisperLanguages.contains { $0.code == "uk" })
        // коды уникальны
        XCTAssertEqual(Set(whisperLanguages.map(\.code)).count, whisperLanguages.count)
    }

    // MARK: Тиры моделей

    @MainActor func testModelTiersCuration() {
        let m = AppModel()
        m.availableModels = [
            "openai_whisper-tiny", "openai_whisper-base", "openai_whisper-small",
            "openai_whisper-large-v3-v20240930_626MB", "openai_whisper-large-v3",
            "openai_whisper-large-v3_947MB", "distil-whisper_distil-large-v3",
        ]
        m.selectedModel = "openai_whisper-large-v3-v20240930_626MB"
        let tiers = m.modelTiers

        XCTAssertEqual(tiers.count, 5)                                   // 5 уровней, без клонов
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
        m.selectedModel = "openai_whisper-large-v2_949MB"   // не попадает ни в один уровень
        let tiers = m.modelTiers
        XCTAssertEqual(tiers.count, 6)                       // 5 + «текущая»
        XCTAssertEqual(tiers.last?.name, "openai_whisper-large-v2_949MB")
        XCTAssertEqual(tiers.last?.title, "Large v2")
    }

    // MARK: Доп. покрытие (по итогам ревью)

    func testDisplayDropsEmptySegments() {
        let segs = [Segment(start: 0, end: 1, text: "привет"),
                    Segment(start: 1, end: 2, text: ""),
                    Segment(start: 2, end: 3, text: "мир")]
        let item = makeItem(text: "привет мир", segments: segs)
        XCTAssertEqual(item.display(timestamps: true), "[00:00] привет\n[00:02] мир")  // пустой сегмент выкинут
    }

    func testFmtTimeNegativeAndRounding() {
        XCTAssertEqual(fmtTime(-5), "00:00")    // отрицательное клампится
        XCTAssertEqual(fmtTime(-1), "00:00")
        XCTAssertEqual(fmtTime(59.6), "01:00")  // округление вверх
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
                       "openai_whisper-base.en")   // base-ветка пропускает .en → первый элемент
        XCTAssertEqual(AppModel.bestDefault(from: ["openai_whisper-base.en", "openai_whisper-base"]),
                       "openai_whisper-base")       // выбирает не-.en base
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
        XCTAssertEqual(out.components(separatedBy: "---").count, items.count + 1)  // один разделитель на запись
    }

    @MainActor func testModelTiersPrefixFallback() {
        let m = AppModel()
        m.availableModels = ["openai_whisper-tiny", "openai_whisper-large-v3-v20240930_626MB_quant"]
        m.selectedModel = "openai_whisper-tiny"
        XCTAssertTrue(m.modelTiers.contains { $0.title == "Large v3 turbo" })  // зарезолвилось по префиксу
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
        XCTAssertLessThan(m.modelTiers.count, 5)   // отсутствующие уровни не показываются
    }

    // MARK: Правка текста (фича 02)

    func testNormalizedEditDetectsChange() {
        let a = normalizedEdit("новый текст", from: "старый")
        XCTAssertTrue(a.changed)
        XCTAssertEqual(a.text, "новый текст")
        let b = normalizedEdit("одинаковый", from: "одинаковый")
        XCTAssertFalse(b.changed)
        XCTAssertEqual(b.text, "одинаковый")
    }

    func testNormalizedEditTrimsAndIgnoresWhitespace() {
        XCTAssertFalse(normalizedEdit("  привет мир  \n", from: "привет мир").changed)  // тримминг → равно
        XCTAssertFalse(normalizedEdit("a\r\nb", from: "a\nb").changed)                  // CRLF нормализован
        let changed = normalizedEdit("  новое  ", from: "старое")
        XCTAssertTrue(changed.changed)
        XCTAssertEqual(changed.text, "новое")   // вернулся тримнутый текст
    }

    func testNormalizedEditEmptyKeepsOriginal() {
        let r = normalizedEdit("   ", from: "оригинал")
        XCTAssertEqual(r.text, "оригинал")   // пустую правку не применяем
        XCTAssertFalse(r.changed)
    }

    func testEditedItemSuppressesTimestamps() {
        let segs = [Segment(start: 0, end: 2, text: "привет"), Segment(start: 65, end: 67, text: "мир")]
        let edited = makeItem(text: "привет мир", segments: segs, edited: true)
        XCTAssertEqual(edited.display(timestamps: true), "привет мир")   // таймкоды подавлены
        let notEdited = makeItem(text: "привет мир", segments: segs, edited: false)
        XCTAssertEqual(notEdited.display(timestamps: true), "[00:00] привет\n[01:05] мир")
        let legacy = makeItem(text: "привет мир", segments: segs, edited: nil)
        XCTAssertEqual(legacy.display(timestamps: true), "[00:00] привет\n[01:05] мир")  // nil = не редактировалось
    }

    /// Ключевой миграционный тест: старый history.json без ключей edited/editedAt декодится без throw.
    func testCodableBackwardCompatLegacyJSON() throws {
        let legacy = #"[{"id":"\#(UUID().uuidString)","date":740000000,"sourceName":"a.ogg","language":"ru","durationSec":1,"model":"openai_whisper-tiny","text":"привет","segments":[]}]"#
        let items = try JSONDecoder().decode([TranscriptItem].self, from: Data(legacy.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items.first?.edited)              // отсутствующий ключ → nil, НЕ throw
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

            // no-op: тот же текст → false, штамп не трогаем
            let stampedAt = m.history.first?.editedAt
            XCTAssertFalse(m.saveEdit("исправлено", for: item.id))
            XCTAssertEqual(m.history.first?.editedAt, stampedAt)

            // неизвестный id → false, история не меняется
            XCTAssertFalse(m.saveEdit("другое", for: UUID()))
            XCTAssertEqual(m.history.count, 1)

            // правка реально на диске (во временном файле) и декодится обратно
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
        XCTAssertTrue(blocks[0].contains("изменено"))    // правленая — с пометкой
        XCTAssertTrue(blocks[1].contains("## b.ogg"))
        XCTAssertFalse(blocks[1].contains("изменено"))   // обычная — без
    }

    // MARK: Батч-прогресс + уведомления (фича 05)

    func testBatchLabelSingleVsMulti() {
        XCTAssertEqual(batchLabel("a.ogg", nil), "«a.ogg»")
        XCTAssertEqual(batchLabel("a.ogg", BatchProgress(index: 1, total: 1, done: 0)), "«a.ogg»")  // одиночный — без счётчика
        XCTAssertEqual(batchLabel("a.ogg", BatchProgress(index: 3, total: 12, done: 2)), "«a.ogg» (3 из 12)")
    }

    func testEnginePhaseDefaultBatchNil() {
        XCTAssertEqual(EnginePhase.preparing("x"), .preparing("x", batch: nil))   // дефолтный конструктор = nil
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
        XCTAssertFalse(BatchNotifier.shouldNotify(total: 1, elapsed: 5,  frontmost: false))   // быстрый одиночный — молчим
        XCTAssertTrue (BatchNotifier.shouldNotify(total: 1, elapsed: 25, frontmost: false))   // долгий одиночный — шлём
        XCTAssertFalse(BatchNotifier.shouldNotify(total: 1, elapsed: 25, frontmost: true))    // но если активны — нет
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
        XCTAssertEqual(BatchNotifier.summary(succeeded: 11, failed: 1).body, "11 из 12 готово · 1 не удалась")
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

    // MARK: Слежение за папкой (фича 04)

    func testFolderScanIgnoresUnstable() {
        let a = stat("a.ogg", 100, 1000)
        let bPrev = stat("b.ogg", 100, 1000)
        let bNow  = stat("b.ogg", 200, 1000)   // размер вырос → файл ещё дописывается
        let (ready, next) = FolderScan.newStableFiles(
            current: [a, bNow],
            lastSeen: ["/watch/a.ogg": a, "/watch/b.ogg": bPrev],
            processed: [])
        XCTAssertEqual(ready.map { $0.url.lastPathComponent }, ["a.ogg"])   // только стабильный a
        XCTAssertEqual(next["/watch/b.ogg"], bNow)                          // b перенесён на следующий проход
    }

    func testFolderScanFirstSightNotReady() {
        let a = stat("a.ogg", 100, 1000)
        let (ready, next) = FolderScan.newStableFiles(current: [a], lastSeen: [:], processed: [])
        XCTAssertTrue(ready.isEmpty)               // впервые увиден — ещё не готов
        XCTAssertEqual(next["/watch/a.ogg"], a)    // но запомнен
    }

    func testFolderScanSkipsProcessed() {
        let a = stat("a.ogg", 100, 1000)
        let (ready, _) = FolderScan.newStableFiles(current: [a], lastSeen: ["/watch/a.ogg": a], processed: [a.dedupKey])
        XCTAssertTrue(ready.isEmpty)   // dedupKey уже обработан → пропускаем
    }

    func testFolderScanReadyIsSorted() {
        let c = stat("c.ogg", 1, 1), a = stat("a.ogg", 1, 1), b = stat("b.ogg", 1, 1)
        let lastSeen = ["/watch/c.ogg": c, "/watch/a.ogg": a, "/watch/b.ogg": b]
        let (ready, _) = FolderScan.newStableFiles(current: [c, a, b], lastSeen: lastSeen, processed: [])
        XCTAssertEqual(ready.map { $0.url.lastPathComponent }, ["a.ogg", "b.ogg", "c.ogg"])
    }

    func testDedupKeyChangesWithContent() {
        let base = stat("a.ogg", 100, 1000)
        XCTAssertEqual(base.dedupKey, stat("a.ogg", 100, 1000).dedupKey)       // тот же triple → тот же ключ
        XCTAssertNotEqual(base.dedupKey, stat("a.ogg", 200, 1000).dedupKey)    // другой размер
        XCTAssertNotEqual(base.dedupKey, stat("a.ogg", 100, 2000).dedupKey)    // другой mtime
    }

    func testCapProcessedFIFO() {
        XCTAssertEqual(FolderScan.capProcessed(["1", "2", "3", "4"], max: 2), ["3", "4"])  // старые отброшены
        XCTAssertEqual(FolderScan.capProcessed(["1"], max: 2), ["1"])                      // под лимитом — без изменений
        XCTAssertEqual(FolderScan.capProcessed(["1", "2"], max: 0), [])
    }

    func testProcessedStoreRoundtrip() {
        let original = ProcessedStore.fileURL
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ParlaPS-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ProcessedStore.fileURL = dir.appendingPathComponent("processed.json")
        defer { ProcessedStore.fileURL = original; try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(ProcessedStore.load(), [])                    // нет файла → пусто, без краша
        ProcessedStore.save(["k1", "k2", "k3"])
        XCTAssertEqual(ProcessedStore.load(), ["k1", "k2", "k3"])   // порядок сохранён (нужен для FIFO)
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
        XCTAssertEqual(flat, ["a.ogg"])                                                  // без подпапок, без note.txt
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

        // первый проход: файл впервые увиден → не готов
        let pass1 = AppModel.scanFolder(tmp, recursive: false)
        let (ready1, seen1) = FolderScan.newStableFiles(current: pass1, lastSeen: [:], processed: [])
        XCTAssertTrue(ready1.isEmpty)
        // второй проход без изменений → готов (двухпроходная гарантия стабильности, без FSEvents)
        let pass2 = AppModel.scanFolder(tmp, recursive: false)
        let (ready2, _) = FolderScan.newStableFiles(current: pass2, lastSeen: seen1, processed: [])
        XCTAssertEqual(ready2.map { $0.url.lastPathComponent }, ["a.ogg"])
    }

    // MARK: Перераспознать (фича 01)

    /// Ключевая обратная совместимость: старый history.json без sourcePath/sourceBookmark декодится.
    func testCodableBackwardCompatSourceFields() throws {
        let legacy = #"[{"id":"\#(UUID().uuidString)","date":740000000,"sourceName":"a.ogg","language":"ru","durationSec":1,"model":"openai_whisper-tiny","text":"привет","segments":[]}]"#
        let items = try JSONDecoder().decode([TranscriptItem].self, from: Data(legacy.utf8))
        XCTAssertNil(items.first?.sourcePath)        // отсутствующий ключ → nil, НЕ throw
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
        let item = makeItem(text: "t")   // sourcePath == nil (как у легаси-записи)
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
        item.sourcePath = nil            // путь отсутствует — должен найтись по bookmark
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
            m.retranscribe(item, with: "openai_whisper-tiny")   // та же модель → no-op, ни истории ни фазы
            XCTAssertEqual(m.history.first?.text, "оригинал")
            if case .idle = m.phase {} else { XCTFail("phase должна остаться .idle") }
        }
    }

    @MainActor func testCanRetranscribe() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ogg")
        try Data("x".utf8).write(to: tmp)
        defer { try? fm.removeItem(at: tmp) }
        let m = AppModel()
        XCTAssertFalse(m.canRetranscribe(makeItem(text: "t")))   // нет sourcePath → нельзя
        var present = makeItem(text: "t")
        present.sourcePath = tmp.path
        XCTAssertTrue(m.canRetranscribe(present))                // движок свободен + файл есть
    }

    // MARK: Аудиоплеер (фича 06)

    func testTranscriptItemDecodesWithoutAudioFile() throws {
        let legacy = #"[{"id":"\#(UUID().uuidString)","date":740000000,"sourceName":"a.ogg","language":"ru","durationSec":1,"model":"openai_whisper-tiny","text":"привет","segments":[]}]"#
        let items = try JSONDecoder().decode([TranscriptItem].self, from: Data(legacy.utf8))
        XCTAssertNil(items.first?.audioFile)        // нет ключа → nil, НЕ throw
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
        XCTAssertEqual(AudioStore.fileName(for: id, sourceExtension: "OGG"), "\(id.uuidString).ogg")  // нижний регистр
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
            XCTAssertNotNil(AudioStore.playableURL(for: item))   // копия на месте
            AudioStore.remove(item)
            XCTAssertNil(AudioStore.playableURL(for: item))      // удалена
        }
    }

    func testAudioStoreUrlMissingReturnsNil() {
        withTemporaryHistoryStore {
            var item = makeItem(text: "t")
            item.audioFile = "nope-\(UUID().uuidString).ogg"     // файла нет
            XCTAssertNil(AudioStore.playableURL(for: item))
        }
    }

    func testActiveSegmentIndex() {
        let segs = [Segment(start: 0, end: 2, text: "a"),
                    Segment(start: 2, end: 5, text: "b"),
                    Segment(start: 10, end: 12, text: "c")]
        XCTAssertNil(activeSegmentIndex(segs, at: -1))          // раньше первого
        XCTAssertEqual(activeSegmentIndex(segs, at: 0), 0)
        XCTAssertEqual(activeSegmentIndex(segs, at: 1.9), 0)
        XCTAssertEqual(activeSegmentIndex(segs, at: 2), 1)      // ровно start → новый сегмент
        XCTAssertEqual(activeSegmentIndex(segs, at: 6), 1)      // в зазоре → остаёмся на последнем начавшемся
        XCTAssertEqual(activeSegmentIndex(segs, at: 11), 2)
        XCTAssertEqual(activeSegmentIndex(segs, at: 100), 2)    // за концом → последний
        XCTAssertNil(activeSegmentIndex([], at: 1))             // нет сегментов
    }

    // MARK: Быстрая расшифровка — буфер + хоткей (фича 03)

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
        XCTAssertEqual(PasteboardReader.audioOnly(urls).map { $0.lastPathComponent }, ["a.ogg", "c.M4A"])  // регистронезависимо, только аудио
    }
    func testAudioOnlyEmpty() {
        XCTAssertTrue(PasteboardReader.audioOnly([]).isEmpty)
    }

    func testHotKeyMatchesExact() {
        let mods: NSEvent.ModifierFlags = [.control, .option, .command]
        XCTAssertTrue(hotKeyMatches(keyCode: 17, flags: mods, wantKey: 17, wantMods: mods))
    }
    func testHotKeyMatchesIgnoresExtraFlags() {
        let mods: NSEvent.ModifierFlags = [.control, .option, .command]
        XCTAssertTrue(hotKeyMatches(keyCode: 17, flags: mods.union(.capsLock), wantKey: 17, wantMods: mods))  // лишний capslock не мешает
    }
    func testHotKeyRejectsMissingModifier() {
        let mods: NSEvent.ModifierFlags = [.control, .option, .command]
        XCTAssertFalse(hotKeyMatches(keyCode: 17, flags: [.command], wantKey: 17, wantMods: mods))
    }
    func testHotKeyRejectsWrongKey() {
        let mods: NSEvent.ModifierFlags = [.control, .option, .command]
        XCTAssertFalse(hotKeyMatches(keyCode: 16, flags: mods, wantKey: 17, wantMods: mods))
    }

    // MARK: Авто-уборка аудио-кэша (LRU)

    func testEnforceAudioCapNoOpUnderCap() {
        let a = makeItem(text: "a"), b = makeItem(text: "b")
        let sizes = [a.id: Int64(100), b.id: Int64(100)]
        let evict = AudioStore.enforceAudioCap([b, a], capBytes: 1000, sizeOf: { sizes[$0.id] ?? 0 }, protected: [])
        XCTAssertTrue(evict.isEmpty)   // влезаем → ничего не трогаем
    }

    func testEnforceAudioCapEvictsOldest() {
        let n = makeItem(text: "n"), m = makeItem(text: "m"), o = makeItem(text: "o")   // newest-first: [n, m, o]
        let sizes = [n.id: Int64(400), m.id: Int64(400), o.id: Int64(400)]               // 1200 > 1000
        let evict = AudioStore.enforceAudioCap([n, m, o], capBytes: 1000, sizeOf: { sizes[$0.id] ?? 0 }, protected: [])
        XCTAssertEqual(evict, [o.id])   // только самый старый, до влезания (1200-400=800 ≤ 1000)
    }

    func testEnforceAudioCapProtectsSelected() {
        let n = makeItem(text: "n"), m = makeItem(text: "m"), o = makeItem(text: "o")
        let sizes = [n.id: Int64(400), m.id: Int64(400), o.id: Int64(400)]
        let evict = AudioStore.enforceAudioCap([n, m, o], capBytes: 1000, sizeOf: { sizes[$0.id] ?? 0 }, protected: [o.id])
        XCTAssertEqual(evict, [m.id])   // o защищён (играет/выделена) → выселяем следующую старую
    }

    func testEnforceAudioCapSkipsItemsWithoutAudio() {
        let n = makeItem(text: "n"), m = makeItem(text: "m"), o = makeItem(text: "o")
        let sizes = [n.id: Int64(600), o.id: Int64(600)]   // у m аудио нет (0 байт)
        let evict = AudioStore.enforceAudioCap([n, m, o], capBytes: 1000, sizeOf: { sizes[$0.id] ?? 0 }, protected: [])
        XCTAssertEqual(evict, [o.id])   // 1200>1000 → выселяем o (600≤1000); m пропущен (нет аудио)
    }

    func testEnforceAudioCapPartialWhenOnlyProtectedExceeds() {
        let big = makeItem(text: "big")
        let sizes = [big.id: Int64(2000)]   // одна запись больше всего кэпа, но защищена
        let evict = AudioStore.enforceAudioCap([big], capBytes: 1000, sizeOf: { sizes[$0.id] ?? 0 }, protected: [big.id])
        XCTAssertTrue(evict.isEmpty)   // не дёргаем аудио из-под плеера — частичное соответствие OK
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

    /// Выполнить блок с временным файлом истории — чтобы saveEdit/HistoryStore.save НЕ трогали
    /// реальную историю пользователя в ~/Library/Application Support/Parla/.
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
}
