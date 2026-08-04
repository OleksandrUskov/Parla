import SwiftUI

/// The wrong-language nudge, shared by both apps.
///
/// This is the cheapest large win the app has: a wrong speech-language pin measured **49.85% word errors
/// against 5.57%** on identical audio — about nine times as many — while the app said nothing at all. The user
/// simply got a bad transcript and no explanation. The model already knows; it was never asked.
///
/// Deliberately a quiet inline strip and not an alert: it appears only above a measured confidence, it never
/// blocks reading, and it never rewrites anything by itself. Being wrong here means telling someone their own
/// language is wrong, on their own voice, so the design leans towards being easy to ignore.
public struct LanguageNudgeView: View {
    @Environment(AppModel.self) private var model
    let suggestion: LanguageSuggestion

    public init(suggestion: LanguageSuggestion) { self.suggestion = suggestion }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "character.bubble")
                .foregroundStyle(Brand.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(Lf("language.nudge.title", model.languageDisplayName(suggestion.detected)))
                    .font(.callout.weight(.medium))
                Text(Lf("language.nudge.body", model.languageDisplayName(suggestion.pinned)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(Lf("language.nudge.switch", model.languageDisplayName(suggestion.detected))) {
                model.applyLanguageSuggestion()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button {
                model.dismissLanguageSuggestion()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(L("language.nudge.dismiss"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Brand.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.accent.opacity(0.25)))
    }
}

extension View {
    /// Attach the nudge above `self`. A no-op while there is nothing to suggest, so call sites stay unconditional.
    public func languageNudge(_ model: AppModel) -> some View {
        VStack(spacing: 10) {
            if let suggestion = model.languageSuggestion {
                LanguageNudgeView(suggestion: suggestion)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            self
        }
        .animation(.easeInOut(duration: 0.2), value: model.languageSuggestion)
    }
}
