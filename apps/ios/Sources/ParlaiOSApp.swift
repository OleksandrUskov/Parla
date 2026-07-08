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
            RootTabView()
                .environment(model)
                .preferredColorScheme(.dark)   // Parla is dark-theme only, like the Mac app
        }
    }
}
