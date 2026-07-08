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
                .preferredColorScheme(.dark)   // Parla is dark-theme only, like the Mac app
        }
    }
}

/// First-run gate: show the 4.2.3 model-download screen until the user downloads (or defers), then the main UI.
/// Keeps the display awake while any job is in flight (model download or transcription) — a long on-device run
/// must survive the screen not locking (P1.4f).
private struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("didFirstRunSetup") private var didFirstRun = false

    var body: some View {
        Group {
            if didFirstRun {
                RootTabView()
            } else {
                FirstRunDownloadView(onDone: { didFirstRun = true })
            }
        }
        .keepAwake(while: model.isBusy)
    }
}
