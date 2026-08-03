import XCTest
@testable import ParlaCore

/// Pins the rule that large re-downloadable model trees stay OUT of the user's backup. It used to be implemented
/// once, inline, for the WhisperKit tree only — so the ~2.3 GB MLX/Qwen model and the MLX embedding model, both
/// added later, were backed up in full (App Store 2.5 on iOS, Time Machine on macOS).
final class ModelBackupExclusionTests: XCTestCase {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("modelstore-\(UUID().uuidString)", isDirectory: true)
    }

    func testPrepareCreatesTheDirectoryAndExcludesItFromBackup() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "precondition: does not exist yet")

        XCTAssertTrue(ModelStorage.prepareExcludedFromBackup(dir), "the flag must actually be set")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "must create the tree before download")
        XCTAssertTrue(ModelStorage.isExcludedFromBackup(dir), "a re-downloadable model tree must not be backed up")
    }

    func testPrepareIsIdempotent() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        ModelStorage.prepareExcludedFromBackup(dir)
        try Data("weights".utf8).write(to: dir.appendingPathComponent("model.safetensors"))

        XCTAssertTrue(ModelStorage.prepareExcludedFromBackup(dir), "calling it again on a populated tree is fine")
        XCTAssertTrue(ModelStorage.isExcludedFromBackup(dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path),
                      "must never clobber already-downloaded weights")
    }

    /// A plain directory is NOT excluded by default — proves the assertions above are testing something real
    /// rather than a flag the filesystem hands out for free.
    func testAPlainDirectoryIsNotExcluded() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(ModelStorage.isExcludedFromBackup(dir))
    }

    #if os(macOS)
    /// Both MLX stores must live under Application Support — one deletable tree with one "disk used" number — and
    /// never in Documents, where the user sees (and syncs) them.
    func testMLXStoresLiveUnderApplicationSupport() {
        for base in [MLXModelSpec.downloadBase, EmbeddingModelSpec.downloadBase] {
            XCTAssertTrue(base.path.contains("Application Support"), "unexpected model base: \(base.path)")
            XCTAssertFalse(base.path.contains("/Documents/"), "model weights must not sit in Documents")
        }
    }
    #endif
}
