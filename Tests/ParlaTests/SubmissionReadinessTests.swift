import XCTest
@testable import ParlaCore

/// Claims about the SUBMITTED bundle that no runtime assertion can reach.
///
/// `build_app.sh` writes the macOS Info.plist after xcodebuild has already run, so there is no way to obtain it
/// without a full release build — which is exactly why these went unnoticed. Scanned in the source instead,
/// with comment lines stripped, because a substring test that matches inside a comment passes forever while the
/// thing it guards is gone; that happened in this repo the same week.
final class SubmissionReadinessTests: ParlaLogicTestCase {

    private func code(of path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("<!--") }
            .joined(separator: "\n")
    }

    /// The keys App Store Connect needs. Without the encryption declaration every single upload stops in
    /// "Missing Compliance" until it is answered by hand — an avoidable delay on every release, forever.
    func testTheMacBundleDeclaresWhatASubmissionRequires() throws {
        let script = try code(of: "build_app.sh")
        for key in ["ITSAppUsesNonExemptEncryption", "NSHumanReadableCopyright",
                    "LSApplicationCategoryType", "LSMinimumSystemVersion", "NSMicrophoneUsageDescription"] {
            XCTAssertTrue(script.contains("<key>\(key)</key>"), "the macOS Info.plist no longer declares \(key)")
        }
        // …and iOS, which already had it, must keep it.
        let ios = try code(of: "apps/ios/Parla-iOS-Info.plist")
        XCTAssertTrue(ios.contains("ITSAppUsesNonExemptEncryption"))
    }

    /// Apple's SF Symbols licence forbids using the symbols — or anything confusingly similar — in an app icon.
    /// The macOS icon was DRAWN from `waveform` for months: a rejection, not a matter of taste. It now
    /// rasterises the project's own artwork, and this is what stops that being quietly undone.
    func testTheAppIconIsRealArtworkAndNotAnSFSymbol() throws {
        let generator = try code(of: "make_icon.swift")
        XCTAssertFalse(generator.contains("systemSymbolName"),
                       "the app icon is being drawn from an SF Symbol again — Apple's licence forbids that")
        XCTAssertTrue(generator.contains("AppIcon-1024.png"), "the generator must read the real artwork")

        let master = repoRoot.appendingPathComponent("apps/ios/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: master.path),
                      "the master artwork is missing — both platforms' icons come from this one file")
        let bytes = (try? Data(contentsOf: master))?.count ?? 0
        XCTAssertGreaterThan(bytes, 10_000, "the master artwork looks like a placeholder")
    }

    /// A build that loses its icon must FAIL, not print a tick over a faceless bundle. Three steps used to
    /// swallow their errors — `swift`, `sips` and `iconutil` — and the app is rejected without an icon.
    func testTheIconStepCannotFailSilently() throws {
        let script = try code(of: "build_app.sh")
        guard let iconBlock = script.range(of: "Generating the icon")
            .map({ String(script[$0.lowerBound...].prefix(1400)) }) else {
            return XCTFail("the icon step moved — this guard is now blind")
        }
        XCTAssertFalse(iconBlock.contains("iconutil -c icns \"$ISET\" -o Resources/AppIcon.icns >/dev/null 2>&1 || true"),
                       "iconutil failure is being swallowed again")
        XCTAssertTrue(iconBlock.contains("icon render failed"), "a failed render must abort the build")
        XCTAssertTrue(iconBlock.contains("AppIcon.icns is empty"), "an empty icns must abort the build")
    }
}
