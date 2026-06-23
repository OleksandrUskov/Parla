import SwiftUI
import KeyboardShortcuts

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

            Section("Слежение за папкой") {
                Toggle("Следить за папкой", isOn: $model.watchEnabled)
                LabeledContent("Папка") {
                    HStack(spacing: 8) {
                        Text(model.watchedFolderURL?.path ?? "не выбрана")
                            .font(.caption)
                            .foregroundStyle(model.watchedFolderURL == nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            .lineLimit(1).truncationMode(.middle)
                        Button("Выбрать…") { model.pickWatchFolder() }
                    }
                }
                Toggle("Включая подпапки", isOn: $model.watchRecursive)
                Toggle("Сохранять .txt рядом с файлом", isOn: $model.watchWriteSidecar)
                Text("Новые аудиофайлы в папке распознаются сами — как старый скрипт, но локально. Транскрибируются только файлы, появившиеся после включения; уже лежащие игнорируются.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Горячая клавиша") {
                Toggle("Глобальный хоткей — распознать аудио из буфера", isOn: $model.globalHotkeyEnabled)
                if model.globalHotkeyEnabled {
                    KeyboardShortcuts.Recorder("Комбинация:", name: .quickTranscribe)
                }
                Text("Работает глобально из любого приложения — без «Универсального доступа» и системных запросов. Кликни по полю, чтобы переназначить. Кнопки «Распознать из буфера» / «Повторить последний файл» в меню-баре работают всегда.")
                    .font(.caption).foregroundStyle(.secondary)
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
                LabeledContent("Аудио для плеера") {
                    Text(formatBytes(AudioStore.totalBytes())).foregroundStyle(.secondary).font(.caption)
                }
                Button("Очистить аудио-кэш", role: .destructive) { model.clearAudioCache() }
                Text("Parla хранит копии аудио для повторного прослушивания и автоматически удаляет самые старые, когда их набирается слишком много. Текст расшифровок при этом сохраняется всегда.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 560)
    }
}
