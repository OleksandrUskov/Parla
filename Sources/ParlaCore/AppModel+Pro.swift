import Foundation

/// Pro feature-gating entry points (Phase 3, beyond the length gate). Each returns/acts through the same
/// `isProUser` seam + sets `paywallReason` to upsell, so both apps gate identically and the logic is unit-testable.
extension AppModel {
    /// True if this export format is Pro-gated for the current (non-Pro) user — and, when so, sets `paywallReason`
    /// to upsell. A caller that gets `true` must NOT export. Free formats (TXT/Markdown) and Pro users get `false`.
    /// The single choke point both platforms consult (macOS `exportGated`; iOS checks it before rendering+sharing).
    public func exportIsGated(_ format: ExportFormat) -> Bool {
        guard !isProUser(), ProGate.isProExportFormat(format) else { return false }
        paywallReason = .featureLocked(.export)
        return true
    }

    /// Export a note gated by Pro (the macOS menu entry point): free = TXT/Markdown; Pro = + SRT/VTT/JSON.
    /// A gated tap shows the paywall instead of writing the file.
    public func exportGated(_ item: TranscriptItem, as format: ExportFormat) {
        if exportIsGated(format) { return }
        export(item, as: format)
    }

    /// Batch (a multi-file or folder drop) is Pro; free = one file per drop. Returns true (and upsells) when a
    /// non-Pro user's drop expands to more than one file — the caller then transcribes none of them.
    public func batchIsGated(fileCount: Int) -> Bool {
        guard !isProUser(), fileCount > 1 else { return false }
        paywallReason = .featureLocked(.batch)
        return true
    }

    /// Folder-watch (auto-transcribe a watched folder, macOS) is Pro. Returns true (and upsells) if a non-Pro
    /// user is turning it ON; the caller then leaves the toggle off.
    public func folderWatchEnableGated(_ turningOn: Bool) -> Bool {
        guard turningOn, !isProUser() else { return false }
        paywallReason = .featureLocked(.folderWatch)
        return true
    }
}
