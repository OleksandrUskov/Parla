import SwiftUI
import AppKit
import UserNotifications
import KeyboardShortcuts

@main
struct ParlaApp: App {
    @State private var model = AppModel()
    @State private var hotkeyInstalled = false

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(model)
                .environment(\.locale, model.resolvedLocale)   // reading resolvedLocale in App.body → re-render on language change
                .task {
                    NotificationClickHandler.install()   // click on completion notification → bring window forward
                    installHotkeyOnce()                  // install hotkey handler + sync enabled/disabled to the setting
                    model.startWatchingIfEnabled()       // resume folder watching if enabled
                    await model.pruneAudioCache()        // remove orphans + old audio beyond the limit
                    await model.refreshModels()
                }
                .onChange(of: model.globalHotkeyEnabled) { _, _ in syncHotkey() }
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 980, height: 660)

        MenuBarExtra("Parla", systemImage: model.isBusy ? "waveform.circle.fill" : "waveform") {
            MenuBarView()
                .environment(model)
                .environment(\.locale, model.resolvedLocale)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .environment(\.locale, model.resolvedLocale)
                .frame(width: 500)
                .preferredColorScheme(.dark)
        }
    }

    /// Once: register the global hotkey handler + sync enabled/disabled to the setting.
    /// Registered only in the real app (via `.task`), not in `swift test`.
    @MainActor private func installHotkeyOnce() {
        if !hotkeyInstalled {
            hotkeyInstalled = true
            KeyboardShortcuts.onKeyUp(for: .quickTranscribe) { model.quickTranscribeFromClipboard() }
        }
        syncHotkey()
    }

    /// Enable/disable the global hotkey to follow the toggle (Carbon, no «Accessibility» permission).
    @MainActor private func syncHotkey() {
        if model.globalHotkeyEnabled { KeyboardShortcuts.enable(.quickTranscribe) }
        else { KeyboardShortcuts.disable(.quickTranscribe) }
    }
}

/// Click on the batch-completion notification → activate Parla and bring its window forward.
/// Registered only in the real app (via `.task`), not in `swift test`.
final class NotificationClickHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationClickHandler()
    static func install() { UNUserNotificationCenter.current().delegate = shared }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        await MainActor.run { NSApp.activate() }   // macOS 14: without ignoringOtherApps (deprecated)
    }
}
