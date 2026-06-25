import AppKit

/// macOS Services provider (OS_INTEGRATION): "Transcribe with Parla" in Finder right-click and every
/// app's Services menu for audio-file selections. Collects the selected file URLs and routes them into
/// the existing race-safe `handleDrop` funnel — no new transcription logic.
final class ServicesProvider: NSObject {
    private weak var model: AppModel?
    init(model: AppModel) { self.model = model; super.init() }

    /// Info.plist `NSMessage` = "transcribeFiles" maps to this exact AppKit selector signature
    /// (`_:userData:error:`). A signature mismatch silently no-ops — the classic Services footgun.
    @objc func transcribeFiles(_ pasteboard: NSPasteboard, userData: String?,
                               error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        let audio = PasteboardReader.audioOnly(urls)   // reuse the tested clipboard filter
        guard !audio.isEmpty else { return }
        let model = self.model                          // AppKit calls this on main; read the weak ref here
        Task { @MainActor in
            model?.quickModeRun = true                  // toast feedback — a Finder service has no window
            model?.handleDrop(urls: audio)
        }
    }
}
