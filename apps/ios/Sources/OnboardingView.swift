import SwiftUI
import ParlaCore

/// First-run intro (iOS-port P1.4l) — what Parla does + the on-device privacy promise, shown once before the
/// model-download screen. Uses iOS-neutral copy (`onboarding.ios.*`; the macOS `onboarding.*` strings say
/// "Mac" / "drag"). The macOS model-picker + ffmpeg steps are dropped — iOS decodes in-process, and the
/// RAM-adaptive first-run screen (P1.4c) names + downloads the model on the next step.
struct OnboardingView: View {
    let onDone: () -> Void

    var body: some View {
        ZStack {
            AuroraBackground().ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        header
                        step("square.and.arrow.down", L("onboarding.ios.step1.title"), L("onboarding.ios.step1.body"))
                        step("lock.shield", L("onboarding.privacy.title"), L("onboarding.ios.privacy.body"))
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(action: onDone) {
                    Text(L("onboarding.start")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Brand.accent)
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Parla")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.gradient)
            Text(L("onboarding.ios.title"))
                .font(.title3).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(Brand.accent).frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(body).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
