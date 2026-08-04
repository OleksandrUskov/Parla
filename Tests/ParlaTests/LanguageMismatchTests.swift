import XCTest
@testable import ParlaCore

/// The wrong-language nudge. The thresholds here are not taste — they come from running detection over real
/// notes and a known-language synthetic set, so the tests use those measured values as their fixtures.
final class LanguageMismatchTests: ParlaTestCase {

    /// THE case this feature exists for, with its real numbers: Russian speech transcribed with Ukrainian
    /// pinned. Measured 49.85% word errors versus 5.57%, and the detector called it Russian at 0.999.
    func testTheMeasuredRealMismatchIsSuggested() {
        let s = LanguageMismatch.suggestion(for: UUID(), pinned: "uk",
                                            heard: HeardLanguage(language: "ru", confidence: 0.999))
        XCTAssertEqual(s?.pinned, "uk")
        XCTAssertEqual(s?.detected, "ru")
    }

    /// The measured FALSE alarm: a genuinely Ukrainian note, poorly recorded, that detection called Russian at
    /// 0.63. Telling that user their own language is wrong is worse than saying nothing, so it must stay quiet.
    func testTheMeasuredFalseAlarmStaysQuiet() {
        XCTAssertNil(LanguageMismatch.suggestion(for: UUID(), pinned: "uk",
                                                 heard: HeardLanguage(language: "ru", confidence: 0.63)))
    }

    func testConfidenceThresholdIsInclusiveAtTheBoundary() {
        XCTAssertFalse(LanguageMismatch.shouldSuggest(pinned: "uk", detected: "ru",
                                                      confidence: LanguageMismatch.minConfidence - 0.001))
        XCTAssertTrue(LanguageMismatch.shouldSuggest(pinned: "uk", detected: "ru",
                                                     confidence: LanguageMismatch.minConfidence))
    }

    /// On Auto there is nothing to correct — the model chose the language itself, so questioning it would be
    /// questioning its own answer.
    func testAutoIsNeverSecondGuessed() {
        XCTAssertFalse(LanguageMismatch.shouldSuggest(pinned: "", detected: "ru", confidence: 1.0))
        XCTAssertNil(LanguageMismatch.suggestion(for: UUID(), pinned: "",
                                                 heard: HeardLanguage(language: "ru", confidence: 1.0)))
    }

    func testAgreementIsSilentEvenAtFullConfidence() {
        XCTAssertFalse(LanguageMismatch.shouldSuggest(pinned: "ru", detected: "ru", confidence: 1.0))
    }

    /// Region tags must not read as a mismatch: "ru-RU" pinned and "ru" heard is the same language.
    func testRegionTagsCompareByPrimarySubtag() {
        XCTAssertFalse(LanguageMismatch.shouldSuggest(pinned: "ru-RU", detected: "ru", confidence: 1.0))
        XCTAssertFalse(LanguageMismatch.shouldSuggest(pinned: "en", detected: "en-US", confidence: 1.0))
        XCTAssertTrue(LanguageMismatch.shouldSuggest(pinned: "uk-UA", detected: "ru-RU", confidence: 0.95))
    }

    /// No detection (streaming dictation, an older engine, a detection failure) must never produce a nudge.
    func testNoHeardLanguageMeansNoSuggestion() {
        XCTAssertNil(LanguageMismatch.suggestion(for: UUID(), pinned: "uk", heard: nil))
        XCTAssertFalse(LanguageMismatch.shouldSuggest(pinned: "uk", detected: "", confidence: 1.0))
    }

    /// The suggestion carries normalised subtags, because the UI turns them into language NAMES.
    func testSuggestionNormalisesToPrimarySubtags() {
        let s = LanguageMismatch.suggestion(for: UUID(), pinned: "UK-ua",
                                            heard: HeardLanguage(language: "RU-ru", confidence: 0.99))
        XCTAssertEqual(s?.pinned, "uk")
        XCTAssertEqual(s?.detected, "ru")
    }
}
