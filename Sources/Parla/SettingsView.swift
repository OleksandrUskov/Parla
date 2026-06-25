import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section(L("settings.section.interface")) {
                Picker(L("settings.interface.language"), selection: $model.uiLanguage) {
                    ForEach(UILanguage.allCases) { lang in
                        Text(lang.pickerLabel).tag(lang)
                    }
                }
                Text(L("settings.interface.hint"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("settings.section.model")) {
                Picker(L("settings.section.model"), selection: $model.selectedModel) {
                    ForEach(model.availableModels, id: \.self) { name in
                        Text(friendlyModel(name)).tag(name)
                    }
                }
                Text(L("settings.model.hint"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("settings.section.language")) {
                Picker(L("settings.section.language"), selection: $model.language) {
                    ForEach(whisperLanguages, id: \.code) { lang in
                        Text(lang.code.isEmpty ? L("lang.auto") : lang.name).tag(lang.code)
                    }
                }
                Text(L("settings.language.hint"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("settings.section.translation")) {
                Toggle(L("settings.translation.toggle"), isOn: $model.translateToEnglish)
                Text(L("settings.translation.hint"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("settings.section.behavior")) {
                Toggle(L("settings.behavior.autocopy"), isOn: $model.autoCopy)
                Toggle(L("settings.behavior.timestamps"), isOn: $model.showTimestamps)
                Toggle(L("settings.behavior.sound"), isOn: $model.soundOnComplete)
            }

            Section(L("settings.section.folderwatch")) {
                Toggle(L("settings.folderwatch.toggle"), isOn: $model.watchEnabled)
                LabeledContent(L("settings.folderwatch.folder")) {
                    HStack(spacing: 8) {
                        Text(model.watchedFolderURL?.path ?? L("settings.folderwatch.notchosen"))
                            .font(.caption)
                            .foregroundStyle(model.watchedFolderURL == nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            .lineLimit(1).truncationMode(.middle)
                        Button(L("settings.folderwatch.choose")) { model.pickWatchFolder() }
                    }
                }
                Toggle(L("settings.folderwatch.subfolders"), isOn: $model.watchRecursive)
                Toggle(L("settings.folderwatch.sidecar"), isOn: $model.watchWriteSidecar)
                Text(L("settings.folderwatch.hint"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("settings.section.hotkey")) {
                Toggle(L("settings.hotkey.toggle"), isOn: $model.globalHotkeyEnabled)
                // Always visible so the user sees the current binding (default ⌃⌥⌘T) and can rebind
                // it any time; the toggle above only enables/disables firing it globally.
                KeyboardShortcuts.Recorder(L("settings.hotkey.recorder"), name: .quickTranscribe)
                Text(L("settings.hotkey.hint"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("settings.section.dictation")) {
                Toggle(L("settings.dictation.toggle"), isOn: $model.dictationHotkeyEnabled)
                KeyboardShortcuts.Recorder(L("settings.dictation.recorder"), name: .dictate)
                Picker(L("settings.dictation.mode"), selection: $model.dictationMode) {
                    ForEach(DictationMode.allCases) { mode in Text(mode.label).tag(mode) }
                }
                Toggle(L("settings.dictation.vad"), isOn: $model.dictationVADEnabled)
                Toggle(L("settings.dictation.keepaudio"), isOn: $model.keepDictationAudio)
                Toggle(L("settings.dictation.paste"), isOn: $model.dictationPasteIntoFrontmost)
                if model.dictationPasteIntoFrontmost {
                    Text(L("settings.dictation.paste.caption"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(L("settings.dictation.hint"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("settings.section.history")) {
                Button(L("settings.history.export")) { model.exportHistory() }
                    .disabled(model.history.isEmpty)
                Button(L("settings.history.clear"), role: .destructive) { model.clearHistory() }
                    .disabled(model.history.isEmpty)
            }

            Section(L("settings.section.system")) {
                LabeledContent("ffmpeg") {
                    if let p = AudioConverter.ffmpegURL() {
                        Text(AudioConverter.isUsingBundledFfmpeg ? L("settings.system.ffmpeg.bundled") : p.path)
                            .foregroundStyle(.secondary).font(.caption)
                    } else {
                        Text(L("settings.system.ffmpeg.missing"))
                            .foregroundStyle(.orange).font(.caption)
                    }
                }
                LabeledContent(L("settings.system.models")) {
                    Text(formatBytes(model.totalModelsBytes)).foregroundStyle(.secondary).font(.caption)
                }
                LabeledContent(L("settings.system.audio")) {
                    Text(formatBytes(AudioStore.totalBytes())).foregroundStyle(.secondary).font(.caption)
                }
                Button(L("settings.system.clearaudio"), role: .destructive) { model.clearAudioCache() }
                Text(L("settings.system.audiohint"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 560)
    }
}
