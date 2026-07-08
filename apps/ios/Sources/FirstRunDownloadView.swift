import SwiftUI
import ParlaCore

/// First-run model-download screen (iOS-port P1.4c) — the App Store **4.2.3** gate: the ~600 MB speech model is
/// NOT bundled and NOT auto-downloaded; this screen names the (RAM-adaptive) model, shows its size, and requires
/// an explicit tap before the download, with resumable progress. "Maybe later" lets the user in without a model
/// (a transcribe then downloads on demand). Reuses `AppModel.downloadModel` + `downloadProgress` verbatim.
struct FirstRunDownloadView: View {
    @Environment(AppModel.self) private var model
    let onDone: () -> Void

    var body: some View {
        ZStack {
            AuroraBackground().ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "waveform")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(Brand.gradient)
                Text(Brand.name).font(.largeTitle.bold())
                Text(L("onboarding.privacy.body"))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                modelCard
                Spacer()
                if case .failed(let msg) = model.phase {
                    Text(msg).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                controls
            }
            .padding(28)
        }
    }

    private var modelCard: some View {
        VStack(spacing: 4) {
            Text(friendlyModel(model.selectedModel)).font(.headline)
            Text(ModelTierSelector.sizeEstimate(for: model.selectedModel))
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private var controls: some View {
        if model.downloadingModel != nil {
            VStack(spacing: 10) {
                ProgressView(value: model.downloadProgress).tint(Brand.accent)
                Text("\(Int((model.downloadProgress * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 12) {
                Button(action: startDownload) {
                    Text("\(L("common.download")) · \(ModelTierSelector.sizeEstimate(for: model.selectedModel))")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.accent)
                .controlSize(.large)

                Button(L("firstrun.later"), action: onDone)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func startDownload() {
        model.dismissError()
        Task {
            await model.downloadModel(model.selectedModel)
            if model.isDownloaded(model.selectedModel) { onDone() }   // success → into the app; a failure keeps the screen
        }
    }
}
