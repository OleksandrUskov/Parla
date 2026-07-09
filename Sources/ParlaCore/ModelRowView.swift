import SwiftUI

/// A transcription-model tier row (iOS-port P1.4i) — radio-select + download / delete / progress. Relocated
/// VERBATIM from the macOS `MainPane.swift` into ParlaCore as `public` SwiftUI so both the macOS ModelManagerView
/// and the iOS ModelManagerView render the same row (true parity, zero dup). Tapping the row selects that tier —
/// which is also the iOS "recover from a mis-picked RAM tier" path (the P1.4 review debt). Depends only on
/// `AppModel` / `ModelTier` / `Brand` / `formatBytes` — all already in Core.
public struct ModelRow: View {
    @Environment(AppModel.self) private var model
    let tier: ModelTier

    public init(tier: ModelTier) { self.tier = tier }

    private var isSelected: Bool { model.selectedModel == tier.name }
    private var isDownloaded: Bool { model.isDownloaded(tier.name) }
    private var isDownloading: Bool { model.downloadingModel == tier.name }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.tertiary))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(tier.title)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    if tier.recommended {
                        Text(L("model.recommended")).font(.caption2.weight(.bold)).foregroundStyle(Brand.accent)
                    }
                }
                Text(tier.hint).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(8)
        .background(
            isSelected ? AnyShapeStyle(Brand.gradient.opacity(0.18)) : AnyShapeStyle(Color.white.opacity(0.04)),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectedModel = tier.name }
    }

    @ViewBuilder private var trailing: some View {
        if isDownloading {
            HStack(spacing: 6) {
                ProgressView(value: model.downloadProgress).frame(width: 64)
                Text("\(Int(model.downloadProgress * 100))%").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
        } else if isDownloaded {
            HStack(spacing: 8) {
                if let bytes = model.modelSizes[tier.name] {
                    Text(formatBytes(bytes)).font(.caption2).foregroundStyle(.secondary)
                }
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Button { Task { await model.deleteModel(tier.name) } } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.borderless)
                .tint(.secondary)
                .help(Text(L("model.delete.help")))
                .accessibilityLabel(Text(L("model.delete.help")))
                .disabled(model.downloadingModel != nil || model.isBusy)
            }
        } else {
            HStack(spacing: 8) {
                if !tier.estimate.isEmpty {
                    Text(tier.estimate).font(.caption2).foregroundStyle(.secondary)
                }
                Button { Task { await model.downloadModel(tier.name) } } label: {
                    Label(L("common.download"), systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Brand.accent)
                .disabled(model.downloadingModel != nil || model.isBusy)
            }
        }
    }
}
