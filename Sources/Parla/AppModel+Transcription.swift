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

    /// Clear a stuck error chip (.failed → .idle). No-op otherwise.
    func dismissError() { if case .failed = phase { phase = .idle } }

    /// Whether «Try again» can re-run the last attempted input.
    var canRetryLast: Bool { !lastAttemptedURLs.isEmpty && !isBusy && downloadingModel == nil }

    /// Re-run the last attempted input after a failure — single-flight via handleDrop.
    func retryLast() {
        guard canRetryLast else { return }
        handleDrop(urls: lastAttemptedURLs)
    }

    func transcribe(urls: [URL]) async {
        lastAttemptedURLs = urls   // remember for «Try again»
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
        if soundOnComplete { failures.isEmpty ? CompletionSound.success() : CompletionSound.failure() }

        // Notification: only if the job «was worth the wait» and the window isn't frontmost.
        // Read frontmost at the END — switching away during the batch is exactly what should trigger a notification.
        let elapsed = Date().timeIntervalSince(jobStart)
        // NSApplication.shared (not NSApp): the latter is nil until the app instance exists → would crash under tests.
        if BatchNotifier.shouldNotify(total: total, elapsed: elapsed, frontmost: NSApplication.shared.isActive) {
            await postNotification(succeeded, failures.count)
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

        // AVFoundation opens these containers directly (WhisperKit loads via AVAudioFile + resamples to
        // 16 kHz itself) → hand the engine the ORIGINAL file and skip the ffmpeg re-encode entirely.
        // Everything else (Ogg/Opus, amr, webm, flac, video, …) still goes through ffmpeg as before.
        // NOTE: `wavPath:` is a historical name — for an AVFoundation format it's the source path, not a WAV.
        let decodePath: String
        let tempWav: URL?
        if Self.avDecodable.contains(url.pathExtension.lowercased()) {
            decodePath = url.path
            tempWav = nil
        } else {
            let convert = wavConverter      // capture the seam (real ffmpeg in production, stub in tests)
            let wav = try await Task.detached(priority: .userInitiated) {
                try convert(url)
            }.value
            decodePath = wav.path
            tempWav = wav
        }
        defer { if let tempWav { try? FileManager.default.removeItem(at: tempWav) } }

        // A long recording → chunked pipeline: bounded memory + real per-chunk progress, EVEN inside a
        // folder batch (a long file mustn't bypass chunking just because it was dropped with others).
        // Needs ffmpeg to split; the no-ffmpeg / unknown-duration cases fall through to single-pass.
        // The duration probe opens the file via AVAudioFile → run it off the main actor.
        let dur = await Task.detached(priority: .userInitiated) { AudioConverter.duration(of: decodePath) }.value
        if let dur, AudioChunker.shouldChunk(durationSec: dur, ffmpegAvailable: AudioConverter.isFFmpegAvailable) {
            return try await transcribeChunked(source: URL(fileURLWithPath: decodePath),
                                               model: model, audioDuration: dur)
        }

        phase = .loadingModel
        try await engine.ensureLoaded(model: model, progress: progressHandler())

        phase = .transcribing(url.lastPathComponent, batch: batch)
        let lang = language.isEmpty ? nil : language
        return try await engine.transcribe(wavPath: decodePath, language: lang,
                                           model: model, translate: translateToEnglish)
    }

    /// Long-audio path: split into ~2-min chunks, transcribe each (per-chunk progress via the existing
    /// BatchProgress bar), then stitch the per-chunk timecodes into one global timeline. One chunk is
    /// in flight at a time → memory stays bounded regardless of total length. A failed chunk is recorded
    /// as a placeholder so the rest of the transcript survives.
    private func transcribeChunked(source: URL, model: String, audioDuration: Double) async throws -> EngineResult {
        let chunks = try await Task.detached(priority: .userInitiated) {
            try AudioConverter.splitIntoChunks(source, chunkLength: AudioChunker.chunkLengthSec)
        }.value
        let chunkDir = chunks.first?.deletingLastPathComponent()
        defer { if let chunkDir { try? FileManager.default.removeItem(at: chunkDir) } }

        phase = .loadingModel
        try await engine.ensureLoaded(model: model, progress: progressHandler())
        let lang = language.isEmpty ? nil : language

        // Split produced nothing → fall back to a single pass on the whole file.
        guard !chunks.isEmpty else {
            phase = .transcribing(source.lastPathComponent)
            return try await engine.transcribe(wavPath: source.path, language: lang,
                                               model: model, translate: translateToEnglish)
        }

        let total = chunks.count
        var perChunkSegments: [[Segment]] = []
        var texts: [String] = []
        var langs: [String] = []
        for (k, chunk) in chunks.enumerated() {
            phase = .transcribing(Lf("chunk.label", k + 1, total),
                                  batch: BatchProgress(index: k + 1, total: total, done: k))
            do {
                let r = try await engine.transcribe(wavPath: chunk.path, language: lang,
                                                    model: model, translate: translateToEnglish)
                perChunkSegments.append(r.segments)
                texts.append(r.text)
                langs.append(r.language)
            } catch {
                // resilience: one bad chunk doesn't lose the whole transcript. Put the marker in BOTH
                // the segments AND the flat text, so the gap is visible in copy/TXT/MD (not only SRT/VTT).
                let mark = Lf("chunk.failed", k + 1)
                perChunkSegments.append([AudioChunker.failedChunkSegment(label: mark)])
                texts.append(mark)
                langs.append("")
            }
            try? FileManager.default.removeItem(at: chunk)   // free each chunk WAV as we go
        }
        let stitched = AudioChunker.stitch(chunkSegments: perChunkSegments,
                                           chunkLength: AudioChunker.chunkLengthSec)
        let fullText = texts.filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Mirror the single-pass path: keep the engine-reported language (detected in Auto mode),
        // not the bare requested value — otherwise long Auto-mode files persist an empty language.
        return EngineResult(text: fullText,
                            language: AudioChunker.resolveLanguage(chunkLanguages: langs, requested: lang),
                            segments: stitched, duration: audioDuration)
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
        // A re-transcribe is NOT a "last drop": clear it so the error chip's «Try again» (which replays
        // lastAttemptedURLs) can't fire the wrong file/model if this re-transcribe fails.
        lastAttemptedURLs = []
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
