import XCTest
@testable import ParlaCore

/// Pins the rule that large re-downloadable model trees stay OUT of the user's backup. It used to be implemented
/// once, inline, for the WhisperKit tree only — so the ~2.3 GB MLX/Qwen model and the MLX embedding model, both
/// added later, were backed up in full (App Store 2.5 on iOS, Time Machine on macOS).
final class ModelBackupExclusionTests: ParlaTestCase {

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

    /// MLX cannot run on the iOS simulator at all, and an Apple-Silicon simulator answers `arch(arm64)` — so an
    /// arch-only check would offer a ~2.3 GB download there and crash on first use. Inert today (this backend is
    /// macOS-only), pinned now so it stays correct when MLX reaches the iOS build.
    func testMLXIsNeverConsideredSupportedOnASimulator() {
        #if targetEnvironment(simulator)
        XCTAssertFalse(MLXLLMService.isSupportedHardware, "the simulator must never be offered the MLX download")
        #else
        XCTAssertEqual(MLXLLMService.isSupportedHardware, true, "real Apple Silicon supports MLX")
        #endif
    }

    #if os(macOS)
    /// Both MLX stores must live under Application Support — one deletable tree with one "disk used" number — and
    /// never in Documents, where the user sees (and syncs) them.
    ///
    /// Asserts the PRODUCTION default rather than `downloadBase`, which the test base class redirects to a temp
    /// dir on purpose. Checking the redirected value would only prove the isolation works.
    func testMLXStoresLiveUnderApplicationSupport() {
        for base in [MLXModelSpec.defaultDownloadBase(), EmbeddingModelSpec.defaultDownloadBase()] {
            XCTAssertTrue(base.path.contains("Application Support"), "unexpected model base: \(base.path)")
            XCTAssertFalse(base.path.contains("/Documents/"), "model weights must not sit in Documents")
        }
    }

    /// …and the isolation itself is load-bearing enough to pin: a test run must never see the user's real model
    /// cache, because `retrievalEmbedder` switches to the MLX embedder when it does — which pulls the MLX runtime
    /// into a process that has no Metal library and aborts it from a background thread.
    func testTestRunsNeverSeeTheRealModelCache() {
        XCTAssertFalse(MLXModelSpec.downloadBase.path.contains("Application Support"),
                       "the test base class must redirect the model cache")
        XCTAssertFalse(EmbeddingModelSpec.isDownloaded(), "…so no model is ever 'downloaded' during a test run")
    }
    #endif
}
