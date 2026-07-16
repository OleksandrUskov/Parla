import AppIntents
import ParlaCore

/// App Intents → Siri / Shortcuts / Spotlight. A lean iOS subset of the macOS intents: the two
/// that port cleanly (transcribe a handed-in file; read the last transcript). The macOS `TranscribeLastIntent`
/// is skipped — it depends on `transcribeLast()`, which lives in the macOS-only quick-actions layer. These live
/// in the app target (not ParlaCore) so the AppIntents metadata processor registers them for THIS app.
///
/// In-process locator for the live `@MainActor AppModel` so an app-bound intent reaches the same model the UI
/// drives (an app-bound intent's `perform()` runs in the app's own process). Set in `ParlaiOSApp`.
enum ParlaRuntime {
    @MainActor static weak var model: AppModel?
}

/// Transcribe a file handed in from Shortcuts / Siri — 100% on-device.
struct TranscribeFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Transcribe File with Parla"
    static let description = IntentDescription("Transcribe an audio or video file to text, 100% on-device.")

    @Parameter(title: "File") var file: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let model = ParlaRuntime.model else { return .result() }
        // IntentFile may be in-memory → materialize to a temp URL, then route into the existing drop funnel.
        let url: URL
        if let f = file.fileURL {
            url = f
        } else {
            let name = file.filename.isEmpty ? "parla-intent-\(UUID().uuidString)" : file.filename
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try file.data.write(to: dest)
            url = dest
        }
        model.handleDrop(urls: [url])
        return .result()
    }
}

/// Read action: return the most recent transcript's text (does NOT transcribe). Pipe it into another Shortcut step.
struct GetLastTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Last Parla Transcript"
    static let description = IntentDescription("Return the text of the most recent transcript. Does not transcribe.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: ParlaRuntime.model?.lastTranscriptText ?? "")
    }
}

/// Auto-populates Spotlight + the Shortcuts gallery with spoken/typed phrases.
struct ParlaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // NB: an App Shortcut phrase may only interpolate an AppEntity/AppEnum parameter — NOT an IntentFile —
        // so the file isn't in the phrase (Siri asks for it). The iOS metadata validator halts on this; the
        // macOS build (SPM, no --validate-assistant-intents) never caught the same phrase.
        AppShortcut(intent: TranscribeFileIntent(),
                    phrases: ["Transcribe a file with \(.applicationName)"],
                    shortTitle: "Transcribe File", systemImageName: "waveform")
        AppShortcut(intent: GetLastTranscriptIntent(),
                    phrases: ["Get last \(.applicationName) transcript"],
                    shortTitle: "Get Last Transcript", systemImageName: "doc.text")
    }
}
