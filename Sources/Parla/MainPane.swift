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
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Brand.gradient)
            Text(Brand.name)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(Brand.gradient)
            if model.translateToEnglish {
                Text("→ EN")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Brand.accent.opacity(0.25), in: Capsule())
                    .foregroundStyle(Brand.accent)
                    .help("Результат переводится в английский")
            }
            if model.watchEnabled {
                HStack(spacing: 4) {
                    Image(systemName: "eye.fill").font(.caption2)
                    if model.watchQueueCount > 0 {
                        Text("\(model.watchQueueCount)").font(.caption2.weight(.bold)).monospacedDigit()
                    }
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Brand.accent.opacity(0.2), in: Capsule())
                .foregroundStyle(Brand.accent)
                .help(model.watchQueueCount > 0
                      ? "Слежу за папкой · в очереди: \(model.watchQueueCount)"
                      : "Слежу за папкой")
            }
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
        .help("Выбрать, скачать или удалить модель")
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
            Text("Все офлайн, качаются один раз. Клик по строке — выбрать, «Скачать» — загрузить заранее, 🗑 — удалить с диска.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(spacing: 6) {
                ForEach(model.modelTiers) { tier in
                    ModelRow(tier: tier)
                }
            }
            Divider()
            HStack {
                Text("Занято на диске").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(formatBytes(model.totalModelsBytes)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 440)
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
                .help("Удалить модель с диска")
                .disabled(model.downloadingModel != nil || model.isBusy)
            }
        } else {
            HStack(spacing: 8) {
                if !tier.estimate.isEmpty {
                    Text(tier.estimate).font(.caption2).foregroundStyle(.secondary)
                }
                Button { Task { await model.downloadModel(tier.name) } } label: {
                    Label("Скачать", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Brand.accent)
                .disabled(model.downloadingModel != nil || model.isBusy)
            }
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
        case .preparing(let n, let b):
            progressChip("Готовлю \(batchLabel(n, b))…", b)
        case .downloadingModel(let p):
            downloadChip(p)
        case .loadingModel:
            chip("Загружаю модель в память…", busy: true)
        case .transcribing(let n, let b):
            progressChip("Распознаю \(batchLabel(n, b))…", b)
        case .failed(let m):
            chip(m, busy: false, error: true)
        }
    }

    /// Чип + (для батча) нижний детерминированный бар «сколько из скольких».
    private func progressChip(_ text: String, _ b: BatchProgress?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            chip(text, busy: true)
            if let b, b.total > 1 {
                ProgressView(value: Double(b.done), total: Double(b.total))
                    .tint(Brand.accent)
            }
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

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var editorFocused: Bool
    @State private var player = PlaybackController()

    private var text: String { item.display(timestamps: model.showTimestamps) }
    private var justCopied: Bool { model.lastCopiedID == item.id }
    private var audioURL: URL? { AudioStore.playableURL(for: item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Смена выделения (или новая расшифровка): сбрасываем незавершённую правку (чтобы не
        // записать её в чужую запись) и перегружаем плеер на аудио новой записи. initial:true —
        // грузим и при первом показе.
        .onChange(of: item.id, initial: true) { _, _ in
            if isEditing { cancelEdit() }
            player.load(audioURL)
        }
        .onDisappear { player.stop() }
    }

    // MARK: Шапка — мета + действия (разные в режиме чтения и правки)

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.sourceName).font(.system(.headline, design: .rounded)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(meta).font(.caption).foregroundStyle(.secondary)
                    if item.isEdited { editedChip }
                }
            }
            Spacer()
            if isEditing { editActions } else { readActions }
        }
    }

    private var readActions: some View {
        HStack(spacing: 10) {
            if !model.isBusy {
                Button { beginEdit() } label: {
                    Image(systemName: "pencil").font(.body)
                        .padding(9).background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Редактировать текст")
            }
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
            RetranscribeMenu(item: item)
            ShareLink(item: text) {
                Image(systemName: "square.and.arrow.up").font(.body)
                    .padding(9).background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var editActions: some View {
        HStack(spacing: 8) {
            Button { cancelEdit() } label: {
                Text("Отмена")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)   // Esc
            Button { commitEdit() } label: {
                Label("Готово", systemImage: "checkmark")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Brand.gradient, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)   // ⌘↩
        }
    }

    private var editedChip: some View {
        Text("изменено")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Brand.accent.opacity(0.18), in: Capsule())
            .foregroundStyle(Brand.accent)
            .help(item.editedAt.map { "Отредактировано \($0.formatted(date: .abbreviated, time: .shortened))" }
                  ?? "Текст изменён вручную")
    }

    // MARK: Тело — текст (чтение) или редактор (правка)

    @ViewBuilder private var content: some View {
        if isEditing {
            TextEditor(text: $draft)
                .font(.system(.body, design: .rounded))
                .scrollContentBackground(.hidden)          // macOS 14-safe; сохраняем тёмный фон карточки
                .focused($editorFocused)
                .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity, alignment: .leading)
                .padding(10)
                .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
        } else {
            VStack(spacing: 10) {
                TransportBar(player: player, hasAudio: audioURL != nil)
                readBody
            }
        }
    }

    // MARK: Правка — хелперы

    /// Текст записи: список тапабельных сегментов (если есть таймкоды и запись не правлена) или плоский текст.
    @ViewBuilder private var readBody: some View {
        if model.showTimestamps, !item.isEdited, !item.segments.isEmpty {
            SegmentList(segments: item.segments, player: player, tappable: audioURL != nil)
        } else {
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .rounded))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func beginEdit() {
        player.stop()              // правим текст — не проигрываем
        draft = item.text          // ВСЕГДА плоский текст, не display(timestamps:)
        isEditing = true
        editorFocused = true
    }
    private func cancelEdit() {
        isEditing = false
        editorFocused = false
    }
    private func commitEdit() {
        model.saveEdit(draft, for: item.id)
        isEditing = false
        editorFocused = false
    }

    private var meta: String {
        let lang = item.language.isEmpty ? "?" : item.language.uppercased()
        return "\(item.date.formatted(date: .abbreviated, time: .shortened)) · \(lang) · \(friendlyModel(item.model)) · \(Int(item.durationSec))s · \(item.wordCount) сл."
    }
}

/// «Перераспознать» — дропдаун уровней моделей. Перезапускает запись на выбранной модели,
/// заменяя её содержимое на месте. Выключен, если движок занят или исходник недоступен.
struct RetranscribeMenu: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptItem

    var body: some View {
        Menu {
            ForEach(model.modelTiers) { tier in
                Button { model.retranscribe(item, with: tier.name) } label: {
                    if tier.name == item.model {
                        Label("\(tier.title) — текущая", systemImage: "checkmark")
                    } else if !model.isDownloaded(tier.name) {
                        Label("\(tier.title) — скачать", systemImage: "arrow.down.circle")
                    } else {
                        Text(tier.title)
                    }
                }
                .disabled(tier.name == item.model)   // та же модель — пересчитывать нечего
            }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath").font(.body)
                .padding(9).background(.ultraThinMaterial, in: Circle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(!model.canRetranscribe(item))
        .help(item.hasResolvableSource
              ? "Перераспознать другой моделью"
              : "Исходный файл недоступен — перетащи его заново")
    }
}

// MARK: - Плеер исходного аудио (фича 06)

/// Транспорт: play/pause + скрабер + время. Деградирует в одну строку-заметку, если аудио нет
/// или формат не проигрывается встроенным плеером.
struct TransportBar: View {
    let player: PlaybackController
    let hasAudio: Bool

    var body: some View {
        if hasAudio && player.canPlay {
            HStack(spacing: 12) {
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3).foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Brand.gradient, in: Circle())
                }
                .buttonStyle(.plain)
                Slider(value: Binding(get: { player.currentTime },
                                      set: { player.scrub(to: $0) }),
                       in: 0...max(player.duration, 0.01))
                    .tint(Brand.accent)
                Text("\(fmtTime(player.currentTime)) / \(fmtTime(player.duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else if hasAudio {
            note("Это аудио нельзя проиграть встроенным плеером (формат не поддержан).")
        } else {
            note("Аудио недоступно — текст расшифровки сохранён.")
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Список сегментов с таймкодами. Клик по строке (если есть аудио) перематывает плеер.
/// Активный сегмент подсвечивается по текущему времени проигрывания.
struct SegmentList: View {
    let segments: [Segment]
    let player: PlaybackController
    let tappable: Bool

    private var activeIdx: Int? { activeSegmentIndex(segments, at: player.currentTime) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { i, seg in
                    if !seg.text.isEmpty {
                        SegmentRow(seg: seg, active: i == activeIdx, tappable: tappable)
                            .contentShape(Rectangle())
                            .onTapGesture { if tappable { player.seek(to: seg.start) } }
                    }
                }
            }
            .padding(12)
        }
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct SegmentRow: View {
    let seg: Segment
    let active: Bool
    let tappable: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("[\(fmtTime(seg.start))]")
                .font(.caption.monospacedDigit())
                .foregroundStyle(active || tappable ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.tertiary))
            Text(seg.text)
                .font(.system(.body, design: .rounded))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(active ? AnyShapeStyle(Brand.gradient.opacity(0.18)) : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}
