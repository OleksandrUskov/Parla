import XCTest
@testable import Parla_iOS

/// iOS-port P1.4b — the security-scoped import copy. The full import→transcribe→text flow is device-only
/// (WhisperKit text inference crashes on the sim), but the copy-into-container step — the load-bearing sandbox
/// bit — is verifiable here: a local temp file stands in for a picked URL (`startAccessingSecurityScopedResource`
/// returns false for a non-scoped URL, but the copy still runs), so this pins the copy + naming + container path.
final class ImportCoordinatorTests: XCTestCase {

    func testCopyIntoContainerPreservesNameAndContent() throws {
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).ogg")
        let bytes = Data("OggS-\(UUID().uuidString)".utf8)
        try bytes.write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let out = ImportCoordinator.copyIntoContainer([src])
        defer { out.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }

        XCTAssertEqual(out.count, 1)
        let dest = try XCTUnwrap(out.first)
        XCTAssertEqual(dest.lastPathComponent, src.lastPathComponent, "original filename + extension preserved")
        XCTAssertTrue(dest.path.contains("/Parla/imports/"), "copied into the app container")
        XCTAssertEqual(try Data(contentsOf: dest), bytes, "content copied verbatim")
    }

    func testEmptyInputYieldsNothing() {
        XCTAssertTrue(ImportCoordinator.copyIntoContainer([]).isEmpty)
    }
}
