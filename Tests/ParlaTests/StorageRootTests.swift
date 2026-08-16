import XCTest
@testable import ParlaCore

/// Everything this app owns lives under one directory, and that directory is named after the BUNDLE
/// IDENTIFIER rather than after the app.
///
/// The reason is the Mac App Store. When a previously-unsandboxed app becomes sandboxed, the system migrates
/// its existing data into the new container by bundle identifier. Our store directory was named `Parla`, which
/// matches nothing — so a sandboxed build would have started on an empty container while every file sat
/// untouched on disk, invisible. Worse, the preferences plist IS bundle-ID-named and does migrate, so the app
/// would have arrived configured: remembering a watched folder it cannot watch and a last file it cannot
/// replay. After that build ships there is no recovery from inside the app.
// `ParlaLogicTestCase` rather than `ParlaTestCase`: it carries `repoRoot`, which the source scan needs.
final class StorageRootTests: ParlaLogicTestCase {

    private var support: URL!

    override func setUp() {
        super.setUp()
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("root-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    private func seedLibrary(_ dir: URL, marker: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(marker.utf8).write(to: dir.appendingPathComponent("history.json"))
    }

    private func marker(_ dir: URL) -> String? {
        try? String(contentsOf: dir.appendingPathComponent("history.json"), encoding: .utf8)
    }

    /// The upgrade: a previous install's whole library arrives under the new name, contents intact.
    func testAPreviousInstallsLibraryMovesToTheBundleIdentifiedRoot() {
        seedLibrary(support.appendingPathComponent("Parla"), marker: "the user's archive")
        let target = support.appendingPathComponent("com.parla.app")

        XCTAssertEqual(StorageRoot.migrateIfNeeded(support: support, into: target), "Parla")
        XCTAssertEqual(marker(target), "the user's archive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("Parla").path))
    }

    /// An existing root is the LIVE library. Merging a stale one into it would produce a history that is
    /// neither, and the damage would look like missing notes rather than an error.
    func testAnExistingRootIsNeverMergedInto() {
        seedLibrary(support.appendingPathComponent("Parla"), marker: "old")
        let target = support.appendingPathComponent("com.parla.app")
        seedLibrary(target, marker: "live")

        XCTAssertNil(StorageRoot.migrateIfNeeded(support: support, into: target))
        XCTAssertEqual(marker(target), "live", "the live library must win")
        XCTAssertEqual(marker(support.appendingPathComponent("Parla")), "old", "…and the old one must survive")
    }

    /// A FILE with the legacy name is not a library. Moving it would produce a "root" nothing can be written into.
    func testAFileWithTheLegacyNameIsNotMistakenForALibrary() {
        try? Data("not a folder".utf8).write(to: support.appendingPathComponent("Parla"))
        let target = support.appendingPathComponent("com.parla.app")

        XCTAssertNil(StorageRoot.migrateIfNeeded(support: support, into: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    /// A fresh install has nothing to move and must not create anything by looking.
    func testAFreshInstallMigratesNothing() {
        let target = support.appendingPathComponent("com.parla.app")
        XCTAssertNil(StorageRoot.migrateIfNeeded(support: support, into: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    /// The production root itself: under Application Support, named for the running bundle.
    func testTheProductionRootIsNamedAfterTheBundleIdentifier() {
        let root = StorageRoot.defaultURL()
        XCTAssertTrue(root.path.contains("Application Support"))
        XCTAssertEqual(root.lastPathComponent, Bundle.main.bundleIdentifier ?? "com.parla.app")
        XCTAssertTrue(StorageRoot.legacyFolderNames.contains("Parla"),
                      "the name every existing install uses must stay in the legacy list")
    }

    /// The property that makes the rename worth anything: every store hangs off the ONE root. A store that
    /// builds its own path from Application Support is left outside the container migration — silently.
    func testEveryStoreDerivesFromTheSingleRoot() throws {
        // Exact equality, not a prefix: a store one level off would still pass a prefix check while sitting
        // outside the directory the container migration moves.
        let production = StorageRoot.defaultURL()
        XCTAssertEqual(ChunkProgressStore.defaultFileURL(), production.appendingPathComponent("chunk-progress.json"))
        XCTAssertEqual(AppModel.defaultImportsRoot(), production.appendingPathComponent("imports", isDirectory: true))
        XCTAssertEqual(MLXModelSpec.defaultDownloadBase(), production.appendingPathComponent("mlx", isDirectory: true))
        XCTAssertEqual(EmbeddingModelSpec.defaultDownloadBase(), production.appendingPathComponent("embed", isDirectory: true))
        // The weights base follows the LIVE root instead, because `prepareModelStorage` MOVES directories with
        // it — a test that triggered that must relocate a temp tree, never the developer's real models.
        XCTAssertEqual(TranscriptionEngine.downloadBase(), StorageRoot.url.appendingPathComponent("huggingface", isDirectory: true))

        // …and nothing may hardcode a folder name beside it. Same file-scan idiom this repo already uses for
        // claims about the build that no type can express.
        let sources = repoRoot.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 20, "the source scan found nothing — the path is wrong")
        for file in files {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            XCTAssertFalse(text.contains("appendingPathComponent(\"Parla"),
                           "\(file.lastPathComponent) hardcodes a storage folder instead of using StorageRoot")
        }
    }
}
