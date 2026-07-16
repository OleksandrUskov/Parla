import XCTest
import ParlaCore
@testable import Parla_iOS

/// model weights RELOCATED out of Documents (user-visible + iCloud-backed = App Store 2.5)
/// into Application Support, excluded from backup. This is device-agnostic filesystem logic (no ANE), so it's
/// fully verifiable on the sim — a repro-gate for the storage change: the exact assertions that would fail if a
/// future edit regresses the location or the backup-exclusion flag.
final class ModelStorageTests: XCTestCase {

    func testDownloadBaseIsApplicationSupportNotDocuments() {
        let base = TranscriptionEngine.downloadBase().path
        XCTAssertTrue(base.contains("Application Support"), "iOS weights must live under Application Support, got \(base)")
        XCTAssertFalse(base.contains("/Documents"), "iOS weights must NOT live under Documents (iCloud-backed), got \(base)")
        XCTAssertTrue(base.hasSuffix("huggingface"), "downloadBase must be the huggingface component HubApi expects, got \(base)")
    }

    func testModelsRootMirrorsHubApiLayoutUnderDownloadBase() {
        // HubApi stores at <downloadBase>/models/<repo.id>; modelsRoot() must mirror that exactly, else a
        // download lands where isDownloaded() can't see it (silent re-download loop).
        let root = TranscriptionEngine.modelsRoot().path
        XCTAssertTrue(root.hasSuffix("huggingface/models/argmaxinc/whisperkit-coreml"),
                      "modelsRoot must be <downloadBase>/models/argmaxinc/whisperkit-coreml, got \(root)")
        XCTAssertTrue(root.hasPrefix(TranscriptionEngine.downloadBase().path),
                      "modelsRoot must sit under downloadBase")
    }

    func testPrepareModelStorageCreatesAndExcludesFromBackup() throws {
        TranscriptionEngine.prepareModelStorage()
        let hf = TranscriptionEngine.downloadBase()
        XCTAssertTrue(FileManager.default.fileExists(atPath: hf.path), "prepareModelStorage must create the huggingface dir")
        let excluded = try hf.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true, "the model tree must be excluded from iCloud/iTunes backup")
    }
}
