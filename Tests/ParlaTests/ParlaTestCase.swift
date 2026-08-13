import XCTest
@testable import ParlaCore

/// Base class for any test that touches app state, and mandatory for anything that drives the transcription
/// pipeline.
///
/// Several of Parla's stores are process-wide statics that read the REAL disk: history, processed-files, and the
/// two model caches. A test that leaves them pointing at the user's data is not just impolite, it is
/// non-deterministic — and one of those paths can take the whole test process down.
///
/// That is not hypothetical. `retrievalEmbedder` returns the MLX embedder whenever `EmbeddingModelSpec` reports
/// the download-tier model present, and on a machine where it genuinely IS downloaded, a test that transcribes
/// anything reaches MLX through the fire-and-forget `refreshSemanticIndex` that follows every note. MLX then asks
/// for a Metal library that `swift test` never builds and aborts the process from a background thread — at a
/// different, innocent-looking test each run, minutes after the test that actually caused it had passed.
///
/// So the redirects live here once, and pipeline tests inherit them rather than remembering to copy a setUp.
class ParlaTestCase: XCTestCase {

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParlaTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // The user's history — and the embedding/audio stores, which derive their directory from it.
        HistoryStore.fileURL = dir.appendingPathComponent("history.json")
        // A separate global path, so it needs its own redirect or folder-watch tests write the real file.
        ProcessedStore.fileURL = dir.appendingPathComponent("processed.json")
        // Never migrate the user's legacy dataset during a test run.
        HistoryStore.legacyBase = dir.appendingPathComponent("no-legacy")
        // The iOS import container. This one is DELETED FROM — `pruneImportedOrphans` removes every unreferenced
        // subdirectory — so leaving it pointed at the real container is the "a test wiped user data" shape.
        AppModel.importsRoot = dir.appendingPathComponent("imports", isDirectory: true)

        #if os(macOS)
        // The two model caches. Redirecting them makes `isDownloaded()` deterministically false, which keeps
        // availability assertions stable AND keeps the MLX runtime out of the test process entirely.
        MLXModelSpec.downloadBase = dir.appendingPathComponent("mlx")
        EmbeddingModelSpec.downloadBase = dir.appendingPathComponent("embed")
        #endif
    }
}
