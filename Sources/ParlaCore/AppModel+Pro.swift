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

    /// Generative AI power is Pro: the MLX/embed model downloads, the manual ✨ regenerate, and the per-chapter
    /// summaries. Returns true (and upsells) for a non-Pro user — the caller then does nothing. The AUTOMATIC
    /// extractive insights (title/keywords/one-line summary shown on load) are NOT gated here — those stay free.
    public func aiPowerIsGated() -> Bool {
        guard !isProUser() else { return false }
        paywallReason = .featureLocked(.aiPower)
        return true
    }
}

// MARK: - Wrong-language nudge

extension AppModel {
    /// The suggestion to actually SHOW — or nil.
    ///
    /// One place decides this, because a raw `languageSuggestion` is a global slot with no lifetime and that made
    /// it dangerous rather than merely untidy: it survived selecting another note, so on macOS the strip floated
    /// above whatever the user had opened and its button re-transcribed a DIFFERENT note — wiping that note's
    /// text and any manual edits. It also survived deleting the note it was about, leaving a permanent strip with
    /// a dead button. Both are gone if validity is asked, not assumed.
    public var activeLanguageSuggestion: LanguageSuggestion? {
        guard let suggestion = languageSuggestion else { return nil }
        guard suggestion.id == selection else { return nil }                    // only for the note on screen
        guard history.contains(where: { $0.id == suggestion.id }) else { return nil }   // …that still exists
        return suggestion
    }

    /// Whether accepting can actually do anything right now. Checked BEFORE anything is committed, because the
    /// accept path used to flip the app-wide speech language and consume the offer FIRST and then call
    /// `retranscribe`, which is free to decline — leaving the user with a permanently re-pinned language, no
    /// re-transcription, and no way to ask again.
    public var canApplyLanguageSuggestion: Bool {
        guard let suggestion = activeLanguageSuggestion else { return false }
        guard !isBusy, downloadingModel == nil else { return false }
        guard let item = history.first(where: { $0.id == suggestion.id }) else { return false }
        return isProUser() || !ProGate.exceedsFreeLimit(durationSec: item.durationSec, isPro: false)
    }

    /// Accept: switch the speech language to what the model heard and run THIS note again.
    ///
    /// Order matters. Nothing is committed until the re-transcription is known to be startable — in particular
    /// while a batch is still running, tapping this must not re-pin the language for the files that have not been
    /// transcribed yet (`transcribeOne` reads `language` live, per file). The offer stays on screen instead, so
    /// the user can accept it once the batch is done rather than losing it to a no-op.
    public func applyLanguageSuggestion() {
        guard let suggestion = activeLanguageSuggestion,
              let item = history.first(where: { $0.id == suggestion.id }) else { return }
        guard canApplyLanguageSuggestion else {
            // Over the free length cap is the one case worth surfacing: show the paywall, keep the offer.
            if !isProUser(), ProGate.exceedsFreeLimit(durationSec: item.durationSec, isPro: false) {
                paywallReason = .lengthExceeded(fileName: item.sourceName, durationSec: item.durationSec)
            }
            return
        }
        languageSuggestion = nil
        language = suggestion.detected
        retranscribe(item, with: item.model, allowingSameModel: true)
    }

    /// Decline. Deliberately no "never ask again": the check is per-note and only fires above a measured
    /// confidence, so a user who is right simply dismisses it and it does not come back for that note.
    public func dismissLanguageSuggestion() { languageSuggestion = nil }

    /// Display name for a language subtag, in the user's UI language. NOT capitalized: Slavic language names are
    /// lowercase mid-sentence, and «на Русский» is both miscased and in the wrong grammatical case — the template
    /// supplies the case, this supplies the word.
    public func languageDisplayName(_ subtag: String) -> String {
        Locale(identifier: uiLanguage.code).localizedString(forLanguageCode: subtag) ?? subtag.uppercased()
    }
}
