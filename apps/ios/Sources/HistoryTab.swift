import SwiftUI
import ParlaCore

/// The History tab shell selector (iOS-port P2.2). Owns the `PlaybackController` HERE — ABOVE the compact↔regular
/// layout swap — so audio playback survives an iPad rotate / Split-View resize that tears down and rebuilds the
/// History subtree (a `@State` player inside the swapped shell would reset on every resize). Picks the compact
/// `HistoryListView` (iPhone, iPad narrow multitasking) vs the two-column `HistorySplitView` (iPad regular width).
struct HistoryTab: View {
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var player = PlaybackController()

    /// Gate on idiom AND size class — NEVER size class alone: an iPhone Plus/Max reports `.regular` width in
    /// landscape and would wrongly split the phone. Only an actual iPad at regular width gets the two-column shell.
    private var useSplit: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && hSize == .regular
    }

    var body: some View {
        if useSplit {
            HistorySplitView(player: player)
        } else {
            HistoryListView(player: player)
        }
    }
}
