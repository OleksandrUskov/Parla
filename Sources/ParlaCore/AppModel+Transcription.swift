import SwiftUI

/// One queued manual-drop job: a batch of URLs waiting for the transcription lane. A drop while the lane
/// is busy is APPENDED here (not discarded), so the user can stack "5 files, then 5 more".
public struct TranscriptionJob: Identifiable {
    public let id = UUID()
    public let urls: [URL]
}

/// Transcription pipeline: drop → (conversion → model load → recognition) → history,
/// plus «re-transcribe» (feature 01), which reuses the same `transcribeOne`.
extension AppModel {
    /// A dropped batch. Instead of REJECTING a drop while busy (old behavior), we QUEUE it and pump the
    /// lane — so stacked drops run one after another. Shares the isBusy lane with folder-watch.
    public func handleDrop(urls: [URL]) {
        enqueueManual(urls)
    }

    /// Append a manual-drop batch to the queue and pump the lane.
    public func enqueueManual(_ urls: [URL]) {
        transcriptionQueue.append(TranscriptionJob(urls: urls))
        pumpQueues()
    }

    /// Total transcription jobs waiting (manual drops + watched files) — drives the "+N queued" badge.
    public var queuedCount: Int { transcriptionQueue.count + watchQueue.count }

    /// Start the next MANUAL job if the lane is free (mirrors folder-watch `drainQueue`). Claims the phase
    /// synchronously so a second drop in the same tick can't double-start — it just queues behind this one.
    public func drainManualQueue() {
        guard !isBusy, downloadingModel == nil, !transcriptionQueue.isEmpty else { return }
        let job = transcriptionQueue.removeFirst()
        phase = .preparing("…")   // claim the phase synchronously — closes the double-start race
        currentTranscriptionTask = Task {
            await transcribe(urls: job.urls)
            currentTranscriptionTask = nil
            cancelling = false    // robustness: clear "Stopping…" however transcribe exited (belt-and-suspenders vs the in-loop reset)
            pumpQueues()          // lane freed → pull the next job
        }
    }

    /// Stop the running MANUAL transcription + drop everything queued behind it. The in-flight file/chunk
    /// can't be aborted mid-decode (WhisperKit has no early-stop), so it finishes the current unit and then
    /// its result is DISCARDED — nothing partial is saved. Already-completed files in the batch stay. The
    /// folder-watcher is untouched (it has no `currentTranscriptionTask`); only the user's manual run stops.
    public func cancelTranscription() {
        // Free the import-container copies of every QUEUED job we're dropping (iOS): they were copied upfront and
        // will never be transcribed now, and — unlike the in-flight batch — they're not referenced by
        // `lastAttemptedURLs`, so «Try again» can't need them. No-op on macOS originals (imports-root prefix guard).
        // (cancelled queued jobs used to leak their copies.)
        transcriptionQueue.forEach { $0.urls.forEach { Self.pruneImportedSource($0.path) } }
        transcriptionQueue.removeAll()
        // Stop the DECODE too, not just the task. A detached decode ignores task cancellation, so before this
        // the Cancel button did nothing at all until the decode finished on its own — on a long file, minutes.
        decodeControl?.cancel()
        guard let task = currentTranscriptionTask else { return }
        cancelling = true          // "Stopping…" until the current file/chunk finishes and the loop breaks
        task.cancel()
    }

    /// One pump for BOTH lanes whenever the lane may have freed (job finished, dictation ended, …).
    /// Manual (user-initiated) drains first; if it claims the lane, the watch drain then no-ops on isBusy.
    public func pumpQueues() {
        drainManualQueue()
        drainWatchQueue()
    }

    /// Remember the last successfully transcribed source (for «replay the last file»). Pure bookmark write —
    /// lives in Core because the transcription loop calls it (the macOS quick-actions extension reads it back).
    public func rememberSource(_ url: URL) {
        if let data = try? url.bookmarkData() {   // plain bookmark (the app is not sandboxed)
            UserDefaults.standard.set(data, forKey: Keys.lastBookmark)
        }
    }

    /// Clear a stuck error chip (.failed → .idle). No-op otherwise.
    public func dismissError() { if case .failed = phase { phase = .idle } }

    /// Whether «Try again» can re-run the last attempted input.
    public var canRetryLast: Bool { !lastAttemptedURLs.isEmpty && !isBusy && downloadingModel == nil }

    /// Re-run the last attempted input after a failure — single-flight via handleDrop.
    public func retryLast() {
        guard canRetryLast else { return }
        handleDrop(urls: lastAttemptedURLs)
    }

    /// Whether a finished run plays the completion sound: user-initiated runs always do (when enabled);
    /// the folder watcher only when nothing else is queued — so a burst of N files beeps ONCE, not N times.
    public nonisolated static func shouldPlayCompletionSound(soundEnabled: Bool, isWatcherRun: Bool, watchQueueEmpty: Bool) -> Bool {
        soundEnabled && (!isWatcherRun || watchQueueEmpty)
    }

    public func transcribe(urls: [URL], isWatcherRun: Bool = false) async {
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
        // Batch (multiple files or a folder) is Pro; free = one file at a time → show the upsell, transcribe none.
        if batchIsGated(fileCount: files.count) {
            phase = .idle
            return
        }
        let total = files.count
        let jobStart = Date()
        var failures: [String] = []
        var succeeded = 0
        var gated: [(name: String, dur: Double)] = []   // files blocked by the free-tier length cap → up-front upsell
        for (i, url) in files.enumerated() {
            if Task.isCancelled { break }   // cancelled → stop pulling more files (already-saved ones stay)
            // FREE-tier length gate (stateless): a non-Pro user's over-cap file is skipped BEFORE any decode or
            // model work — the graceful up-front upsell (never cut mid-transcript). Pro users skip the probe
            // entirely (zero added latency). `mediaDuration` covers EVERY supported format: Ogg/Opus (incl.
            // extension-less Telegram voices) via opusfile's index, everything else via AVURLAsset.
            if !isProUser(), let dur = await mediaDuration(url),
               ProGate.exceedsFreeLimit(durationSec: dur, isPro: false) {
                gated.append((url.lastPathComponent, dur))
                continue
            }
            // Show the queue position only for a batch (>1 file); a single drop looks like before.
            let batch = total > 1 ? BatchProgress(index: i + 1, total: total, done: i) : nil
            do {
                let r = try await transcribeOne(url: url, model: selectedModel, batch: batch)
                if Task.isCancelled { break }   // decode finished but user cancelled → DISCARD this result, don't save
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
                // A pinned language that doesn't match the audio is the most expensive silent failure in the
                // app (measured: 49.85% word errors against 5.57%), and until now nothing surfaced it.
                languageSuggestion = LanguageMismatch.suggestion(for: item.id, pinned: language, heard: r.heard)
                Task { await refreshSemanticIndex() }   // extractive title/summary + search embedding
                if autoCopy, !r.text.isEmpty { copy(item.text) }
                succeeded += 1
                rememberSource(url)            // for «repeat last file»
                // Prepare the player audio AFTER the text is shown; patch the entry by id (the player shows up a bit later).
                let kept = await Self.keepAudio(from: url, id: item.id, using: decoder)
                if (kept.file != nil || kept.playable != nil),
                   let idx = history.firstIndex(where: { $0.id == item.id }) {
                    history[idx].audioFile = kept.file
                    history[idx].audioPlayable = kept.playable
                    HistoryStore.save(history)
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                failures.append("\(url.lastPathComponent) (\(msg))")
                // NB: do NOT prune url's iOS import copy here — `lastAttemptedURLs` still points at it and «Try again»
                // (retryLast) must be able to re-decode it. Abandoned failed copies are swept at next launch by
                // pruneImportedOrphans (AppModel.iOS()). (fixes the «Try again» regression.)
            }
        }
        if Task.isCancelled {                 // user hit Cancel: don't beep / notify / show a "done" toast
            if quickModeRun { hideToast() }   // clear the sticky "Recognizing…" toast of a cancelled quick run
            cancelling = false
            quickModeRun = false
            phase = .idle
            refreshDownloaded()
            await pruneAudioCache()            // keep the audio cache bounded even on a cancelled batch
            return
        }
        // Pure-gate outcome: every dropped file was blocked by the free length cap (nothing decoded or failed).
        // The paywall IS the feedback — skip the "done" sound / notification / toast.
        if succeeded == 0, failures.isEmpty, !gated.isEmpty {
            refreshDownloaded()
            phase = .idle
            // A quick-mode run (menu bar / Services / Shortcuts) may have no open window to host the paywall
            // sheet → give it a toast (replaces the sticky "Recognizing…") so the upsell isn't a silent no-op.
            if quickModeRun { quickModeRun = false; showToast(L("toast.pro.needed"), false) }
            paywallReason = gated.first.map { .lengthExceeded(fileName: $0.name, durationSec: $0.dur) }
            await pruneAudioCache()
            return
        }
        refreshDownloaded()
        phase = failures.isEmpty ? .idle : .failed(Lf("error.transcribe.failed", failures.joined(separator: "; ")))
        if Self.shouldPlayCompletionSound(soundEnabled: soundOnComplete, isWatcherRun: isWatcherRun,
                                          watchQueueEmpty: watchQueue.isEmpty && transcriptionQueue.isEmpty) {  // coalesce across BOTH lanes: a watch run stays silent if a manual job is queued behind it (it beeps instead)
            playCompletionSound(failures.isEmpty)
        }

        // Notification: only if the job «was worth the wait» and the window isn't frontmost.
        // Read frontmost at the END — switching away during the batch is exactly what should trigger a notification.
        let elapsed = Date().timeIntervalSince(jobStart)
        // Frontmost via the `isAppActive` platform seam (macOS wires NSApplication.shared.isActive); the inert
        // Core/XCTest default reports "not frontmost", so this stays AppKit-free and portable.
        if BatchNotifier.shouldNotify(total: total, elapsed: elapsed, frontmost: isAppActive()) {
            await postNotification(succeeded, failures.count)
        }

        // Toast for quick mode (hotkey/menu bar) — the user has no open window with a chip.
        if quickModeRun {
            quickModeRun = false
            if !failures.isEmpty {
                showToast(L("toast.failed"), false)
            } else {
                showToast(autoCopy ? L("toast.done.copied") : L("toast.done"), false)
            }
        }

        // Mixed batch: some files ran, some were gated by the free cap → still surface the upsell for the blocked ones.
        if let g = gated.first { paywallReason = .lengthExceeded(fileName: g.name, durationSec: g.dur) }
        await pruneAudioCache()   // keep the audio cache within its limit (we don't touch the text)
    }

    /// One file → EngineResult: conversion → model load (downloading if needed) →
    /// recognition. Sets the phases itself (accounting for the batch position). Throws on error.
    /// Shared path for a fresh drop and «re-transcribe».
    private func transcribeOne(url: URL, model: String, batch: BatchProgress? = nil) async throws -> EngineResult {
        phase = .preparing(url.lastPathComponent, batch: batch)

        // Decide the long-audio path from the SOURCE, before spending anything on it. This used to decode the
        // whole file to one big WAV and THEN re-read that WAV to cut chunks: two full decode passes, and at peak
        // the intermediate WAV plus every chunk on disk simultaneously — gigabytes for a multi-hour recording,
        // on exactly the feature Pro is sold for. The chunker reads the original container perfectly well, so
        // the intermediate never needed to exist. `mediaDuration` is the same probe the free-tier length gate
        // uses, so it already measures Ogg/Opus (which AVFoundation cannot) without decoding.
        if let sourceDuration = await mediaDuration(url),
           AudioChunker.shouldChunk(durationSec: sourceDuration, chunkingAvailable: decoder.isChunkingAvailable) {
            return try await transcribeChunked(source: url, model: model, audioDuration: sourceDuration)
        }

        // AVFoundation opens these containers directly (WhisperKit loads via AVAudioFile + resamples to
        // 16 kHz itself) → hand the engine the ORIGINAL file and skip decode entirely.
        // Everything else (Ogg/Opus, flac, mp4/mov/m4v, 3gp) goes through the in-process native decoder
        // (opusfile / AVAssetReader — Phase 2c; iOS + macOS, no ffmpeg subprocess).
        // NOTE: `wavPath:` is a historical name — for an AVFoundation format it's the source path, not a WAV.
        let decodePath: String
        let tempWav: URL?
        if Self.avDecodable.contains(url.pathExtension.lowercased()) {
            decodePath = url.path
            tempWav = nil
        } else {
            let decoder = self.decoder      // capture the seam (the native in-process decoder in production, stub in tests)
            // `Task.detached` does NOT inherit cancellation, which is exactly why Cancel did nothing during a
            // decode. The control is the way in: the button flips it and the read loop throws.
            let control = DecodeControl()
            decodeControl = control
            defer { decodeControl = nil }
            let wav = try await Task.detached(priority: .userInitiated) {
                try decoder.decodeToWav16k(url, control: control)
            }.value
            decodePath = wav.path
            tempWav = wav
        }
        defer { if let tempWav { try? FileManager.default.removeItem(at: tempWav) } }

        // Fallback for a source whose length the probe above could not determine: measure the DECODED audio and
        // chunk from there. This is the old path, kept because "unknown duration" must not silently lose chunking —
        // it just no longer runs for the ordinary case, which is what removes the double decode.
        let dur = await Task.detached(priority: .userInitiated) { AudioDuration.seconds(ofFileAt: decodePath) }.value
        if let dur, AudioChunker.shouldChunk(durationSec: dur, chunkingAvailable: decoder.isChunkingAvailable) {
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
        let decoder = self.decoder
        let control = DecodeControl()
        decodeControl = control
        defer { decodeControl = nil }
        let chunks = try await Task.detached(priority: .userInitiated) {
            try decoder.splitIntoChunks(source, chunkLength: AudioChunker.chunkLengthSec, control: control)
        }.value
        // Delete the chunk DIRECTORY, never a directory that merely contains chunks. This line trusted the
        // decoder's "chunks live in their own temp dir" contract absolutely, and recursive deletion is not
        // something to trust: a decoder that returned a chunk straight from the shared temp directory made this
        // delete /var/folders/<user>/T itself, taking every other process's files with it. Proven with a
        // sentinel file. The guard is deliberately about the real hazard — never remove the temp ROOT — rather
        // than a naming convention, which would only move the assumption somewhere else.
        let tempRoot = FileManager.default.temporaryDirectory.standardizedFileURL
        let parent = chunks.first?.deletingLastPathComponent().standardizedFileURL
        let chunkDir: URL? = {
            guard let parent else { return nil }
            guard parent.path != tempRoot.path, parent.path.hasPrefix(tempRoot.path) else {
                assertionFailure("refusing to delete \(parent.path): chunks must live in their own temp dir")
                return nil
            }
            return parent
        }()
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
            if Task.isCancelled { break }   // cancelled → stop decoding more chunks (the partial is discarded upstream)
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

    public func progressHandler() -> @Sendable (ModelLoad) -> Void {   // internal: also reused by +Dictation
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
    public func canRetranscribe(_ item: TranscriptItem) -> Bool {
        !isBusy && downloadingModel == nil && item.hasResolvableSource
    }

    /// Re-run an entry on a different model, replacing its contents IN PLACE (same id/position).
    public func retranscribe(_ item: TranscriptItem, with model: String, allowingSameModel: Bool = false) {
        guard !isBusy, downloadingModel == nil else { return }
        // Same model is normally a no-op — except when something OTHER than the model changed, which is exactly
        // the wrong-language case: same weights, different language, completely different transcript.
        guard allowingSameModel || model != item.model else { return }
        // Free-tier length gate: re-transcribing an over-cap note is a fresh transcription too, so gate it for a
        // non-Pro user (parity with a fresh drop — otherwise a migrated/refunded free user re-runs a long history
        // note unlimited for free). Uses the note's KNOWN duration, so it also covers Ogg/Opus that the fresh-drop
        // AVFoundation probe can't measure.
        if !isProUser(), ProGate.exceedsFreeLimit(durationSec: item.durationSec, isPro: false) {
            paywallReason = .lengthExceeded(fileName: item.sourceName, durationSec: item.durationSec)
            return
        }
        // A re-transcribe is NOT a "last drop": clear it so the error chip's «Try again» (which replays
        // lastAttemptedURLs) can't fire the wrong file/model if this re-transcribe fails.
        lastAttemptedURLs = []
        phase = .preparing(item.sourceName)                   // claim the phase synchronously — closes the race (like handleDrop)
        currentTranscriptionTask = Task {                     // stored → the chip's Cancel button works for a re-transcribe too
            await runRetranscribe(item, with: model)
            currentTranscriptionTask = nil
            cancelling = false    // clear "Stopping…" however runRetranscribe exited
            pumpQueues()          // lane freed → start any file queued during this re-transcribe (nil FIRST so a new job's handle isn't clobbered)
        }
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
                if Task.isCancelled { phase = .idle; return }   // cancelled during the decode → KEEP the old transcript, apply nothing
                // If the audio was evicted by the cache and the source is in hand now — restore the copy
                // for the player (otherwise the freshly re-transcribed entry would be left without a player). BEFORE the mutation.
                var restored: (file: String?, playable: String?)?
                if let cur = history.first(where: { $0.id == item.id }),
                   cur.audioFile == nil, cur.audioPlayable == nil {
                    restored = await Self.keepAudio(from: url, id: item.id, using: decoder)
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
                    invalidateDerivedData(for: item.id)   // text fully changed → recompute search/Related/insights
                    HistoryStore.save(history)
                    if autoCopy, !r.text.isEmpty { copy(updated.text) }
                }
                phase = .idle   // transcript is ready → clear "busy" BEFORE the background semantic recompute
                await refreshSemanticIndex()   // re-embed + re-lemmatize + re-insight from the new text (inline → test-safe)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                phase = .failed(Lf("error.retranscribe.failed", msg))
            }
        }
        refreshDownloaded()   // the target model may have just been downloaded (pump happens in the retranscribe wrapper)
    }
}
