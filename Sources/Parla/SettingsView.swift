import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Модель") {
                Picker("Модель", selection: $model.selectedModel) {
                    ForEach(model.availableModels, id: \.self) { name in
                        Text(friendlyModel(name)).tag(name)
                    }
                }
                Text("Качать и удалять модели удобнее через чип модели в шапке окна.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Язык") {
                Picker("Язык", selection: $model.language) {
                    ForEach(whisperLanguages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                Text("Whisper мультиязычный (~99 языков). На «Авто» язык определяется сам — английский и любой другой работают сходу, доскачивать ничего не нужно. Для русского / украинского / суржика «Авто» — лучший выбор.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Перевод") {
                Toggle("Переводить результат в английский", isOn: $model.translateToEnglish)
                Text("Whisper умеет не только расшифровывать, но и переводить речь любого языка сразу в английский текст.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Поведение") {
                Toggle("Копировать результат в буфер автоматически", isOn: $model.autoCopy)
                Toggle("Показывать таймкоды", isOn: $model.showTimestamps)
            }

            Section("История") {
                Button("Экспортировать историю…") { model.exportHistory() }
                    .disabled(model.history.isEmpty)
                Button("Очистить историю", role: .destructive) { model.clearHistory() }
                    .disabled(model.history.isEmpty)
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
                LabeledContent("Модели на диске") {
                    Text(formatBytes(model.totalModelsBytes)).foregroundStyle(.secondary).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 560)
    }
}
