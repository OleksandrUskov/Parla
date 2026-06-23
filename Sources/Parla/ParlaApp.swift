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
                .task {
                    NotificationClickHandler.install()   // клик по уведомлению о завершении → окно вперёд
                    installHotkeyOnce()                  // обработчик хоткея + привести вкл/выкл к настройке
                    model.startWatchingIfEnabled()       // возобновить слежение за папкой, если включено
                    await model.pruneAudioCache()        // убрать сирот + старое аудио сверх лимита
                    await model.refreshModels()
                }
                .onChange(of: model.globalHotkeyEnabled) { _, _ in syncHotkey() }
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 980, height: 660)

        MenuBarExtra("Parla", systemImage: model.isBusy ? "waveform.circle.fill" : "waveform") {
            MenuBarView().environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 500)
                .preferredColorScheme(.dark)
        }
    }

    /// Один раз: зарегистрировать обработчик глобальной комбинации + привести вкл/выкл к настройке.
    /// Регистрация только в реальном приложении (через `.task`), не в `swift test`.
    @MainActor private func installHotkeyOnce() {
        if !hotkeyInstalled {
            hotkeyInstalled = true
            KeyboardShortcuts.onKeyUp(for: .quickTranscribe) { model.quickTranscribeFromClipboard() }
        }
        syncHotkey()
    }

    /// Вкл/выкл глобальной комбинации вслед за тоглом (Carbon, без «Универсального доступа»).
    @MainActor private func syncHotkey() {
        if model.globalHotkeyEnabled { KeyboardShortcuts.enable(.quickTranscribe) }
        else { KeyboardShortcuts.disable(.quickTranscribe) }
    }
}

/// Клик по уведомлению о завершении батча → активируем Parla и выносим окно вперёд.
/// Регистрируется только в реальном приложении (через `.task`), не в `swift test`.
final class NotificationClickHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationClickHandler()
    static func install() { UNUserNotificationCenter.current().delegate = shared }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        await MainActor.run { NSApp.activate() }   // macOS 14: без ignoringOtherApps (deprecated)
    }
}
