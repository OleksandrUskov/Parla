import SwiftUI
import ParlaCore

/// iOS root shell (iOS-port P1.4a). A `TabView` fuses what macOS splits across a sidebar window + MenuBarExtra
/// + Settings scene (IOS_P1_4_UI §2): History (import + list + reading detail) and the model Manager (P1.4i).
struct RootTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            HistoryListView()
                .tabItem { Label(L("history.title"), systemImage: "waveform") }
            ModelManagerView()
                .tabItem { Label(L("model.manager.title"), systemImage: "square.stack.3d.up.fill") }
        }
        .tint(Brand.accent)
        .id(model.uiLanguage)   // re-resolve verbatim L() strings live on a UI-language switch (mirrors macOS ContentView:43)
    }
}
