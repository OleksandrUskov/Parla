import SwiftUI

struct DetailPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            DropZoneView()
                .frame(height: 130)

            StatusBar()

            if let item = model.selectedItem {
                TranscriptDetailView(item: item)
            } else {
                Spacer()
                ContentUnavailableView(
                    "Готов к работе",
                    systemImage: "waveform",
                    description: Text("Перетащи аудио в зону выше или нажми «выбери файл»")
                )
                Spacer()
            }
        }
        .padding(20)
        .navigationTitle("Murmur")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ModelMenu() }
        }
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .preparing(let name):
            busy("Готовлю «\(name)»…")
        case .loadingModel:
            busy("Загружаю модель (первый раз — это разово, подожди пару минут)…")
        case .transcribing(let name):
            busy("Распознаю «\(name)»…")
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

struct ModelMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Picker("Модель", selection: Binding(
                get: { model.selectedModel },
                set: { model.selectedModel = $0 }
            )) {
                ForEach(model.availableModels, id: \.self) { name in
                    Text(prettyModel(name)).tag(name)
                }
            }
            Divider()
            SettingsLink { Text("Настройки…") }
        } label: {
            Label(prettyModel(model.selectedModel), systemImage: "cpu")
        }
    }
}
