import XCTest
@testable import ParlaCore

/// macOS kept its model weights at HubApi's default, `~/Documents/huggingface` — measured at 2.4 GB on the
/// development machine. Documents is user-visible, swept into Time Machine, and uploaded wholesale to iCloud for
/// anyone with Desktop & Documents syncing enabled. That was the wrong place before the Mac App Store made it a
/// blocker: weights are cache, and cache does not belong in someone's documents.
///
/// The move is the delicate part. That legacy path is HubApi's DEFAULT, so it is shared ground — any other app
/// built on swift-transformers downloads into the same directory. These tests pin that the relocation takes only
/// what this app put there and leaves everything else untouched. The pure function is exercised with temporary
/// paths; `prepareModelStorage`, which supplies the real ones, is never called from a test.
final class ModelRelocationTests: ParlaTestCase {

    private var legacy: URL!
    private var current: URL!

    override func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("relocation-\(UUID().uuidString)", isDirectory: true)
        legacy = root.appendingPathComponent("Documents/huggingface", isDirectory: true)
        current = root.appendingPathComponent("Application Support/huggingface", isDirectory: true)
    }

    /// Write a marker file at `<base>/models/<owner>/<repo>/weights.bin` and return its path.
    @discardableResult
    private func seed(_ base: URL, owner: String, repo: String, contents: String) -> URL {
        let dir = base.appendingPathComponent("models/\(owner)/\(repo)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("weights.bin")
        try? Data(contents.utf8).write(to: file)
        return file
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The ordinary upgrade: both owners this app populates move, and the emptied legacy tree is cleaned up.
    func testTheAppsOwnModelsMoveAndTheEmptiedTreeIsRemoved() {
        seed(legacy, owner: "argmaxinc", repo: "whisperkit-coreml", contents: "whisper")
        seed(legacy, owner: "openai", repo: "whisper-large-v3", contents: "tokenizer")

        let moved = ModelStorage.migrateLegacyTree(from: legacy, to: current,
                                                   owners: ["argmaxinc", "openai"])

        XCTAssertEqual(Set(moved), ["argmaxinc", "openai"])
        XCTAssertTrue(exists(current.appendingPathComponent("models/argmaxinc/whisperkit-coreml/weights.bin")))
        XCTAssertTrue(exists(current.appendingPathComponent("models/openai/whisper-large-v3/weights.bin")))
        XCTAssertFalse(exists(legacy), "an emptied legacy tree should not be left behind as clutter")
    }

    /// THE safety property: the legacy path is HubApi's default, so another swift-transformers app's models can
    /// be sitting right next to ours. Moving the whole directory would take them along and cost that app a
    /// re-download of gigabytes. Nothing but our own owners may be touched.
    func testAnotherAppsModelsAreLeftExactlyWhereTheyAre() {
        seed(legacy, owner: "argmaxinc", repo: "whisperkit-coreml", contents: "ours")
        let foreign = seed(legacy, owner: "some-other-org", repo: "their-model", contents: "theirs")

        let moved = ModelStorage.migrateLegacyTree(from: legacy, to: current, owners: ["argmaxinc", "openai"])

        XCTAssertEqual(moved, ["argmaxinc"])
        XCTAssertTrue(exists(foreign), "a stranger's models must not be relocated")
        XCTAssertEqual(try? String(contentsOf: foreign, encoding: .utf8), "theirs")
        XCTAssertTrue(exists(legacy), "…and the tree that still holds them must survive")
        XCTAssertFalse(exists(current.appendingPathComponent("models/some-other-org")))
    }

    /// The destination is the live tree and must win. Merging into it could mix a half-downloaded old copy with
    /// a good current one, and the failure would show up as a corrupt model, not as an error.
    func testAnOwnerAlreadyPresentAtTheDestinationIsNotOverwritten() {
        seed(legacy, owner: "argmaxinc", repo: "whisperkit-coreml", contents: "old")
        seed(current, owner: "argmaxinc", repo: "whisperkit-coreml", contents: "live")

        let moved = ModelStorage.migrateLegacyTree(from: legacy, to: current, owners: ["argmaxinc"])

        XCTAssertTrue(moved.isEmpty)
        XCTAssertEqual(try? String(contentsOf: current.appendingPathComponent("models/argmaxinc/whisperkit-coreml/weights.bin"),
                                   encoding: .utf8), "live", "the live tree must not be overwritten by the old one")
    }

    /// A fresh install has nothing to move, and must not create anything by looking.
    func testNothingToMigrateIsANoOp() {
        XCTAssertEqual(ModelStorage.migrateLegacyTree(from: legacy, to: current, owners: ["argmaxinc"]), [])
        XCTAssertFalse(exists(current), "probing for a legacy tree must not create the destination")
    }

    /// Partial state: one owner present, one absent. The present one moves; the absent one is not invented.
    func testOnlyWhatIsActuallyThereMoves() {
        seed(legacy, owner: "openai", repo: "whisper-tiny", contents: "tokenizer")

        let moved = ModelStorage.migrateLegacyTree(from: legacy, to: current, owners: ["argmaxinc", "openai"])

        XCTAssertEqual(moved, ["openai"])
        XCTAssertFalse(exists(current.appendingPathComponent("models/argmaxinc")))
    }

    /// The production paths themselves: Application Support on both platforms, never Documents. This is the
    /// assertion that would have caught the original mistake.
    func testTheProductionModelPathIsNotTheUsersDocuments() {
        let base = TranscriptionEngine.downloadBase()
        XCTAssertTrue(base.path.contains("Application Support"), "weights belong in Application Support")
        XCTAssertFalse(base.path.contains("/Documents/"), "weights must never live in the user's Documents")
        XCTAssertTrue(TranscriptionEngine.modelsRoot().path.hasPrefix(base.path))
        #if os(macOS)
        XCTAssertTrue(TranscriptionEngine.legacyDownloadBase().path.contains("/Documents/"),
                      "the legacy probe must still point at the old location, or nothing gets migrated")
        XCTAssertEqual(TranscriptionEngine.hubRepoOwners, ["argmaxinc", "openai"])
        #endif
    }
}
