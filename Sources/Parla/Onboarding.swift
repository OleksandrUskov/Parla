import Foundation
import ParlaCore

/// Pure decision logic for first-run onboarding + the first-compile reassurance. View code reads these;
/// keeping them free of `@AppStorage`/`AppModel` makes them unit-testable in the pure-logic suite
/// (no UserDefaults, no UI), matching the project's test-seam discipline.
enum Onboarding {
    /// Show the onboarding sheet only on a genuinely fresh start: never onboarded AND no existing
    /// history. An upgrading user who already has transcripts knows the app → skip the sheet.
    static func shouldShowOnboarding(didOnboard: Bool, hasHistory: Bool) -> Bool {
        !didOnboard && !hasHistory
    }

    /// Show the "first compile is one-time, cached afterwards" caption only while a model is compiling
    /// for the very first time — it quietly disappears once `.loadingModel` really is fast.
    static func shouldShowFirstCompileHint(isLoadingModel: Bool, didCompileModel: Bool) -> Bool {
        isLoadingModel && !didCompileModel
    }

    /// The model a fresh user should start on: the tier flagged `recommended` (turbo — the best
    /// quality/speed balance), else the first available. Keeps the first download off the heaviest model.
    static func recommendedModel(from tiers: [ModelTier]) -> String? {
        (tiers.first(where: { $0.recommended }) ?? tiers.first)?.name
    }
}
