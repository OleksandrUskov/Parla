import XCTest
@testable import ParlaCore

/// Repro-gate for a bug that silently cost real users a whole feature: the FoundationModels language check
/// consulted a HARDCODED list before the model's own live list, so it could only ever *narrow* what Apple
/// actually supports. Every language Apple added after that line was written — Danish, Dutch, Norwegian,
/// Swedish, Turkish — was reported "your language isn't supported" to people whose model handled it fine.
///
/// These run on any machine: the decision is a pure function, so no Apple Intelligence, no macOS 26, no device.
final class FoundationModelsLanguageGateTests: XCTestCase {

    /// THE regression. "da" is deliberately NOT in `knownSupportedLanguages`; if the static list is ever
    /// consulted as a gate again, this goes red.
    func testALanguageMissingFromTheStaticListIsStillReadyWhenTheModelSupportsIt() {
        XCTAssertFalse(FoundationModelsService.knownSupportedLanguages.contains("da"),
                       "precondition: the static list is stale by design — it must not be the gate")
        XCTAssertEqual(
            FoundationModelsService.decide(modelAvailable: true, liveSupportedSubtags: ["en", "da"], language: "da"),
            .ready,
            "the model's live set is the source of truth — a stale static list must never veto it")
    }

    func testRegionTagsAreMatchedByPrimarySubtag() {
        for tag in ["da-DK", "DA", "da_DK"] {
            XCTAssertEqual(
                FoundationModelsService.decide(modelAvailable: true, liveSupportedSubtags: ["da"], language: tag),
                .ready, "\(tag) should resolve to the 'da' primary subtag")
        }
    }

    /// The other direction still has to hold — this is what keeps Russian/Ukrainian on the MLX/extractive path.
    func testALanguageTheModelDoesNotSupportIsReportedUnsupported() {
        for lang in ["ru", "uk", "ru-RU"] {
            XCTAssertEqual(
                FoundationModelsService.decide(modelAvailable: true, liveSupportedSubtags: ["en", "de"], language: lang),
                .languageUnsupported, "\(lang) must fall through to the MLX / extractive path")
        }
    }

    /// Apple Intelligence off / device ineligible / model still downloading outranks the language question:
    /// telling the user "your language is unsupported" there would be a lie.
    func testAnUnavailableModelReportsModelUnavailableNotLanguageUnsupported() {
        XCTAssertEqual(
            FoundationModelsService.decide(modelAvailable: false, liveSupportedSubtags: ["en"], language: "en"),
            .modelUnavailable)
        XCTAssertEqual(
            FoundationModelsService.decide(modelAvailable: false, liveSupportedSubtags: [], language: "ru"),
            .modelUnavailable)
    }

    /// An empty live set (model present but reporting nothing) must not be read as "everything is ready".
    func testAnEmptyLiveSetSupportsNothing() {
        XCTAssertEqual(
            FoundationModelsService.decide(modelAvailable: true, liveSupportedSubtags: [], language: "en"),
            .languageUnsupported)
    }

    /// The static set survives only as a LOWER BOUND for callers that cannot ask the framework (below the OS
    /// floor, Apple Intelligence off). English must stay in it — it is what makes the backend worth shipping —
    /// and Russian/Ukrainian must stay out of it.
    func testStaticListRemainsAConservativeLowerBound() {
        XCTAssertTrue(FoundationModelsService.knownSupportedLanguages.contains("en"))
        XCTAssertFalse(FoundationModelsService.knownSupportedLanguages.contains("ru"))
        XCTAssertFalse(FoundationModelsService.knownSupportedLanguages.contains("uk"))
    }
}
