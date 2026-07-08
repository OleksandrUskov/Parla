import SwiftUI
import ParlaCore

/// iOS root shell (iOS-port P1.4a). A `TabView` fuses what macOS splits across a sidebar window + MenuBarExtra
/// + Settings scene (IOS_P1_4_UI §2). This is the SHELL: real tabs, the injected `AppModel.iOS()`, and
/// localized strings that PROVE the bundled `.lproj` resolves (`AppModel.init` already applied `setLanguage`).
/// The import / reading-detail / model-manager / settings content lands in P1.4b+.
struct RootTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            HistoryListView()
                .tabItem { Label(L("history.title"), systemImage: "waveform") }
            modelsTab
                .tabItem { Label(L("model.manager.title"), systemImage: "square.stack.3d.up.fill") }
        }
        .tint(Brand.accent)
    }

    /// Models = the future manager. For the shell it surfaces the RAM-adaptive default the factory picked —
    /// proving `AppModel.iOS()` is injected and the tier selector ran on this device.
    private var modelsTab: some View {
        NavigationStack {
            ZStack {
                AuroraBackground().ignoresSafeArea()
                VStack(spacing: 10) {
                    Text(L("model.recommended").capitalized)
                        .font(.headline)
                    Text(friendlyModel(model.selectedModel))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Brand.gradient)
                    Text(verbatim: model.selectedModel)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(32)
            }
            .navigationTitle(L("model.manager.title"))
        }
    }
}
