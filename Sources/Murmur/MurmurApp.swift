import SwiftUI

@main
struct MurmurApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(model)
                .task { await model.refreshModels() }
        }
        .defaultSize(width: 940, height: 620)

        MenuBarExtra("Murmur", systemImage: model.isBusy ? "waveform.circle.fill" : "waveform") {
            MenuBarView().environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 480)
        }
    }
}
