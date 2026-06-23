import SwiftUI
import AppKit
import UserNotifications

@main
struct ParlaApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(model)
                .task {
                    NotificationClickHandler.install()   // клик по уведомлению о завершении → окно вперёд
                    model.startWatchingIfEnabled()       // возобновить слежение за папкой, если включено
                    await model.refreshModels()
                }
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
