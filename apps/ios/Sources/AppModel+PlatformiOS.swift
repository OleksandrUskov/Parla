#if os(iOS)
import UIKit
import ParlaCore

/// iOS wiring for `AppModel`'s platform seams — the counterpart of the macOS `AppModel.mac()` factory. The Core
/// declares platform behaviors as injectable closures with inert Foundation-only defaults so it stays UI-toolkit
/// free; each app installs the real implementations. This keeps `AppModel` + `TranscriptionEngine` portable and
/// is what let the whole transcription path move to iOS unchanged (see IOS_PORT.md §1).
extension AppModel {
    /// The iOS app-facing constructor: a default `AppModel` with the in-process decoder + UIKit seams wired in.
    /// The macOS-only seams (NSSavePanel export, synthetic ⌘V paste, folder-watch, the floating toast panel)
    /// deliberately keep their inert Core defaults — the iOS UI layer (P1.4) provides ShareLink / `.fileExporter`
    /// equivalents where they make sense. Unit tests that want the pure Core keep using `AppModel()` directly.
    @MainActor static func iOS() -> AppModel {
        let m = AppModel()

        // Audio decode / chunking → the in-process ParlaCore decoder (libopusfile + AVAssetReader). This is the
        // iOS replacement for the macOS ffmpeg subprocess and closes the drop → decode → WhisperKit pipeline.
        m.decoder = OpusAudioDecoder()

        m.copyToClipboard = { text in UIPasteboard.general.string = text }
        m.isAppActive = { UIApplication.shared.applicationState == .active }

        return m
    }
}
#endif
