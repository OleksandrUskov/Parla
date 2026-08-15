import XCTest
@testable import ParlaCore

/// Bookmarks are what let a watched folder and a record's original file survive a relaunch. Under the App
/// Sandbox — required by the Mac App Store — a PLAIN bookmark resolves to a URL the app has no permission to
/// open, so both features would come back after a restart pointing at files they can no longer read.
///
/// The migration hazard is the reason these tests exist: every bookmark already stored in a user's history and
/// UserDefaults is plain, and a plain bookmark **cannot** be resolved with `.withSecurityScope` — Foundation
/// rejects it outright. Reading only the new way would break the watched folder and every record's source
/// locator for everyone who has used the app before today.
final class BookmarkTests: ParlaTestCase {

    private func tempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookmark-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: url)
        return url
    }

    /// A bookmark written today is security-scoped, and resolving it hands back a live grant. This works
    /// outside the sandbox too — measured, not assumed — which is why there is one code path and not two.
    func testABookmarkWrittenTodayCarriesItsGrant() throws {
        let file = try tempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let data = try XCTUnwrap(Bookmarks.make(for: file))
        let resolved = try XCTUnwrap(Bookmarks.resolve(data))
        defer { if resolved.scoped { resolved.url.stopAccessingSecurityScopedResource() } }

        XCTAssertEqual(resolved.url.standardizedFileURL.path, file.standardizedFileURL.path)
        XCTAssertTrue(resolved.scoped, "a freshly written bookmark should resolve as security-scoped")
    }

    /// THE compatibility guard. A plain bookmark — what every existing install has stored — must still resolve.
    /// Foundation refuses to read it with `.withSecurityScope` (NSCocoaErrorDomain 259, "isn't in the correct
    /// format"), so without the fallback this returns nil and the user's watched folder and re-transcribe
    /// silently stop working after an update.
    func testAPlainBookmarkFromAnOlderInstallStillResolves() throws {
        let file = try tempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let legacy = try file.bookmarkData()                        // exactly what older versions wrote
        // First, prove the hazard is real rather than imagined: the scoped read genuinely rejects this data.
        var stale = false
        XCTAssertNil(try? URL(resolvingBookmarkData: legacy, options: [.withSecurityScope],
                              relativeTo: nil, bookmarkDataIsStale: &stale),
                     "if this ever starts succeeding, the fallback below is no longer load-bearing")

        let resolved = try XCTUnwrap(Bookmarks.resolve(legacy),
                                     "an older install's bookmark must not stop resolving")
        XCTAssertEqual(resolved.url.standardizedFileURL.path, file.standardizedFileURL.path)
        XCTAssertFalse(resolved.scoped, "a plain bookmark grants nothing, so there is nothing to stop")
    }

    /// Garbage in, nil out — never a crash and never a half-resolved URL.
    func testUnreadableBookmarkDataResolvesToNothing() {
        XCTAssertNil(Bookmarks.resolve(Data("not a bookmark".utf8)))
        XCTAssertNil(Bookmarks.resolve(Data()))
    }

    /// The record locator uses the same layer, and reports `scoped` honestly so the caller can balance it.
    func testARecordResolvesItsSourceThroughTheSharedLayer() throws {
        let file = try tempFile()
        defer { try? FileManager.default.removeItem(at: file) }

        var item = TranscriptItem(sourceName: file.lastPathComponent, language: "ru", durationSec: 1,
                                  model: "m", text: "t", segments: [])
        item.sourcePath = nil                                        // force the bookmark branch
        item.sourceBookmark = makeSourceBookmark(file)

        guard case .found(let url, let scoped) = item.resolveSource() else {
            return XCTFail("the record should find its source through the bookmark")
        }
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        XCTAssertEqual(url.standardizedFileURL.path, file.standardizedFileURL.path)
    }

    /// A bookmark that resolves to a file which no longer exists must report "missing" — and must not leave a
    /// security-scoped grant open on the way out, since nobody is left to close it.
    func testAVanishedSourceIsMissingAndLeavesNoGrantOpen() throws {
        let file = try tempFile()
        var item = TranscriptItem(sourceName: file.lastPathComponent, language: "ru", durationSec: 1,
                                  model: "m", text: "t", segments: [])
        item.sourcePath = nil
        item.sourceBookmark = makeSourceBookmark(file)
        try FileManager.default.removeItem(at: file)                 // the user moved it to the bin

        XCTAssertEqual(item.resolveSource(), .missing)
        XCTAssertFalse(item.hasResolvableSource)
    }
}
