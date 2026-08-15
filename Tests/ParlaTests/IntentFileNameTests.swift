import XCTest
@testable import Parla

/// A Shortcut supplies the filename that an in-memory `IntentFile` is written under. That string is INPUT.
/// `appendingPathComponent` does not resolve `..`, so `../../../foo` escaped the temporary directory and wrote
/// wherever the app could reach — which, in an unsandboxed app, is wherever the user can. Live defect, not a Mac
/// App Store one: sandboxing would only mask it by having the write denied.
final class IntentFileNameTests: XCTestCase {

    /// The escape itself, in the forms a hostile or careless Shortcut would produce.
    func testNoInputCanEscapeTheTemporaryDirectory() {
        for hostile in ["../../../etc/passwd", "../evil.wav", "/etc/passwd", "a/b/c.wav",
                        "..", ".", "", "../..", "/", "//"] {
            let safe = IntentFileName.safe(hostile)
            XCTAssertFalse(safe.contains("/"), "‘\(hostile)’ produced a path, not a name: \(safe)")
            XCTAssertNotEqual(safe, "..")
            XCTAssertNotEqual(safe, ".")
            XCTAssertFalse(safe.isEmpty)
            // The decisive property: joined onto a directory, it stays inside it.
            let base = URL(fileURLWithPath: "/tmp/parla-test", isDirectory: true)
            let joined = base.appendingPathComponent(safe).standardizedFileURL
            XCTAssertTrue(joined.path.hasPrefix(base.standardizedFileURL.path + "/"),
                          "‘\(hostile)’ escaped to \(joined.path)")
        }
    }

    /// …while an ordinary name is left alone, extension included — the funnel routes on it.
    func testAnOrdinaryFilenameSurvivesUntouched() {
        XCTAssertEqual(IntentFileName.safe("voice message.ogg"), "voice message.ogg")
        XCTAssertEqual(IntentFileName.safe("Запись 2026-08-15.m4a"), "Запись 2026-08-15.m4a")
        XCTAssertEqual(IntentFileName.safe("../../notes.mp3"), "notes.mp3", "the name survives, the path does not")
    }

    /// An empty or hidden-file name gets a generated one rather than becoming a dotfile in temp.
    func testAHiddenOrEmptyNameBecomesAGeneratedOne() {
        XCTAssertFalse(IntentFileName.safe(".hidden").hasPrefix("."))
        XCTAssertTrue(IntentFileName.safe("").hasPrefix("parla-intent-"))
        XCTAssertTrue(IntentFileName.safe(".").hasPrefix("parla-intent-"))
    }
}
