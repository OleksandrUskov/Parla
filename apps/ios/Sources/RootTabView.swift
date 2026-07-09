import SwiftUI
import ParlaCore

/// The root tabs. Owned by the shell ABOVE the language `.id` swap so the selected tab survives a UI-language
/// switch (the `.id(uiLanguage)` rebuild would otherwise reset an internal `@State` selection to the first tab,
/// bouncing the user out of Settings the moment they change the language there).
enum RootTab: Hashable { case history, models, settings }

/// iOS root shell (iOS-port P1.4a; Settings tab P2.1b). A `TabView` fuses what macOS splits across a sidebar
/// window + MenuBarExtra + Settings scene (IOS_P1_4_UI §2): History (import + list + reading detail), the model
/// Manager (P1.4i), and Settings (P2.1b).
struct RootTabView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: RootTab

    var body: some View {
        TabView(selection: $selection) {
            HistoryListView()
                .tabItem { Label(L("history.title"), systemImage: "waveform") }
                .tag(RootTab.history)
            ModelManagerView()
                .tabItem { Label(L("model.manager.title"), systemImage: "square.stack.3d.up.fill") }
                .tag(RootTab.models)
            SettingsView(onManageModels: { selection = .models })
                .tabItem { Label(L("settings.title"), systemImage: "gearshape") }
                .tag(RootTab.settings)
        }
        .tint(Brand.accent)
        .id(model.uiLanguage)   // re-resolve verbatim L() strings live on a UI-language switch (mirrors macOS ContentView:43)
    }
}
