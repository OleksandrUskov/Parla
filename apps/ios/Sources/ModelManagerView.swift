import SwiftUI
import ParlaCore

/// «Модели» tab (iOS-port P1.4i) — the real model manager, replacing the P1.4a placeholder. Lists the
/// transcription tiers via the shared Core `ModelRow` (download / delete / on-disk size / progress) over the
/// same `model.modelTiers` the macOS manager uses. Tapping a tier selects it — the iOS way to override the
/// RAM-adaptive default or recover from a momentary-pressure mis-tier (the P1.4 review debt). No MLX/embed rows
/// (gated out of iOS in P1.1), so disk usage is just the WhisperKit weights. The weights themselves now live
/// under Application Support, excluded from backup (the sibling storage-relocation commit).
struct ModelManagerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground().ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("model.manager.hint"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(model.modelTiers) { tier in
                            ModelRow(tier: tier)
                        }

                        Divider().overlay(Color.white.opacity(0.1)).padding(.vertical, 4)
                        HStack {
                            Text(L("model.disk.used")).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(formatBytes(model.totalModelsBytes))
                                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle(L("model.manager.title"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { model.refreshDownloaded() }   // refresh presence + on-disk sizes when the tab appears
    }
}
