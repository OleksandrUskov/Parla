import XCTest
@testable import ParlaCore

/// Getting back to a note's ORIGINAL file after a relaunch — the thing «re-transcribe» and «replay the last
/// file» both depend on, and the thing the App Sandbox takes away unless the code asks for it correctly.
///
/// Both bugs these tests pin were found by an audit of the Mac App Store work and were invisible outside a
/// container, because the sandbox profile allows `file-read-metadata` across the home directory: `fileExists`
/// is a stat and SUCCEEDS on a file the process may not `open`. Every check the code used to make therefore
/// passed, and only the decode failed.
///
/// ⚠️ `BookmarkTests` already exercised the bookmark branch — by setting `sourcePath = nil` "to force the
/// bookmark branch". It had accommodated the bug rather than caught it: the input it never tried was the only
/// one that matters, a path and a bookmark that BOTH resolve. Same shape as the two property tests that went
/// green first try earlier in this project.
final class SandboxSourceAccessTests: ParlaTestCase {

    private var dir: URL!
    private var viaPath: URL!
    private var viaBookmark: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-access-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        viaPath = dir.appendingPathComponent("reached-by-path.m4a")
        viaBookmark = dir.appendingPathComponent("reached-by-bookmark.m4a")
        try? Data("a".utf8).write(to: viaPath)
        try? Data("b".utf8).write(to: viaBookmark)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// An item whose path and bookmark point at DIFFERENT existing files, so which one comes back is a direct
    /// readout of the order — no sandbox required to observe it.
    private func itemPointingBothWays() -> TranscriptItem {
        var item = TranscriptItem(sourceName: "n.m4a", language: "ru", durationSec: 1,
                                  model: "m", text: "t", segments: [])
        item.sourcePath = viaPath.path
        item.sourceBookmark = Bookmarks.make(for: viaBookmark)
        return item
    }

    // MARK: the order

    /// 🔴 The bug. Inside a container the bookmark is the ONLY branch that carries a grant, and the old code
    /// could never reach it: it returned the bare path — with `scoped: false` — whenever `fileExists` passed,
    /// which under the sandbox it does for files the app cannot open. The store build would show
    /// «re-transcribe» enabled, start no scope, and fail at the decode with a format error.
    func testInsideAContainerTheBookmarkWins() throws {
        let item = itemPointingBothWays()
        XCTAssertNotNil(item.sourceBookmark, "no bookmark means this test proves nothing")

        guard case .found(let url, let scoped) = item.resolveSource(sandboxed: true) else {
            return XCTFail("expected to resolve")
        }
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        XCTAssertEqual(url.lastPathComponent, "reached-by-bookmark.m4a",
                       "a contained process must go through the bookmark, or it gets a path it may not open")
    }

    /// Outside a container the path goes first, and deliberately: it is a stat instead of a bookmark
    /// resolution plus a start/stop pair, and this is called from a SwiftUI `.help` that re-evaluates on
    /// render. Both orders find a file; only the grant differs.
    func testOutsideAContainerThePathWins() {
        guard case .found(let url, let scoped) = itemPointingBothWays().resolveSource(sandboxed: false) else {
            return XCTFail("expected to resolve")
        }
        XCTAssertEqual(url.lastPathComponent, "reached-by-path.m4a")
        XCTAssertFalse(scoped, "the path branch grants nothing, so it must not claim a scope the caller would stop")
    }

    /// Whichever order applies, a missing file must fall through to the other mechanism rather than to
    /// `.missing` — that fallback is what keeps a moved file reachable.
    func testEitherOrderFallsThroughToTheOtherMechanism() throws {
        var item = itemPointingBothWays()
        item.sourcePath = dir.appendingPathComponent("never-existed.m4a").path

        for sandboxed in [true, false] {
            guard case .found(let url, let scoped) = item.resolveSource(sandboxed: sandboxed) else {
                return XCTFail("sandboxed=\(sandboxed): the bookmark should still have found it")
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
            XCTAssertEqual(url.lastPathComponent, "reached-by-bookmark.m4a", "sandboxed=\(sandboxed)")
        }
    }

    /// Nothing to resolve is `.missing`, and it must not be reported as found in either order.
    func testNothingToResolveIsMissing() {
        var item = TranscriptItem(sourceName: "n.m4a", language: "ru", durationSec: 1,
                                  model: "m", text: "t", segments: [])
        item.sourcePath = dir.appendingPathComponent("gone.m4a").path
        item.sourceBookmark = nil
        for sandboxed in [true, false] {
            if case .missing = item.resolveSource(sandboxed: sandboxed) {} else {
                XCTFail("sandboxed=\(sandboxed): expected .missing")
            }
        }
    }

    // MARK: the grant that has to outlive the resolve

    /// «Replay the last file» only ENQUEUES; the decode opens the file minutes later. Releasing the grant at
    /// resolve time — which the code did, with a comment saying it was free while the app was unsandboxed —
    /// made every replay fail after a relaunch in the store build. Handing the grant to the async funnel
    /// instead leaks one per replay forever, which is what that comment was avoiding. Hence: hold it, but
    /// never more than one.
    @MainActor
    func testANewReplayReleasesExactlyThePreviousGrant() {
        var stopped: [String] = []
        let grant = SingleScopedGrant { stopped.append($0.lastPathComponent) }

        grant.hold(viaPath)
        XCTAssertEqual(stopped, [], "the first grant has nothing to supersede")

        grant.hold(viaBookmark)
        XCTAssertEqual(stopped, ["reached-by-path.m4a"], "a new replay releases the previous grant…")
        XCTAssertEqual(grant.current, viaBookmark, "…and keeps the new one, or the job cannot open its file")
    }

    /// Re-holding the same URL must not stop-then-keep it: that would revoke the very grant being kept.
    @MainActor
    func testReHoldingTheSameFileDoesNotRevokeIt() {
        var stopped: [String] = []
        let grant = SingleScopedGrant { stopped.append($0.lastPathComponent) }
        grant.hold(viaPath)
        grant.hold(viaPath)
        XCTAssertEqual(stopped, [])
        XCTAssertEqual(grant.current, viaPath)
    }

    @MainActor
    func testReleasingLetsTheGrantGo() {
        var stopped: [String] = []
        let grant = SingleScopedGrant { stopped.append($0.lastPathComponent) }
        grant.hold(viaPath)
        grant.release()
        XCTAssertEqual(stopped, ["reached-by-path.m4a"])
        XCTAssertNil(grant.current)
        grant.release()
        XCTAssertEqual(stopped, ["reached-by-path.m4a"], "releasing twice must not stop a grant that is gone")
    }
}
