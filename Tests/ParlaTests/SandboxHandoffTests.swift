import XCTest
@testable import ParlaCore

/// The handoff that carries a direct-download install's library into the Mac App Store build's container.
///
/// It exists because the migration everything here was designed around does not happen. Measured on macOS 26,
/// three ways: macOS does NOT bring `Application Support/<bundle-id>` into a new container. It DOES bring
/// `Preferences/<bundle-id>.plist` — but only when it creates the container itself, so pre-seeding the data
/// suppresses the settings. That trade is the whole design: stage both, or ship a store build that arrives
/// configured and empty.
///
/// The tests that matter here are the ones about NOT writing. This code removes a directory, and the directory
/// is a user's entire transcript library.
final class SandboxHandoffTests: ParlaTestCase {

    private var home: URL!
    private var live: URL!
    private let bundleID = "com.parla.app"

    override func setUp() {
        super.setUp()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-\(UUID().uuidString)", isDirectory: true)
        live = home.appendingPathComponent("live-library", isDirectory: true)
        try? FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    // MARK: helpers

    private func seed(_ dir: URL, _ name: String, _ contents: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(contents.utf8).write(to: dir.appendingPathComponent(name))
    }

    private func read(_ dir: URL, _ name: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    private var staged: URL { SandboxHandoff.stagedLibrary(home: home, bundleID: bundleID) }

    /// What the store build having taken over looks like on disk: a library in the container that the direct
    /// build did not leave there, i.e. one with no staging marker in it.
    private func storeBuildOwnsTheContainer() {
        try? FileManager.default.removeItem(at: SandboxHandoff.stagingMarker(home: home, bundleID: bundleID))
    }

    // MARK: where the copy has to land

    /// The one path that must be exactly right: it is where `.applicationSupportDirectory` resolves for a
    /// contained process, which is where `StorageRoot` will look and the only reason any of this works.
    func testTheStagedLibraryLandsWhereAContainedProcessWillLookForIt() {
        XCTAssertEqual(staged.path,
                       home.path + "/Library/Containers/com.parla.app/Data/Library/Application Support/com.parla.app")
        XCTAssertEqual(SandboxHandoff.stagedPreferences(home: home, bundleID: bundleID).path,
                       home.path + "/Library/Containers/com.parla.app/Data/Library/Preferences/com.parla.app.plist")
    }

    // MARK: the refusals — the tests that protect data

    /// 🔴 The guard everything rests on. Once the store build has claimed the container, the library inside it
    /// is the user's LIVE library — newer than ours, and the only copy of anything recorded since. Staging over
    /// it would delete real transcripts, and it would look like the app forgot them rather than like an error.
    func testAContainerTheStoreBuildAlreadyOwnsIsNeverTouched() {
        seed(live, "history.json", "the direct build's copy")
        seed(staged, "history.json", "what the store build has recorded since")
        // The settings are the other half, and the half a first draft of this test forgot: an overwrite would
        // also roll back the language, the chosen model and the Pro state to whatever the direct build had.
        let livePrefs = home.appendingPathComponent("Library/Preferences/com.parla.app.plist")
        seed(livePrefs.deletingLastPathComponent(), "com.parla.app.plist", "the direct build's settings")
        let stagedPrefs = SandboxHandoff.stagedPreferences(home: home, bundleID: bundleID)
        seed(stagedPrefs.deletingLastPathComponent(), "com.parla.app.plist", "the store build's settings")
        storeBuildOwnsTheContainer()

        XCTAssertEqual(SandboxHandoff.stage(home: home, bundleID: bundleID,
                                            liveLibrary: live, livePreferences: livePrefs, isSandboxed: false),
                       .skippedContainerInUse)
        XCTAssertEqual(read(staged, "history.json"), "what the store build has recorded since",
                       "the store build's own library must survive untouched")
        XCTAssertEqual(try? String(contentsOf: stagedPrefs, encoding: .utf8), "the store build's settings",
                       "…and so must its settings")
    }

    /// The whole lifecycle in one test: the direct build hands the library over, the store build's first launch
    /// claims it, and from that moment the direct build must never write there again — even though it is still
    /// installed, still launching, and still has a library of its own that is now the older one.
    func testTheStoreBuildsFirstLaunchEndsTheHandoffForGood() {
        seed(live, "history.json", "everything up to the switch")
        XCTAssertEqual(SandboxHandoff.stage(home: home, bundleID: bundleID, liveLibrary: live, isSandboxed: false),
                       .staged)

        // What the sandboxed build does on launch. It addresses its library directly, because inside a container
        // its home already IS the container.
        SandboxHandoff.claimContainer(library: staged)
        seed(staged, "history.json", "and everything the store build has recorded since")

        seed(live, "history.json", "the direct build, still running, still older")
        XCTAssertEqual(SandboxHandoff.stage(home: home, bundleID: bundleID, liveLibrary: live, isSandboxed: false),
                       .skippedContainerInUse)
        XCTAssertEqual(read(staged, "history.json"), "and everything the store build has recorded since")
    }

    /// A staging that failed halfway must not look like one of ours, or the next launch would leave a broken
    /// library in place believing the store build owns it.
    func testOnlyASucceededStagingIsMarkedAsOurs() {
        seed(live, "history.json", "library")
        XCTAssertEqual(SandboxHandoff.stage(home: home, bundleID: bundleID, liveLibrary: live, isSandboxed: false),
                       .staged)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SandboxHandoff.stagingMarker(home: home, bundleID: bundleID).path),
            "without this the very next launch refuses to refresh, and the copy silently goes stale")
    }

    /// The store build calling this would be staging its own data as its own input.
    func testAContainedProcessNeverStages() {
        seed(live, "history.json", "library")

        XCTAssertEqual(SandboxHandoff.stage(home: home, bundleID: bundleID, liveLibrary: live, isSandboxed: true),
                       .skippedSandboxed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    /// A fresh install has nothing to hand over, and must not leave an empty library behind that would later
    /// read as "the user had no notes".
    func testNothingIsStagedWhenThereIsNoLibrary() {
        try? FileManager.default.removeItem(at: live)

        XCTAssertEqual(SandboxHandoff.stage(home: home, bundleID: bundleID, liveLibrary: live, isSandboxed: false),
                       .skippedNoLibrary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    /// An identifier is not a path component. `..` collapses under `appendingPathComponent`, and the removal
    /// this performs would then aim at a directory nobody named.
    func testAnIdentifierThatIsNotAPathComponentIsRefused() {
        seed(live, "history.json", "library")

        XCTAssertEqual(SandboxHandoff.stage(home: home, bundleID: "../../..", liveLibrary: live, isSandboxed: false),
                       .skippedUnsafeDestination)
    }

    // MARK: the handoff itself

    /// Both halves, because either alone is a broken install: data without settings re-runs onboarding in a
    /// foreign language, and settings without data is the empty-but-configured app this whole thing exists to
    /// prevent.
    func testTheLibraryAndTheSettingsArriveTogether() {
        seed(live, "history.json", "the user's archive")
        seed(live.appendingPathComponent("audio", isDirectory: true), "note.m4a", "audio bytes")
        let prefs = home.appendingPathComponent("Library/Preferences/com.parla.app.plist")
        seed(prefs.deletingLastPathComponent(), "com.parla.app.plist", "the user's settings")

        XCTAssertEqual(SandboxHandoff.stage(home: home, bundleID: bundleID,
                                            liveLibrary: live, livePreferences: prefs, isSandboxed: false),
                       .staged)
        XCTAssertEqual(read(staged, "history.json"), "the user's archive")
        XCTAssertEqual(read(staged.appendingPathComponent("audio", isDirectory: true), "note.m4a"), "audio bytes",
                       "the whole tree, not just the top level")
        XCTAssertEqual(try? String(contentsOf: SandboxHandoff.stagedPreferences(home: home, bundleID: bundleID),
                                   encoding: .utf8),
                       "the user's settings")
    }

    /// It runs on every launch of the direct build, so a staging from last week must be replaced rather than
    /// kept. A stale copy is worse than none: it looks like the handoff worked.
    func testAStalePreviousStagingIsRefreshedRatherThanKept() {
        seed(live, "history.json", "first")
        seed(live, "deleted-since.json", "gone tomorrow")
        let livePrefs = home.appendingPathComponent("Library/Preferences/com.parla.app.plist")
        seed(livePrefs.deletingLastPathComponent(), "com.parla.app.plist", "settings v1")
        XCTAssertEqual(SandboxHandoff.stage(home: home, bundleID: bundleID,
                                            liveLibrary: live, livePreferences: livePrefs, isSandboxed: false),
                       .staged)

        try? FileManager.default.removeItem(at: live.appendingPathComponent("deleted-since.json"))
        seed(live, "history.json", "second")
        seed(livePrefs.deletingLastPathComponent(), "com.parla.app.plist", "settings v2")

        XCTAssertEqual(SandboxHandoff.stage(home: home, bundleID: bundleID,
                                            liveLibrary: live, livePreferences: livePrefs, isSandboxed: false),
                       .staged)
        XCTAssertEqual(read(staged, "history.json"), "second")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.appendingPathComponent("deleted-since.json").path),
                       "a refresh replaces the staging; it does not merge into it")
        XCTAssertEqual(try? String(contentsOf: SandboxHandoff.stagedPreferences(home: home, bundleID: bundleID),
                                   encoding: .utf8), "settings v2",
                       "the settings go stale the same way the library does")
    }

    /// The library is measured in gigabytes and this runs once per launch, so the copy must not cost the bytes.
    ///
    /// ⚠️ Scope, honestly: this asserts the PROPERTY, not the call. Swapping `clonefile` for
    /// `FileManager.copyItem` leaves it green — verified by reverting — because Foundation clones on APFS too.
    /// What `clonefile` buys over `copyItem` is the failure on a volume that cannot clone, rather than a silent
    /// multi-gigabyte duplication, and that difference needs a non-APFS volume to observe. The branch it takes
    /// when the clone fails is covered below; the volume-dependent part is not covered by any test here.
    func testTheCopyDoesNotDuplicateTheLibrarysBytes() throws {
        let big = live.appendingPathComponent("weights.bin")
        // 64 MB: big enough that a real copy shows up in the volume's used bytes, small enough to stay quick.
        try Data(count: 64 * 1024 * 1024).write(to: big)

        let free = { () -> Int64 in
            let v = try? self.home.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            return Int64(v?.volumeAvailableCapacity ?? 0)
        }
        let before = free()
        XCTAssertEqual(SandboxHandoff.stage(home: home, bundleID: bundleID, liveLibrary: live, isSandboxed: false),
                       .staged)
        let after = free()

        XCTAssertEqual((try? Data(contentsOf: staged.appendingPathComponent("weights.bin")))?.count, 64 * 1024 * 1024)
        // Other processes move the free-space needle too, so this asserts the ORDER OF MAGNITUDE: a real copy
        // costs 64 MB, a clone costs kilobytes of metadata.
        if before > 0 && after > 0 {
            XCTAssertLessThan(before - after, 32 * 1024 * 1024,
                              "a 64 MB file was duplicated rather than cloned")
        }
    }

    /// When the copy cannot happen, this says so and leaves no half-made library behind — a partial staging
    /// would be adopted as the user's whole archive by the store build, which reads it as "these are the notes".
    func testAFailedCopyLeavesNothingBehind() {
        seed(live, "history.json", "the user's archive")
        // A FILE where the container's `Application Support` directory has to be: nothing can be created under it.
        let supportPath = staged.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: supportPath.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data("not a directory".utf8).write(to: supportPath)

        XCTAssertEqual(SandboxHandoff.stage(home: home, bundleID: bundleID, liveLibrary: live, isSandboxed: false),
                       .skippedCloneUnsupported)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }
}
