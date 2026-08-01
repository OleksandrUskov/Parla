import SwiftUI
import ParlaCore

/// One-time first-run sheet: what Parla does, privacy, pick a model (defaulting to the recommended
/// turbo tier so the first download isn't the heaviest), and a self-contained / on-device reassurance.
/// Presented from `ParlaApp` gated on `@AppStorage("didOnboard")`. View-only — it sets the model
/// choice through the existing `model.selectedModel` (UserDefaults-mirrored) and triggers NO download
/// (the lazy download-on-first-transcribe path stays the single download codepath).
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    let onFinish: () -> Void

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    step("text.bubble", L("onboarding.step1.title"), L("onboarding.step1.body"))
                    step("lock.shield", L("onboarding.privacy.title"), L("onboarding.privacy.body"))
                    modelStep(selection: $model.selectedModel, tiers: model.modelTiers)
                    readyStep
                }
                .padding(28)
            }
            Divider().overlay(.white.opacity(0.08))
            HStack {
                Spacer()
                Button(L("onboarding.start")) { onFinish() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(20)
        }
        .frame(width: 520, height: 580)
        .background(.ultraThinMaterial)
        .preferredColorScheme(.dark)
        .onAppear {
            // Preselect the recommended (turbo) tier so a fresh user doesn't inherit the heaviest model.
            if let rec = Onboarding.recommendedModel(from: model.modelTiers) { model.selectedModel = rec }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Parla").font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.gradient)
            Text(L("onboarding.title")).font(.title3).foregroundStyle(.secondary)
        }
    }

    private func step(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(Brand.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(body).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func modelStep(selection: Binding<String>, tiers: [ModelTier]) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "cpu").font(.title2).foregroundStyle(Brand.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 8) {
                Text(L("onboarding.model.title")).font(.headline)
                Text(L("onboarding.model.body")).font(.callout).foregroundStyle(.secondary)
                Picker("", selection: selection) {
                    ForEach(tiers) { tier in
                        Text(tier.estimate.isEmpty ? tier.title : "\(tier.title) · \(tier.estimate)").tag(tier.name)
                    }
                }
                .labelsHidden().pickerStyle(.radioGroup)
            }
        }
    }

    // A first-run reassurance beat: transcription is fully on-device and self-contained — nothing to install.
    // (Decoding is the in-process native decoder as of Phase 2c; no ffmpeg in the decode path.)
    private var readyStep: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "checkmark.seal").font(.title2).foregroundStyle(.green).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("onboarding.ready.title")).font(.headline)
                Text(L("onboarding.ready.body"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
