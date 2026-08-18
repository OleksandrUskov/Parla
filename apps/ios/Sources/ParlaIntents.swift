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

    /// Wait briefly for the UI to publish the model, because on iOS an App Intent can run WITHOUT a scene.
    ///
    /// 🔴 This is the fix for a silent no-op. `model` is set from the `WindowGroup`'s `.task`, and an intent
    /// invoked from Siri, Spotlight or a Shortcut while the app is not in the foreground gets no scene, so that
    /// `.task` never runs and `perform()` used to return an empty result with no error at all — while the
    /// README advertised the feature. `openAppWhenRun` on the intents that mutate state makes a scene connect;
    /// this closes the race between that launch and `perform()`, which are not ordered.
    @MainActor
    static func awaitModel(timeoutMs: Int = 5_000) async -> AppModel? {
        var waited = 0
        while model == nil, waited < timeoutMs {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 50
        }
        return model
    }
}

/// Transcribe a file handed in from Shortcuts / Siri — 100% on-device.
struct TranscribeFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Transcribe File with Parla"
    static let description = IntentDescription("Transcribe an audio or video file to text, 100% on-device.")

    /// The app must come to the front: this intent mutates the library and shows progress, and on iOS an
    /// intent that runs without a scene reaches no model at all.
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "File") var file: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let model = await ParlaRuntime.awaitModel() else { return .result() }
        // IntentFile may be in-memory → materialize to a temp URL, then route into the existing drop funnel.
        let url: URL
        if let f = file.fileURL {
            url = f
        } else {
            // The Shortcut's filename is INPUT: unsanitised, "../Library/Application Support/<id>/history.json"
            // resolves inside the container and overwrites the user's archive. See ParlaCore.IntentFileName.
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(IntentFileName.safe(file.filename))
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

    /// Deliberately does NOT open the app: a read action exists to be piped into another Shortcut step, and
    /// yanking someone into an app to answer it would make it useless. It therefore never needs the live model
    /// — the history file IS the truth, since every mutation saves it — and falls back to reading it directly,
    /// which is also what makes this work when the app is not running at all.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        if let live = ParlaRuntime.model?.lastTranscriptText, !live.isEmpty { return .result(value: live) }
        return .result(value: HistoryStore.load().first?.text ?? "")
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
