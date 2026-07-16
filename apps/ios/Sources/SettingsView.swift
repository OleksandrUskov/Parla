import SwiftUI
import ParlaCore

/// iOS Settings tab. Mirrors the macOS `SettingsView` section-for-section, reusing the SAME
/// `L()` keys (no new L10n except the tab title). Backing props are all Core `@Observable` didSet-persisted, so
/// a toggle here drives the shared reading views live and survives relaunch — exactly like the Mac.
///
/// Dropped vs macOS (physically macOS-only): folder-watch, the global hotkey + `KeyboardShortcuts.Recorder`,
/// the dictation paste-into-frontmost toggle (the paste seam is inert on iOS), the ffmpeg row (iOS decodes
/// in-process), the pinned-player toggle (the iOS detail always pins → the toggle is a no-op), and the MLX
/// generative hint (MLX is `#if os(macOS)`). Model selection is NOT duplicated — there's a Models tab; a
/// read-only current-model + on-disk-size line deep-links there via `onManageModels`.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// Deep-link to the Models tab (owned by the root shell, above the language `.id` swap).
    var onManageModels: () -> Void

    @State private var shareItem: ShareItem?      // whole-history backup export (same mechanism as HistoryListView)
    @State private var showClearConfirm = false
    @State private var showAcknowledgements = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
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

                // Read-only current model + on-disk size; management lives in the Models tab (no duplicate picker).
                Section(L("settings.section.model")) {
                    LabeledContent(L("settings.section.model")) {
                        Text(friendlyModel(model.selectedModel)).foregroundStyle(.secondary)
                    }
                    LabeledContent(L("settings.system.models")) {
                        Text(formatBytes(model.totalModelsBytes)).foregroundStyle(.secondary).font(.caption)
                    }
                    Button(L("model.manager.title")) { onManageModels() }
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

                Section(L("settings.section.insights")) {
                    Toggle(L("settings.insights.titles"), isOn: $model.showTitles)
                    Toggle(L("settings.insights.keywords"), isOn: $model.showKeywords)
                    Toggle(L("settings.insights.summary"), isOn: $model.showSummaries)
                    Toggle(L("settings.insights.actions"), isOn: $model.showActions)
                    Text(L("settings.insights.hint"))
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section(L("settings.section.dictation")) {
                    Picker(L("settings.dictation.mode"), selection: $model.dictationMode) {
                        ForEach(DictationMode.allCases) { mode in Text(mode.label).tag(mode) }
                    }
                    Toggle(L("settings.dictation.vad"), isOn: $model.dictationVADEnabled)
                    Toggle(L("settings.dictation.streaming"), isOn: $model.dictationLiveStreaming)
                    if model.dictationLiveStreaming {
                        Text(L("settings.dictation.streaming.caption"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle(L("settings.dictation.keepaudio"), isOn: $model.keepDictationAudio)
                    Text(L("settings.dictation.hint"))
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section(L("settings.section.history")) {
                    Button(L("settings.history.export")) { shareHistory() }
                        .disabled(model.history.isEmpty)
                    Button(L("settings.history.clear"), role: .destructive) { showClearConfirm = true }
                        .disabled(model.history.isEmpty)
                }

                Section(L("settings.section.system")) {
                    LabeledContent(L("settings.system.audio")) {
                        Text(formatBytes(AudioStore.totalBytes())).foregroundStyle(.secondary).font(.caption)
                    }
                    Button(L("settings.system.clearaudio"), role: .destructive) { model.clearAudioCache() }
                    Text(L("settings.system.audiohint"))
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section(L("settings.section.about")) {
                    LabeledContent(Brand.name) {
                        Text(Acknowledgements.appVersion).foregroundStyle(.secondary).font(.caption)
                    }
                    Button(L("acknowledgements.title")) { showAcknowledgements = true }
                }
            }
            .navigationTitle(L("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
        .sheet(isPresented: $showAcknowledgements) { AcknowledgementsView() }
        .confirmationDialog(L("history.clear.confirm.title"), isPresented: $showClearConfirm,
                            titleVisibility: .visible) {
            Button(L("history.clear.confirm.button"), role: .destructive) { model.clearHistory() }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("history.clear.confirm.message"))
        }
    }

    /// Whole-history backup → a single Markdown file shared via the system sheet (mirrors HistoryListView).
    private func shareHistory() {
        guard !model.history.isEmpty else { return }
        let md = exportText(model.history, content: model.exportContent)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parla-history.md")
        guard (try? Data(md.utf8).write(to: url)) != nil else { return }
        shareItem = ShareItem(url: url)
    }
}
