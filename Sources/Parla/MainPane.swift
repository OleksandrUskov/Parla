import SwiftUI

struct MainPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            BrandHeader()
            DropZoneView().frame(height: 168)
            StatusBar()
            if let item = model.selectedItem {
                TranscriptCard(item: item)
            } else {
                EmptyState()
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Brand.gradient)
            Text(Brand.name)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(Brand.gradient)
            Spacer()
            ModelButton()
            SettingsLink {
                Image(systemName: "gearshape.fill").font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Менеджер моделей

/// Чип текущей модели → открывает менеджер моделей (выбор + скачивание).
struct ModelButton: View {
    @Environment(AppModel.self) private var model
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu").font(.caption)
                Text(friendlyModel(model.selectedModel)).font(.caption.weight(.medium)).lineLimit(1)
                if !model.isDownloaded(model.selectedModel) {
                    Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(Brand.accent)
                }
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("Выбрать и скачать модель")
        .popover(isPresented: $show, arrowEdge: .bottom) {
            ModelManagerView()
        }
    }
}

struct ModelManagerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Модели распознавания").font(.system(.headline, design: .rounded))
            Text("Все офлайн, качаются один раз. Клик по строке — выбрать, «Скачать» — загрузить заранее.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(spacing: 6) {
                ForEach(model.modelTiers) { tier in
                    ModelRow(tier: tier)
                }
            }
        }
        .padding(16)
        .frame(width: 430)
    }
}

struct ModelRow: View {
    @Environment(AppModel.self) private var model
    let tier: ModelTier

    private var isSelected: Bool { model.selectedModel == tier.name }
    private var isDownloaded: Bool { model.isDownloaded(tier.name) }
    private var isDownloading: Bool { model.downloadingModel == tier.name }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.tertiary))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(tier.title)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    if tier.recommended {
                        Text("рекомендую").font(.caption2.weight(.bold)).foregroundStyle(Brand.accent)
                    }
                }
                Text(tier.hint).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
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
            Label("Скачано", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        } else {
            Button { Task { await model.downloadModel(tier.name) } } label: {
                Label("Скачать", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Brand.accent)
            .disabled(model.downloadingModel != nil)
        }
    }
}

// MARK: - Статус / прогресс

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .preparing(let n):
            chip("Готовлю «\(n)»…", busy: true)
        case .downloadingModel(let p):
            downloadChip(p)
        case .loadingModel:
            chip("Загружаю модель в память…", busy: true)
        case .transcribing(let n):
            chip("Распознаю «\(n)»…", busy: true)
        case .failed(let m):
            chip(m, busy: false, error: true)
        }
    }

    private func chip(_ text: String, busy: Bool, error: Bool = false) -> some View {
        HStack(spacing: 10) {
            if busy {
                ProgressView().controlSize(.small)
            } else if error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(error ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func downloadChip(_ p: Double) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle").foregroundStyle(Brand.accent)
                Text("Скачиваю модель (один раз)… \(Int(p * 100))%").font(.callout)
                Spacer()
            }
            ProgressView(value: p).tint(Brand.accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct EmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(Brand.gradient)
                .opacity(0.85)
            Text("Готов к работе")
                .font(.system(.title3, design: .rounded).weight(.semibold))
            Text("Перетащи голосовое из Telegram (или «выбери файл») — получишь текст за пару секунд")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct TranscriptCard: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptItem

    private var text: String { item.display(timestamps: model.showTimestamps) }
    private var justCopied: Bool { model.lastCopiedID == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.sourceName).font(.system(.headline, design: .rounded)).lineLimit(1)
                    Text(meta).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.copyItem(item) } label: {
                    Label(justCopied ? "Скопировано" : "Копировать",
                          systemImage: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(
                            justCopied ? AnyShapeStyle(Color.green.opacity(0.3)) : AnyShapeStyle(Brand.gradient),
                            in: Capsule()
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                ShareLink(item: text) {
                    Image(systemName: "square.and.arrow.up").font(.body)
                        .padding(9).background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
            }
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .rounded))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var meta: String {
        let lang = item.language.isEmpty ? "?" : item.language.uppercased()
        return "\(item.date.formatted(date: .abbreviated, time: .shortened)) · \(lang) · \(friendlyModel(item.model)) · \(Int(item.durationSec))s"
    }
}
