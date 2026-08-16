import XCTest
@testable import ParlaCore

/// A Shortcut supplies the filename that an in-memory `IntentFile` is written under. That string is INPUT.
/// `appendingPathComponent` does not resolve `..`, so `../../../foo` escaped the temporary directory and wrote
/// wherever the app could reach — which, in an unsandboxed app, is wherever the user can. Live defect, not a Mac
/// App Store one: sandboxing would only mask it by having the write denied.
final class IntentFileNameTests: XCTestCase {

    /// The escape itself, in the forms a hostile or careless Shortcut would produce.
    func testNoInputCanEscapeTheTemporaryDirectory() {
        for hostile in ["../../../etc/passwd", "../evil.wav", "/etc/passwd", "a/b/c.wav",
                        "..", ".", "", "../..", "/", "//",
                        // Found by the review: a single leading-dot strip turned these back into "..".
                        "...", ".../", "a/...", "/...", "....", ".."] {
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
        XCTAssertTrue(IntentFileName.safe("...").hasPrefix("parla-intent-"), "every leading dot must go, not one")
    }
}

/// The first fix landed in the macOS intent only, while the iOS twin kept writing the raw filename — same
/// defect, same day, half fixed, and on iOS it could overwrite the user's history.json. A shared sanitiser is
/// necessary but not sufficient: what actually prevents the recurrence is nobody being able to bypass it.
final class IntentSanitiserReachTests: ParlaLogicTestCase {

    func testNeitherPlatformWritesAnIntentFileUnderAnUnsanitisedName() throws {
        for path in ["Sources/Parla/ParlaIntents.swift", "apps/ios/Sources/ParlaIntents.swift"] {
            let text = try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }   // comments prove nothing
                .joined(separator: "\n")
            guard code.contains("file.data.write(to:") else { continue }   // this platform materialises nothing
            XCTAssertTrue(code.contains("IntentFileName.safe(file.filename)"),
                          "\(path) materialises an intent file without sanitising its name")
            XCTAssertFalse(code.contains("appendingPathComponent(name)"),
                           "\(path) still joins a raw filename onto a directory")
        }
    }
}
