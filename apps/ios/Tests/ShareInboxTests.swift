import XCTest
import ParlaCore
@testable import Parla_iOS

/// the Share-Extension → app handoff. The end-to-end share flow is device-only (the extension
/// process + the provisioned App Group), but the app-side drain LOGIC is pure filesystem work, verifiable on the
/// sim with an injected inbox dir — a repro-gate for the pickup: exactly what would fail if a future edit
/// regressed the filtering or ordering.
final class ShareInboxTests: XCTestCase {

    func testPendingFilesFiltersToAudioVideoSortedSkippingHidden() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for name in ["b.m4a", "a.ogg", "c.mp4", "note.txt", "img.png", ".hidden.ogg"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }

        let pending = ShareInbox.pendingFiles(in: dir).map(\.lastPathComponent)
        XCTAssertEqual(pending, ["a.ogg", "b.m4a", "c.mp4"], "audio/video only, name-sorted, hidden skipped")
    }

    func testPendingFilesEmptyDirIsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(ShareInbox.pendingFiles(in: dir).isEmpty)
    }

    /// Full-review D2/S2 + D8: `toRemove` must delete ONLY inbox files that copyIntoContainer actually copied — a
    /// file it skipped (returned no container URL for) is the user's only copy and MUST be kept to retry. This pins
    /// the data-loss guard that used to be "remove pending regardless".
    func testToRemoveKeepsFilesThatFailedToCopy() {
        let inbox = URL(fileURLWithPath: "/inbox")
        let a = inbox.appendingPathComponent("a.ogg")
        let b = inbox.appendingPathComponent("b.ogg")   // this one "failed to copy"
        let c = inbox.appendingPathComponent("c.m4a")
        // copyIntoContainer returned container copies for a and c only (b skipped); names are preserved.
        let container = [URL(fileURLWithPath: "/imports/x/a.ogg"),
                         URL(fileURLWithPath: "/imports/y/c.m4a")]

        let remove = ShareInbox.toRemove(pending: [a, b, c], containerURLs: container).map(\.lastPathComponent)
        XCTAssertEqual(remove.sorted(), ["a.ogg", "c.m4a"], "only the copied files are removed")
        XCTAssertFalse(remove.contains("b.ogg"), "a file that failed to copy stays to retry — never lost")
    }

    func testToRemoveEmptyWhenNothingCopied() {
        let a = URL(fileURLWithPath: "/inbox/a.ogg")
        XCTAssertTrue(ShareInbox.toRemove(pending: [a], containerURLs: []).isEmpty,
                      "if no copy succeeded, delete nothing — keep every source to retry")
    }

    /// The real App Group container needs the provisioned entitlement — present on device, may be absent on an
    /// unsigned sim build. Informative (skips rather than fails) so the run TELLS us whether the sim resolves it.
    func testAppGroupContainerResolution() throws {
        guard let url = ShareInbox.containerURL() else {
            throw XCTSkip("App Group container not provisioned in this (unsigned sim) build — device-only")
        }
        XCTAssertFalse(url.path.isEmpty)
        // The inbox is creatable under it.
        XCTAssertNotNil(ShareInbox.inboxURL())
    }
}
