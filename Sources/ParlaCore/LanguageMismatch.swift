import Foundation

/// An offer to fix the single most expensive silent mistake a user can make: transcribing with the wrong
/// speech language pinned. Measured on identical audio, a wrong pin cost **49.85% word errors against 5.57%** —
/// roughly nine times as many — and the app said nothing at all. The user just got a bad transcript and had no
/// way to know why.
public struct LanguageSuggestion: Sendable, Equatable, Identifiable {
    public let id: UUID              // the transcript this is about
    public let pinned: String        // what the user had selected
    public let detected: String      // what the model heard
    public let confidence: Double    // the model's probability for `detected`, 0...1

    public init(id: UUID, pinned: String, detected: String, confidence: Double) {
        self.id = id; self.pinned = pinned; self.detected = detected; self.confidence = confidence
    }
}

public enum LanguageMismatch {

    /// How sure the model must be before we question the user's own setting.
    ///
    /// **Chosen from data, not taste.** Running detection over the owner's real notes and a synthetic set with
    /// known languages: a genuine mismatch — Russian speech transcribed with Ukrainian pinned, the 49.85%-error
    /// case — was detected at **0.999**. The only false alarm in the set, a genuinely Ukrainian note from a poor
    /// recording, sat at **0.63**. 0.85 separates them with room on both sides.
    ///
    /// Erring high is the right direction here: a missed nudge costs the user nothing they don't already have,
    /// while a wrong nudge tells someone their own language is wrong — on their own voice. That is worse than
    /// silence, so this is deliberately not tuned for recall.
    public static let minConfidence = 0.85

    /// Should we offer to switch? Pure, so the policy is testable without a model, an app, or audio.
    public static func shouldSuggest(pinned: String, detected: String, confidence: Double) -> Bool {
        let want = languagePrimarySubtag(pinned)
        guard !want.isEmpty else { return false }        // Auto: the model already picked, there is nothing to fix
        let got = languagePrimarySubtag(detected)
        guard !got.isEmpty, got != want else { return false }
        return confidence >= minConfidence
    }

    /// The suggestion for a finished transcript, or nil when there is nothing worth saying.
    public static func suggestion(for id: UUID, pinned: String, heard: HeardLanguage?) -> LanguageSuggestion? {
        guard let heard, shouldSuggest(pinned: pinned, detected: heard.language, confidence: heard.confidence)
        else { return nil }
        return LanguageSuggestion(id: id, pinned: languagePrimarySubtag(pinned),
                                  detected: languagePrimarySubtag(heard.language), confidence: heard.confidence)
    }
}
