import SwiftUI
import UniformTypeIdentifiers

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
            OpenFilesButton()
            ModelChip()
            InfoButton()
            SettingsLink {
                Image(systemName: "gearshape.fill").font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Прямой выбор файлов/папки — альтернатива перетаскиванию.
struct OpenFilesButton: View {
    @Environment(AppModel.self) private var model
    @State private var showImporter = false

    var body: some View {
        Button { showImporter = true } label: {
            Label("Открыть", systemImage: "folder.badge.plus")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(
                    model.isBusy ? AnyShapeStyle(Color.gray.opacity(0.3)) : AnyShapeStyle(Brand.gradient),
                    in: Capsule()
                )
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .help("Открыть файлы или целую папку с голосовыми")
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio, .movie, .folder, .data],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { model.handleDrop(urls: urls) }
        }
    }
}

struct ModelChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Picker("Модель", selection: Binding(get: { model.selectedModel }, set: { model.selectedModel = $0 })) {
                ForEach(model.availableModels, id: \.self) { name in
                    Text(prettyModel(name) + (model.isDownloaded(name) ? "  ✓" : "")).tag(name)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu").font(.caption)
                Text(prettyModel(model.selectedModel)).font(.caption.weight(.medium)).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// Кнопка-справка (i): краткое описание моделей + статус скачивания.
struct InfoButton: View {
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "info.circle").font(.title3).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Какую модель выбрать")
        .popover(isPresented: $show, arrowEdge: .bottom) {
            ModelGuideView()
        }
    }
}

struct ModelGuideView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Модели распознавания").font(.system(.headline, design: .rounded))
            Text("Все работают офлайн. Скачиваются один раз, потом хранятся на диске. ✓ — уже скачано.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            row("Tiny", "≈75 МБ", "Очень быстро, черновое качество — для теста.", best: false)
            row("Base", "≈140 МБ", "Быстро, базовое качество.", best: false)
            row("Small", "≈480 МБ", "Хороший баланс скорость / точность.", best: false)
            row("Large v3", "≈1.5 ГБ", "Максимум точности, но медленнее.", best: false)
            row("Large v3 turbo", "≈630 МБ", "Почти как Large v3, но в разы быстрее. Лучший выбор для русского / украинского.", best: true)
            Divider()
            HStack(spacing: 8) {
                if model.isDownloaded(model.selectedModel) {
                    Label("Текущая модель скачана", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                } else {
                    Label("Текущая не скачана", systemImage: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Скачать сейчас") { Task { await model.downloadSelectedModel() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.accent)
                        .disabled(model.isBusy)
                }
            }
            .font(.callout)
        }
        .padding(16)
        .frame(width: 380)
    }

    private func row(_ name: String, _ size: String, _ desc: String, best: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: best ? "star.fill" : "circle.fill")
                .font(best ? .caption : .system(size: 5))
                .foregroundStyle(best ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.tertiary))
                .frame(width: 14)
                .padding(.top, best ? 2 : 6)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(name).font(.callout.weight(best ? .semibold : .regular))
                    Text(size).font(.caption2).foregroundStyle(.secondary)
                    if best {
                        Text("рекомендую").font(.caption2.weight(.bold)).foregroundStyle(Brand.accent)
                    }
                }
                Text(desc).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

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
            Text("Перетащи голосовое из Telegram или нажми «Открыть» — получишь текст за пару секунд")
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
        return "\(item.date.formatted(date: .abbreviated, time: .shortened)) · \(lang) · \(prettyModel(item.model)) · \(Int(item.durationSec))s"
    }
}
