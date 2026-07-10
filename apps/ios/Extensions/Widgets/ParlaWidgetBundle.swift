import WidgetKit
import SwiftUI

/// The ParlaWidgets extension entry point (iOS-port P2.3b). A WidgetBundle so it can grow: the transcription
/// Live Activity now (P2.3b); the Home-screen widget + iOS-18 Control land in P2.3c.
@main
struct ParlaWidgetBundle: WidgetBundle {
    var body: some Widget {
        ParlaTranscriptionLiveActivity()
    }
}
