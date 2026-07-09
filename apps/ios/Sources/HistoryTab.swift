import SwiftUI
import ParlaCore

/// The History tab shell selector (iOS-port P2.2). Owns the `PlaybackController` HERE — ABOVE the compact↔regular
/// layout swap — so audio playback survives an iPad rotate / Split-View resize that tears down and rebuilds the
/// History subtree (a `@State` player inside the swapped shell would reset on every resize). Picks the compact
/// `HistoryListView` (iPhone, iPad narrow) vs the `HistorySplitView` (iPad regular width) — the split branch is
/// added in P2.2b; for now every idiom is compact.
struct HistoryTab: View {
    @State private var player = PlaybackController()

    var body: some View {
        HistoryListView(player: player)
    }
}
