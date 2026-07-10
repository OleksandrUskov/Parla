import SwiftUI
import ParlaCore

/// iOS app entry (iOS-port P1.4a). Builds the real `AppModel.iOS()` (in-process decoder + UIKit seams + a
/// RAM-adaptive default model) once and injects it into the SwiftUI environment for the whole app.
@main
struct ParlaiOSApp: App {
    @State private var model: AppModel

    init() {
        // App.init is @MainActor-isolated → safe to build the @MainActor AppModel here.
        _model = State(initialValue: AppModel.iOS())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(\.locale, model.resolvedLocale)   // reading resolvedLocale here → re-render on language change (mirrors macOS scene root)
                .preferredColorScheme(.dark)   // Parla is dark-theme only, like the Mac app
                .task { ParlaRuntime.model = model }   // app-bound App Intents (Siri/Shortcuts) reach the live model
        }
    }
}

/// First-run gate: show the 4.2.3 model-download screen until the user downloads (or defers), then the main UI.
/// Keeps the display awake while any job is in flight (model download or transcription) — a long on-device run
/// must survive the screen not locking (P1.4f).
private struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("didOnboardIOS") private var didOnboard = false
    @AppStorage("didFirstRunSetup") private var didFirstRun = false
    // Held here (above RootTabView's `.id(uiLanguage)` swap) so the selected tab survives a language switch.
    @State private var tab: RootTab = .history
    // Drives the transcription Live Activity from the phase stream (P2.3b) — best-effort, Core untouched.
    @State private var activityController = TranscriptionActivityController()

    var body: some View {
        Group {
            if !didOnboard {
                OnboardingView(onDone: { didOnboard = true })   // intro + privacy, then the model-download gate
            } else if didFirstRun {
                RootTabView(selection: $tab)
            } else {
                FirstRunDownloadView(onDone: { didFirstRun = true })
            }
        }
        .keepAwake(while: model.isBusy)
        // Pick up anything the Share Extension dropped in the App Group inbox — on cold launch and every
        // foreground. Gated on didFirstRun so a shared file waits for the model-download gate instead of
        // failing to transcribe with no weights.
        .task { drainShareInbox() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { drainShareInbox() } }
        // Reflect the transcription pipeline in a Live Activity / Dynamic Island (best-effort; same observer seam
        // as KeepAwake, so Core is untouched). A phase change carries the batch index → per-chunk updates.
        .onChange(of: model.phase) { _, phase in activityController.sync(phase) }
        // parla:// deep-links (widget taps, Shortcuts, later Handoff). The pure parser lives in Core; here we
        // just route the verbs iOS supports. A note opens via `pendingOpen` (the History shell drains it), so it
        // works on both the compact and the split shell without either needing to know about URLs.
        .onOpenURL { url in
            switch parseParlaURL(url) {
            case .note(let id):  model.pendingOpen = id; tab = .history
            case .dictate:       model.toggleDictation(); tab = .history
            case .show:          tab = .history
            default:             break   // desktop-only verbs (transcribe / clipboard / last) — no-op on iOS
            }
        }
    }

    private func drainShareInbox() {
        guard didFirstRun else { return }
        ShareInbox.drain(into: model)
    }
}
