import AppIntents
import ParlaCore
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
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(IntentFileName.safe(file.filename))
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

/// A Shortcut hands us a filename, and we write a file with it. That name is INPUT, not a label.
///
/// `appendingPathComponent` does not resolve `..`, so a Shortcut supplying `../../../foo` wrote outside the
/// temporary directory — anywhere the app could reach, which today is everywhere the user can. Sandboxing would
/// mask this rather than fix it (the write would simply be denied), and the app is not sandboxed today, so it is
/// a live defect and not a Mac App Store one. Found while auditing the sandbox surface, which is exactly the
/// kind of thing an audit is for: nobody was looking here.
enum IntentFileName {
    /// Reduce whatever arrives to a single, harmless path component.
    static func safe(_ raw: String) -> String {
        // lastPathComponent collapses any directory structure, including `..` segments and absolute paths.
        var name = (raw as NSString).lastPathComponent
        // …but NOT always: for "/" and "//" it returns "/" itself. Caught by the test, not by reading the code —
        // which is the whole reason a sanitiser gets a test that asserts the property rather than the examples.
        name = name.replacingOccurrences(of: "/", with: "")
        // "..", "." and "" are all valid lastPathComponents and none of them is a filename.
        if name.isEmpty || name == "." || name == ".." { name = "" }
        // A leading dot would create a hidden file; a colon or a null byte can still confuse the filesystem layer.
        name = name.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "\0", with: "")
        if name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? "parla-intent-\(UUID().uuidString)" : name
    }
}
