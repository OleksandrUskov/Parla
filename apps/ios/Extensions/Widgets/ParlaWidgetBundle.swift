import WidgetKit
import SwiftUI

/// The ParlaWidgets extension entry point. A WidgetBundle so it can grow: the transcription
/// Live Activity now; the Home-screen widget + iOS-18 Control land later.
@main
struct ParlaWidgetBundle: WidgetBundle {
    var body: some Widget {
        ParlaTranscriptionLiveActivity()   // transcription Live Activity / Dynamic Island
        ParlaHomeWidget()                  // recent-transcripts glance
    }
}
