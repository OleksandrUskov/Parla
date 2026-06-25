import SwiftUI
import AppKit
import UserNotifications
import KeyboardShortcuts

@main
struct ParlaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var hotkeyInstalled = false
    @AppStorage("didOnboard") private var didOnboard = false   // first-run sheet gate (UI pref, not history)
    @State private var showOnboarding = false
    @State private var servicesProvider: ServicesProvider?     // strong ref (NSApp.servicesProvider isn't retained)

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(model)
                .environment(\.locale, model.resolvedLocale)   // reading resolvedLocale in App.body → re-render on language change
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView { didOnboard = true; showOnboarding = false }
                        .environment(model)
                }
                .onOpenURL { model.handleParlaURL($0) }   // parla:// scheme (Raycast/Alfred/terminal/Shortcuts)
                .task {
                    appDelegate.model = model            // let the terminate-guard see in-flight work
                    if Onboarding.shouldShowOnboarding(didOnboard: didOnboard, hasHistory: !model.history.isEmpty) {
                        showOnboarding = true            // fresh start only — upgraders with history skip it
                    }
                    NotificationClickHandler.install()   // click on completion notification → bring window forward
                    let sp = ServicesProvider(model: model)   // "Transcribe with Parla" in the Services menu
                    NSApp.servicesProvider = sp
                    servicesProvider = sp                     // keep a strong ref alive
                    NSUpdateDynamicServices()
                    ParlaRuntime.model = model                // app-bound AppIntents reach the live model
                    installHotkeyOnce()                  // install hotkey handler + sync enabled/disabled to the setting
                    model.startWatchingIfEnabled()       // resume folder watching if enabled
                    await model.pruneAudioCache()        // remove orphans + old audio beyond the limit
                    await model.refreshModels()
                }
                .onChange(of: model.globalHotkeyEnabled) { _, _ in syncHotkey() }
                .onChange(of: model.dictationHotkeyEnabled) { _, _ in syncHotkey() }
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
            KeyboardShortcuts.onKeyUp(for: .dictate) { model.toggleDictation() }
        }
        syncHotkey()
    }

    /// Enable/disable each global hotkey to follow its toggle (Carbon, no «Accessibility» permission).
    @MainActor private func syncHotkey() {
        if model.globalHotkeyEnabled { KeyboardShortcuts.enable(.quickTranscribe) }
        else { KeyboardShortcuts.disable(.quickTranscribe) }
        if model.dictationHotkeyEnabled { KeyboardShortcuts.enable(.dictate) }
        else { KeyboardShortcuts.disable(.dictate) }
    }
}

/// Quit Parla when its main window is closed — instead of lingering in the Dock with no windows
/// (the macOS default that forces a manual right-click → Quit). The `MenuBarExtra` is a status item,
/// not a window, so closing the main window terminates the app, giving a normal desktop-app feel.
/// (⌘Q still works; the menu-bar quick-transcribe lives only while the app is running.)
///
/// But a transcription is saved only when it finishes, so closing the window (or ⌘Q) mid-job would
/// silently discard it. `applicationShouldTerminate` is the single gate for ALL termination paths
/// (close-last-window, ⌘Q, Apple-menu Quit), so we confirm there when work is in flight.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, MainActor.assumeIsolated({ model.shouldConfirmQuit }) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("quit.busy.title")
        alert.informativeText = L("quit.busy.message")
        alert.addButton(withTitle: L("quit.busy.cancel"))   // default (first) → safe: don't lose work
        alert.addButton(withTitle: L("quit.busy.quit"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }
}

/// Click on the batch-completion notification → activate Parla and bring its window forward.
/// Registered only in the real app (via `.task`), not in `swift test`.
final class NotificationClickHandler: NSObject, UNUserNotificationCenterDelegate {
    /// `nonisolated(unsafe)`: the handler is stateless and only ever touched on the main actor
    /// (install() sets the delegate on main; the callback hops via MainActor.run). Marking the class
    /// `@MainActor` would break the nonisolated UNUserNotificationCenterDelegate conformance, so we opt
    /// just this global out — benign, like the other main-actor-only statics.
    nonisolated(unsafe) static let shared = NotificationClickHandler()
    static func install() { UNUserNotificationCenter.current().delegate = shared }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        await MainActor.run { NSApp.activate() }   // macOS 14: without ignoringOtherApps (deprecated)
    }
}
