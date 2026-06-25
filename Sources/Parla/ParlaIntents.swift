import AppIntents
import AppKit

/// In-process locator for the live `@MainActor AppModel` so app-bound intents reach it without
/// `@Dependency` ceremony (fine for a solo app). Set in `ParlaApp .task`. AppIntents `perform()` for an
/// app-bound intent runs in the app's own process, so this resolves the same model the UI uses.
enum ParlaRuntime {
    @MainActor static weak var model: AppModel?
}

/// Transcribe a file handed in from Shortcuts / Spotlight.
struct TranscribeFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Transcribe File with Parla"
    static let description = IntentDescription("Transcribe an audio or video file to text, 100% on-device.")

    @Parameter(title: "File") var file: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let model = ParlaRuntime.model else { return .result() }
        // IntentFile may be in-memory → materialize to a temp URL, then route into the existing funnel.
        let url: URL
        if let f = file.fileURL {
            url = f
        } else {
            let name = file.filename.isEmpty ? "parla-intent-\(UUID().uuidString)" : file.filename
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try file.data.write(to: dest)
            url = dest
        }
        model.quickModeRun = true
        model.handleDrop(urls: [url])
        return .result()
    }
}

/// Re-run the last transcribed file.
struct TranscribeLastIntent: AppIntent {
    static let title: LocalizedStringResource = "Transcribe Last File with Parla"
    static let description = IntentDescription("Re-run Parla on the most recently transcribed file.")

    @MainActor
    func perform() async throws -> some IntentResult {
        ParlaRuntime.model?.transcribeLast()
        return .result()
    }
}

/// Read action: return the most recent transcript's text (does NOT transcribe). Pipe it into another
/// Shortcut step.
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
        AppShortcut(intent: TranscribeFileIntent(),
                    phrases: ["Transcribe \(\.$file) with \(.applicationName)"],
                    shortTitle: "Transcribe File", systemImageName: "waveform")
        AppShortcut(intent: TranscribeLastIntent(),
                    phrases: ["Transcribe last with \(.applicationName)"],
                    shortTitle: "Transcribe Last", systemImageName: "arrow.clockwise")
        AppShortcut(intent: GetLastTranscriptIntent(),
                    phrases: ["Get last \(.applicationName) transcript"],
                    shortTitle: "Get Last Transcript", systemImageName: "doc.text")
    }
}
