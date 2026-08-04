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

    /// DATA-LOSS GUARD: an in-flight copy (`<name>.part`) must never be picked up. The extension copies to `.part`
    /// and atomically renames when the bytes are all written; if the drain grabbed the `.part`, it would move a
    /// TRUNCATED file into the app container and then delete the user's only copy of what they shared. Also pins
    /// that an extension-less shared item (stored as `.dat`) IS picked up when its header is Ogg.
    func testPendingFilesSkipsInFlightPartsAndAcceptsOggDat() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("x".utf8).write(to: dir.appendingPathComponent("done.m4a"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("copying.m4a\(ShareInbox.partSuffix)"))
        try Data("OggS\u{01}\u{00}\u{00}\u{00}".utf8).write(to: dir.appendingPathComponent("voice.dat"))
        try Data("OggS\u{01}".utf8).write(to: dir.appendingPathComponent("half.ogg\(ShareInbox.partSuffix)"))

        let pending = ShareInbox.pendingFiles(in: dir).map(\.lastPathComponent)
        XCTAssertEqual(pending, ["done.m4a", "voice.dat"], "in-flight .part files must never be drained")
    }

    /// The stale-`.part` sweep removes abandoned copies but must NEVER touch one that could still be in flight.
    func testSweepStalePartsRemovesOldOnly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fresh = dir.appendingPathComponent("fresh.m4a\(ShareInbox.partSuffix)")
        let old = dir.appendingPathComponent("old.m4a\(ShareInbox.partSuffix)")
        let keep = dir.appendingPathComponent("real.m4a")
        for u in [fresh, old, keep] { try Data("x".utf8).write(to: u) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -172_800)], ofItemAtPath: old.path)

        ShareInbox.sweepStaleParts(in: dir)
        let left = Set((try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)).map(\.lastPathComponent))
        XCTAssertTrue(left.contains(fresh.lastPathComponent), "a possibly-in-flight .part must be kept")
        XCTAssertFalse(left.contains(old.lastPathComponent), "an abandoned .part must be swept")
        XCTAssertTrue(left.contains(keep.lastPathComponent), "real files untouched")
    }

    func testPendingFilesEmptyDirIsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(ShareInbox.pendingFiles(in: dir).isEmpty)
    }

    /// `toRemove` must delete ONLY inbox files that copyIntoContainer actually copied — a
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
