import XCTest
@testable import Parla

/// Юнит-тесты на чистую логику (без WhisperKit/аудио/UI):
/// имена моделей, тиры, история (схема + миграция), форматирование.
final class ParlaLogicTests: XCTestCase {

    // MARK: Имена моделей

    func testPrettyModel() {
        XCTAssertEqual(prettyModel("openai_whisper-tiny"), "Tiny")
        XCTAssertEqual(prettyModel("openai_whisper-large-v3"), "Large v3")
    }

    func testFriendlyModel() {
        XCTAssertEqual(friendlyModel("openai_whisper-large-v3-v20240930_626MB"), "Large v3 turbo")
        XCTAssertEqual(friendlyModel("openai_whisper-large-v3"), "Large v3")
        XCTAssertEqual(friendlyModel("distil-whisper_distil-large-v3"), "Distil Large v3")
        XCTAssertEqual(friendlyModel("openai_whisper-large-v2_949MB"), "Large v2")
        XCTAssertEqual(friendlyModel("openai_whisper-small"), "Small")
        XCTAssertEqual(friendlyModel("openai_whisper-base"), "Base")
        XCTAssertEqual(friendlyModel("openai_whisper-tiny"), "Tiny")
    }

    // MARK: Форматирование времени / текста

    func testFmtTime() {
        XCTAssertEqual(fmtTime(0), "00:00")
        XCTAssertEqual(fmtTime(65), "01:05")
        XCTAssertEqual(fmtTime(3661), "61:01")
    }

    func testDisplayPlain() {
        let item = TranscriptItem(sourceName: "a.ogg", language: "ru", durationSec: 1,
                                  model: "m", text: "привет мир", segments: [])
        XCTAssertEqual(item.display(timestamps: false), "привет мир")
        // таймкоды запрошены, но сегментов нет → откат к тексту
        XCTAssertEqual(item.display(timestamps: true), "привет мир")
    }

    func testDisplayTimestamps() {
        let segs = [Segment(start: 0, end: 2, text: "привет"),
                    Segment(start: 65, end: 67, text: "мир")]
        let item = TranscriptItem(sourceName: "a.ogg", language: "ru", durationSec: 67,
                                  model: "m", text: "привет мир", segments: segs)
        XCTAssertEqual(item.display(timestamps: true), "[00:00] привет\n[01:05] мир")
    }

    // MARK: История — схема (защищает от потери данных при правках модели)

    func testTranscriptCodableRoundtrip() throws {
        let item = TranscriptItem(sourceName: "a.ogg", language: "ru", durationSec: 12.5,
                                  model: "m", text: "txt", segments: [Segment(start: 0, end: 1, text: "x")])
        let data = try JSONEncoder().encode([item])
        let back = try JSONDecoder().decode([TranscriptItem].self, from: data)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].id, item.id)
        XCTAssertEqual(back[0].text, "txt")
        XCTAssertEqual(back[0].segments.first?.text, "x")
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

        // повторный вызов не перезатирает уже существующий target
        try Data("[1,2,3]".utf8).write(to: legacy)
        HistoryStore.migrate(target: target, legacy: legacy)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "[]")
    }

    func testMigrationNoopWhenLegacyMissing() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        let legacy = tmp.appendingPathComponent("Murmur/history.json")
        let target = tmp.appendingPathComponent("Parla/history.json")
        HistoryStore.migrate(target: target, legacy: legacy)
        XCTAssertFalse(fm.fileExists(atPath: target.path))
    }

    // MARK: Выбор модели по умолчанию

    func testBestDefault() {
        XCTAssertEqual(AppModel.bestDefault(from: ["openai_whisper-base", "openai_whisper-large-v3-v20240930"]),
                       "openai_whisper-large-v3-v20240930")
        XCTAssertEqual(AppModel.bestDefault(from: ["openai_whisper-base", "openai_whisper-large-v3-v20240930_626MB"]),
                       "openai_whisper-large-v3-v20240930_626MB")
        XCTAssertEqual(AppModel.bestDefault(from: ["openai_whisper-small", "openai_whisper-base"]),
                       "openai_whisper-base")
        XCTAssertEqual(AppModel.bestDefault(from: []), "openai_whisper-base")
    }

    // MARK: Путь к локальной модели

    func testLocalFolderPath() {
        let url = TranscriptionEngine.localFolder("openai_whisper-tiny")
        XCTAssertTrue(url.path.hasSuffix("huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-tiny"),
                      url.path)
    }

    // MARK: Тиры моделей (курирование + скрытие клонов)

    @MainActor func testModelTiers() {
        let m = AppModel()
        m.availableModels = [
            "openai_whisper-tiny", "openai_whisper-base", "openai_whisper-small",
            "openai_whisper-large-v3-v20240930_626MB", "openai_whisper-large-v3",
            "openai_whisper-large-v3_947MB", "distil-whisper_distil-large-v3",
        ]
        m.selectedModel = "openai_whisper-large-v3-v20240930_626MB"
        let tiers = m.modelTiers

        XCTAssertEqual(tiers.count, 5)                                  // 5 уровней, без квантованных клонов
        XCTAssertEqual(tiers.first(where: { $0.recommended })?.name,
                       "openai_whisper-large-v3-v20240930_626MB")       // turbo = рекомендованная
        XCTAssertTrue(tiers.contains { $0.title == "Large v3 turbo" })
        XCTAssertFalse(tiers.contains { $0.name.contains("distil") })   // distil/клоны скрыты
        XCTAssertFalse(tiers.contains { $0.name.contains("947MB") })
    }
}
