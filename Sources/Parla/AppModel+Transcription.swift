import SwiftUI
import AppKit

/// Transcription pipeline: drop → (conversion → model load → recognition) → history,
/// plus «re-transcribe» (feature 01), which reuses the same `transcribeOne`.
extension AppModel {
    func handleDrop(urls: [URL]) {
        guard !isBusy, downloadingModel == nil else { return }
        phase = .preparing("…")   // claim the phase synchronously — closes the double-drop race
        Task { await transcribe(urls: urls) }
    }

    func transcribe(urls: [URL]) async {
        var files: [URL] = []
        for url in urls {
            if url.hasDirectoryPath { files.append(contentsOf: Self.audioFiles(in: url)) }
            else { files.append(url) }
        }
        guard !files.isEmpty else {
            phase = .failed(L("error.noaudio"))
            return
        }
        let total = files.count
        let jobStart = Date()
        var failures: [String] = []
        var succeeded = 0
        for (i, url) in files.enumerated() {
            // Show the queue position only for a batch (>1 file); a single drop looks like before.
            let batch = total > 1 ? BatchProgress(index: i + 1, total: total, done: i) : nil
            do {
                let r = try await transcribeOne(url: url, model: selectedModel, batch: batch)
                let item = TranscriptItem(
                    sourceName: url.lastPathComponent,
                    language: r.language,
                    durationSec: r.duration,
                    model: selectedModel,
                    text: r.text.isEmpty ? L("transcript.silence") : r.text,
                    segments: r.segments,
                    sourcePath: url.path,                       // remember the source for «re-transcribe»
                    sourceBookmark: makeSourceBookmark(url)
                )
                // SHOW THE RESULT IMMEDIATELY — don't wait for the audio copy/render for the player.
                history.insert(item, at: 0)
                selection = item.id
                HistoryStore.save(history)
                if autoCopy, !r.text.isEmpty { copy(item.text) }
                succeeded += 1
                rememberSource(url)            // for «repeat last file»
                // Prepare the player audio AFTER the text is shown; patch the entry by id (the player shows up a bit later).
                let kept = await Self.keepAudio(from: url, id: item.id)
                if (kept.file != nil || kept.playable != nil),
                   let idx = history.firstIndex(where: { $0.id == item.id }) {
                    history[idx].audioFile = kept.file
                    history[idx].audioPlayable = kept.playable
                    HistoryStore.save(history)
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                failures.append("\(url.lastPathComponent) (\(msg))")
            }
        }
        refreshDownloaded()
        phase = failures.isEmpty ? .idle : .failed(Lf("error.transcribe.failed", failures.joined(separator: "; ")))

        // Notification: only if the job «was worth the wait» and the window isn't frontmost.
        // Read frontmost at the END — switching away during the batch is exactly what should trigger a notification.
        let elapsed = Date().timeIntervalSince(jobStart)
        if BatchNotifier.shouldNotify(total: total, elapsed: elapsed, frontmost: NSApp.isActive) {
            await BatchNotifier.post(succeeded: succeeded, failed: failures.count)
        }

        // Toast for quick mode (hotkey/menu bar) — the user has no open window with a chip.
        if quickModeRun {
            quickModeRun = false
            if !failures.isEmpty {
                QuickToast.shared.show(L("toast.failed"))
            } else {
                QuickToast.shared.show(autoCopy ? L("toast.done.copied") : L("toast.done"))
            }
        }

        await pruneAudioCache()   // keep the audio cache within its limit (we don't touch the text)
    }

    /// One file → EngineResult: conversion → model load (downloading if needed) →
    /// recognition. Sets the phases itself (accounting for the batch position). Throws on error.
    /// Shared path for a fresh drop and «re-transcribe».
    private func transcribeOne(url: URL, model: String, batch: BatchProgress? = nil) async throws -> EngineResult {
        phase = .preparing(url.lastPathComponent, batch: batch)
        let wav = try await Task.detached(priority: .userInitiated) {
            try AudioConverter.toWav16k(url)
        }.value
        defer { try? FileManager.default.removeItem(at: wav) }

        phase = .loadingModel
        try await engine.ensureLoaded(model: model, progress: progressHandler())

        phase = .transcribing(url.lastPathComponent, batch: batch)
        let lang = language.isEmpty ? nil : language
        return try await engine.transcribe(wavPath: wav.path, language: lang,
                                           model: model, translate: translateToEnglish)
    }

    private func progressHandler() -> @Sendable (ModelLoad) -> Void {
        { [weak self] load in
            Task { @MainActor in
                guard let self else { return }
                switch load {
                case .downloading(let p): self.phase = .downloadingModel(p)
                case .loading: self.phase = .loadingModel
                }
            }
        }
    }

    // MARK: Re-transcribe (feature 01)

    /// Whether the entry can be re-transcribed: the engine is free and the source is available.
    func canRetranscribe(_ item: TranscriptItem) -> Bool {
        !isBusy && downloadingModel == nil && item.hasResolvableSource
    }

    /// Re-run an entry on a different model, replacing its contents IN PLACE (same id/position).
    func retranscribe(_ item: TranscriptItem, with model: String) {
        guard !isBusy, downloadingModel == nil else { return }
        guard model != item.model else { return }            // same model — nothing to recompute
        phase = .preparing(item.sourceName)                   // claim the phase synchronously — closes the race (like handleDrop)
        Task { await runRetranscribe(item, with: model) }
    }

    private func runRetranscribe(_ item: TranscriptItem, with model: String) async {
        // Resolve the source INSIDE the task: the file could have vanished between opening the menu and confirming.
        switch item.resolveSource() {
        case .missing:
            phase = .failed(Lf("error.source.missing", item.sourceName))
        case .found(let url, let scoped):
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let r = try await transcribeOne(url: url, model: model)
                // If the audio was evicted by the cache and the source is in hand now — restore the copy
                // for the player (otherwise the freshly re-transcribed entry would be left without a player). BEFORE the mutation.
                var restored: (file: String?, playable: String?)?
                if let cur = history.first(where: { $0.id == item.id }),
                   cur.audioFile == nil, cur.audioPlayable == nil {
                    restored = await Self.keepAudio(from: url, id: item.id)
                }
                // Resolve the index AFTER all awaits — history could have shifted (background transcription).
                if let idx = history.firstIndex(where: { $0.id == item.id }) {
                    var updated = history[idx]
                    updated.language    = r.language
                    updated.durationSec = r.duration
                    updated.model       = model
                    updated.text        = r.text.isEmpty ? L("transcript.silence") : r.text
                    updated.segments    = r.segments
                    updated.date        = Date()
                    updated.edited      = nil   // fresh recognition → clear the manual-edit flag (timecodes are valid again)
                    updated.editedAt    = nil
                    if let restored {
                        updated.audioFile = restored.file
                        updated.audioPlayable = restored.playable
                    }
                    history[idx] = updated      // IN-PLACE replacement: id/position/sourcePath preserved
                    selection = updated.id
                    HistoryStore.save(history)
                    if autoCopy, !r.text.isEmpty { copy(updated.text) }
                }
                phase = .idle
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                phase = .failed(Lf("error.retranscribe.failed", msg))
            }
        }
        refreshDownloaded()   // the target model may have just been downloaded
    }
}
