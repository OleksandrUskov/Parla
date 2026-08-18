import XCTest
import ParlaCore
@testable import Parla_iOS

/// the security-scoped import copy. The full import→transcribe→text flow is device-only
/// (WhisperKit text inference crashes on the sim), but the copy-into-container step — the load-bearing sandbox
/// bit — is verifiable here: a local temp file stands in for a picked URL (`startAccessingSecurityScopedResource`
/// returns false for a non-scoped URL, but the copy still runs), so this pins the copy + naming + container path.
final class ImportCoordinatorTests: XCTestCase {

    func testCopyIntoContainerPreservesNameAndContent() throws {
        // A name the USER would have: no Share-Extension stamp, so nothing about it should change. (The old
        // fixture happened to be shaped exactly like a stamped name, which is why this test caught the strip.)
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice \(Int.random(in: 1000...9999)).ogg")
        let bytes = Data("OggS-\(UUID().uuidString)".utf8)
        try bytes.write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let out = ImportCoordinator.copyIntoContainer([src])
        defer { out.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }

        XCTAssertEqual(out.count, 1)
        let dest = try XCTUnwrap(out.first)
        XCTAssertEqual(dest.lastPathComponent, src.lastPathComponent, "original filename + extension preserved")
        // Against the imports ROOT, not a hardcoded folder name: that directory is now named after the bundle
        // identifier, so the app's data can be found by the sandbox container migration.
        XCTAssertTrue(dest.path.hasPrefix(AppModel.importsRoot.standardizedFileURL.path + "/"),
                      "copied into the app container's imports root, got \(dest.path)")
        XCTAssertEqual(try Data(contentsOf: dest), bytes, "content copied verbatim")
    }

    /// The Share Extension stamps a UUID into every filename it writes into its flat inbox, and that name used
    /// to reach the note: every shared note was titled `voice-<36 hex characters>.ogg`, and long-audio resume
    /// could never match a re-share, because a job is identified partly by its source's name. The per-import
    /// UUID DIRECTORY already gives collision-freedom, so the file keeps the name the user actually shared.
    func testASharedFilesUniquenessStampIsStrippedFromTheCopy() throws {
        let stamped = FileManager.default.temporaryDirectory
            .appendingPathComponent("Voice message-\(UUID().uuidString).ogg")
        try Data("OggS".utf8).write(to: stamped)
        defer { try? FileManager.default.removeItem(at: stamped) }

        let out = ImportCoordinator.copyIntoContainer([stamped])
        defer { out.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }

        XCTAssertEqual(try XCTUnwrap(out.first).lastPathComponent, "Voice message.ogg")
    }

    func testEmptyInputYieldsNothing() {
        XCTAssertTrue(ImportCoordinator.copyIntoContainer([]).isEmpty)
    }
}
