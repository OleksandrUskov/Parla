import XCTest
@testable import ParlaCore

/// A fresh install's UI language. It used to be English unconditionally; the App Store listing advertises
/// Russian and Ukrainian, so that made the listing contradict itself on the first screen for the audience this
/// app is actually for. Anyone with a stored choice is untouched — only the first launch consults the system.
// `ParlaLogicTestCase` rather than `ParlaTestCase`: it carries `repoRoot`, which the source scan needs.
final class FirstLaunchLanguageTests: ParlaLogicTestCase {

    func testASystemLanguageWeShipIsTheOneAFreshInstallOpensIn() {
        XCTAssertEqual(UILanguage.best(forSystemCode: "ru"), .ru)
        XCTAssertEqual(UILanguage.best(forSystemCode: "uk"), .uk)
        XCTAssertEqual(UILanguage.best(forSystemCode: "en"), .en)
    }

    /// The whole point of the fallback: a language with no catalogue must not render as raw keys.
    func testASystemLanguageWeDoNotShipFallsBackToEnglish() {
        for code in ["de", "fr", "zh", "ja", "pl", ""] {
            XCTAssertEqual(UILanguage.best(forSystemCode: code), .en, "\(code) should fall back")
        }
        XCTAssertEqual(UILanguage.best(forSystemCode: nil), .en)
    }

    /// The platform hands back a bare lowercase code today, but a region- or case-qualified one reaching here
    /// must not silently become English — that failure would look like "the app just ignores my language".
    func testRegionAndCaseDoNotCostTheUserTheirLanguage() {
        XCTAssertEqual(UILanguage.best(forSystemCode: "ru_RU"), .ru)
        XCTAssertEqual(UILanguage.best(forSystemCode: "uk-UA"), .uk)
        XCTAssertEqual(UILanguage.best(forSystemCode: "RU"), .ru)
        XCTAssertEqual(UILanguage.best(forSystemCode: "en-GB"), .en)
    }

    /// Every case of the enum must be reachable from some system code, or a shipped catalogue is dead weight.
    func testEveryShippedLanguageIsReachableFromASystemCode() {
        for lang in UILanguage.allCases {
            XCTAssertEqual(UILanguage.best(forSystemCode: lang.code), lang,
                           "\(lang.code) ships a catalogue nothing can select")
        }
    }

    /// The mapping being right is worthless if nothing uses it, and "simplify that back to `.en`" is a one-word
    /// edit no behaviour test would catch — this project has already shipped exactly that shape once
    /// (`startingStore: Bool = true`, which left every suite green while the store never started).
    ///
    /// Comments are stripped before matching, because a scan that passes on a commented-out line has caught the
    /// project before; and the assignment is COUNTED, so a rename that makes the scan find nothing fails here
    /// rather than passing silently.
    func testTheFreshInstallDefaultIsActuallyWiredIn() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent("Sources/ParlaCore/AppModel.swift"),
                                encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let assignments = code.filter { $0.contains("uiLanguage = UILanguage(rawValue:") }

        XCTAssertEqual(assignments.count, 1,
                       "expected exactly one place that decides the UI language at load; found \(assignments.count)")
        XCTAssertTrue(assignments[0].contains(".systemDefault"),
                      "the fresh-install language is no longer taken from the system: \(assignments[0])")
    }
}
