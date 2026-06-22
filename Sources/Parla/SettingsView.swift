import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Модель распознавания") {
                Picker("Модель", selection: $model.selectedModel) {
                    ForEach(model.availableModels, id: \.self) { name in
                        Text(prettyModel(name)).tag(name)
                    }
                }
                Text("Крупнее — точнее, но дольше и больше скачивать. Для русского/украинского рекомендую large-v3 turbo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Язык") {
                Picker("Язык", selection: $model.language) {
                    Text("Авто").tag("")
                    Text("Русский").tag("ru")
                    Text("Українська").tag("uk")
                    Text("English").tag("en")
                    Text("Deutsch").tag("de")
                    Text("Español").tag("es")
                    Text("Français").tag("fr")
                }
                Text("Для русского, украинского и суржика держи «Авто» — модель сама ловит язык и пишет слова как слышит.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Поведение") {
                Toggle("Копировать результат в буфер автоматически", isOn: $model.autoCopy)
                Toggle("Показывать таймкоды", isOn: $model.showTimestamps)
            }

            Section("Система") {
                LabeledContent("ffmpeg") {
                    if let p = AudioConverter.ffmpegURL() {
                        Text(p.path).foregroundStyle(.secondary).font(.caption)
                    } else {
                        Text("не найден — установи: brew install ffmpeg")
                            .foregroundStyle(.orange).font(.caption)
                    }
                }
                Button("Очистить историю", role: .destructive) { model.clearHistory() }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 480)
    }
}
