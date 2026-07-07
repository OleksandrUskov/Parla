import SwiftUI
import ParlaCore

// Minimal iOS app shell (iOS-port P1.4 spike). Purpose of THIS file: prove the iOS app target links the
// cross-platform `ParlaCore` library and builds/runs on the iOS simulator. The real UI (transcription,
// history, the Share-Extension "send a Telegram voice to Parla" flow) is built on top of this next.
@main
struct ParlaiOSApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Parla · iOS")
                .font(.title2.weight(.semibold))
            // Call a pure `ParlaCore` symbol to PROVE the shared library is linked and usable on iOS.
            Text("ParlaCore linked ✓  (subtag: \(languagePrimarySubtag("ru-RU")))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
