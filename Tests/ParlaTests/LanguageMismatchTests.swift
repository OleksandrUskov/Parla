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

/// The nudge's LIFETIME, which the adversarial review found to be the dangerous part — not the maths.
/// A raw `languageSuggestion` is a global slot: it survived selecting another note (so on macOS the strip floated
/// above whatever was open and its button re-transcribed a DIFFERENT note, wiping that note's edits) and it
/// survived deleting the note it was about (a permanent strip with a dead button).
@MainActor
final class LanguageSuggestionLifetimeTests: ParlaTestCase {

    private func model(with items: [TranscriptItem]) -> AppModel {
        let m = AppModel(engine: NoopEngineForNudge(), ai: NoopAIService(), embedder: NoopEmbedder())
        m.history = items
        m.isProUser = { true }
        return m
    }

    private func note(_ text: String = "текст", dur: Double = 30) -> TranscriptItem {
        TranscriptItem(sourceName: "n.ogg", language: "uk", durationSec: dur,
                       model: "openai_whisper-tiny", text: text, segments: [])
    }

    func testSuggestionShowsOnlyForTheNoteItIsAbout() {
        let a = note(), b = note()
        let m = model(with: [a, b])
        m.selection = a.id
        m.languageSuggestion = LanguageSuggestion(id: a.id, pinned: "uk", detected: "ru", confidence: 0.99)
        XCTAssertNotNil(m.activeLanguageSuggestion, "shown while its own note is open")

        m.selection = b.id
        XCTAssertNil(m.activeLanguageSuggestion,
                     "must NOT float above another note — its button re-transcribes the note it was raised for")
    }

    func testSuggestionDisappearsWithTheDeletedNote() {
        let a = note()
        let m = model(with: [a])
        m.selection = a.id
        m.languageSuggestion = LanguageSuggestion(id: a.id, pinned: "uk", detected: "ru", confidence: 0.99)
        XCTAssertNotNil(m.activeLanguageSuggestion)

        m.history = []
        XCTAssertNil(m.activeLanguageSuggestion, "a strip about a note that no longer exists has a dead button")
    }

    /// The accept path used to commit two irreversible things — the app-wide persisted language, and consuming
    /// the offer — BEFORE calling `retranscribe`, which is free to decline. Mid-batch that re-pinned the language
    /// for files still to be transcribed, while the note the nudge was about was never re-run.
    func testAcceptingWhileBusyChangesNothingAndKeepsTheOffer() {
        let a = note()
        let m = model(with: [a])
        m.selection = a.id
        m.language = "uk"
        m.languageSuggestion = LanguageSuggestion(id: a.id, pinned: "uk", detected: "ru", confidence: 0.99)
        m.recordingStartedAt = Date()                     // something IS running → retranscribe would decline
        XCTAssertTrue(m.isBusy)
        XCTAssertFalse(m.canApplyLanguageSuggestion)

        m.applyLanguageSuggestion()
        XCTAssertEqual(m.language, "uk", "the speech language must NOT be re-pinned when nothing will be re-run")
        XCTAssertNotNil(m.activeLanguageSuggestion, "…and the offer must survive so it can be accepted later")
    }

    /// A free user over the length cap: the offer must lead to the paywall, not to a silently re-pinned language
    /// and a vanished suggestion.
    func testAcceptingAGatedNoteShowsThePaywallAndKeepsEverythingElseIntact() {
        let a = note(dur: 20 * 60)
        let m = model(with: [a])
        m.selection = a.id
        m.language = "uk"
        m.isProUser = { false }
        m.languageSuggestion = LanguageSuggestion(id: a.id, pinned: "uk", detected: "ru", confidence: 0.99)

        m.applyLanguageSuggestion()
        XCTAssertEqual(m.language, "uk", "language must not flip for a re-run that cannot happen")
        XCTAssertNotNil(m.activeLanguageSuggestion)
        XCTAssertNotNil(m.paywallReason, "the reason it declined should be visible, not silent")
    }

    /// Language names go into sentences, so they must arrive in the form the sentence expects — «на русском»,
    /// not «на Русский». Capitalising them was wrong in both Slavic UI languages.
    func testLanguageNamesAreNotCapitalised() {
        let m = model(with: [])
        m.uiLanguage = .ru
        XCTAssertEqual(m.languageDisplayName("ru"), m.languageDisplayName("ru").lowercased(),
                       "Slavic language names are lowercase mid-sentence")
        m.uiLanguage = .uk
        XCTAssertEqual(m.languageDisplayName("uk"), m.languageDisplayName("uk").lowercased())
    }
}

private struct NoopEngineForNudge: TranscribingEngine {
    func ensureLoaded(model: String, progress: @Sendable @escaping (ModelLoad) -> Void) async throws {}
    func transcribe(wavPath: String, language: String?, model: String, translate: Bool) async throws -> EngineResult {
        EngineResult(text: "", language: "", segments: [], duration: 0)
    }
    func transcribe(samples: [Float], language: String?, model: String) async throws -> EngineResult {
        EngineResult(text: "", language: "", segments: [], duration: 0)
    }
    func deleteModel(_ name: String) async throws {}
}
