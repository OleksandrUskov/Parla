import Foundation

/// Live mic dictation (MIC_DICTATION v1): record the microphone → 16 kHz mono WAV (`MicRecorder`) →
/// transcribe it locally, reusing the same result handling as a file drop but **bypassing `wavConverter`**
/// (the WAV is already in WhisperKit's input format — `.wav` ∈ `avDecodable`). Clipboard-only in v1
/// (paste-into-frontmost is P2). 100% on-device — the only new permission is the Microphone.
extension AppModel {
    /// True while a dictation is being recorded (drives `isBusy`, the recording chip, and the menu label).
    var isRecordingDictation: Bool { recordingStartedAt != nil }

    /// Seconds the current dictation has been recording (0 when not recording) — for the live chip timer.
    var recordingElapsed: TimeInterval { recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    /// Whether a NEW dictation can start: engine free, nothing downloading, not already recording
    /// (`isBusy` already folds in the recording state).
    var canDictate: Bool { !isBusy && downloadingModel == nil }

    /// Pure gate (unit-tested): pre-warm the model on launch only for users who actually dictate (the
    /// dictation hotkey is enabled) AND when the model is already on disk (never trigger a download here).
    nonisolated static func shouldPrewarmModel(dictationHotkeyEnabled: Bool, modelDownloaded: Bool) -> Bool {
        dictationHotkeyEnabled && modelDownloaded
    }

    /// Pre-warm the model INTO MEMORY at app launch so the first dictation is instant instead of waiting a few
    /// seconds for the load. Silent + best-effort; ensureLoaded coalesces, so a dictation that starts mid-warm
    /// just joins the same load. Gated by `shouldPrewarmModel` (hotkey users, model already downloaded).
    func prewarmDictationModel() {
        guard Self.shouldPrewarmModel(dictationHotkeyEnabled: dictationHotkeyEnabled,
                                      modelDownloaded: TranscriptionEngine.isDownloaded(selectedModel)) else { return }
        let model = selectedModel
        Task { try? await engine.ensureLoaded(model: model, progress: { _ in }) }
    }

    /// Hotkey / menu-bar / Settings entry point: start recording, or stop+transcribe if already recording.
    func toggleDictation() {
        if isRecordingDictation { stopAndTranscribeDictation() }
        else { startDictation() }
    }

    // MARK: Hotkey routing (toggle vs hold-to-talk)

    enum DictationKeyEdge { case down, up }
    enum DictationAction: Equatable { case start, stop, toggle, ignore }

    /// Pure routing (unit-tested): which action a hotkey edge maps to under the current mode.
    /// Toggle mode acts on key-UP (press to start/stop); hold mode starts on key-DOWN, stops on key-UP.
    nonisolated static func dictationAction(for edge: DictationKeyEdge, mode: DictationMode) -> DictationAction {
        switch (edge, mode) {
        case (.down, .hold):   return .start
        case (.down, .toggle): return .ignore
        case (.up, .hold):     return .stop
        case (.up, .toggle):   return .toggle
        }
    }

    func dictationKeyDown() { perform(Self.dictationAction(for: .down, mode: dictationMode)) }
    func dictationKeyUp()   { perform(Self.dictationAction(for: .up, mode: dictationMode)) }

    private func perform(_ action: DictationAction) {
        switch action {
        case .start:  startDictation()
        case .stop:   stopAndTranscribeDictation()
        case .toggle: toggleDictation()
        case .ignore: break
        }
    }

    /// Begin recording after a mic-permission check. Single-flight: refuses while busy/downloading.
    func startDictation() {
        guard canDictate else { QuickToast.shared.show(L("toast.busy")); return }
        guard recorder == nil, !requestingMic else { return }
        requestingMic = true   // claim the lane synchronously (→ isBusy) so a drop can't race in during the prompt
        Task {
            // Clear the claim + re-pump the watch lane if the dictation aborts before a recorder is committed
            // (mic denied, start throws, or a newer start won).
            defer { requestingMic = false; if recorder == nil { pumpQueues() } }
            // Ask for mic permission BEFORE any recording UI appears. On first use the system prompt shows with
            // NOTHING claiming to record yet — the chip / timer / "Listening…" only start once capture actually
            // does (below). Avoids the "it's already recording while asking permission" feeling + a timer that
            // counts the dialog time.
            let granted = await MicRecorder.ensureMicAccess()
            // A newer start already committed a recorder → don't start a SECOND engine (orphans the first).
            guard recorder == nil else { return }
            guard granted else { QuickToast.shared.show(L("toast.mic.denied")); return }
            let rec = MicRecorder(vad: dictationVADEnabled ? SilenceDetector() : nil,
                                  streaming: dictationLiveStreaming)
            do {
                try rec.start(onAutoStop: { [weak self] in self?.stopAndTranscribeDictation() })
                recorder = rec
                recordingStartedAt = Date()         // NOW the recording UI appears — real capture has begun
                if dictationLiveStreaming { startStreamingLoop(for: rec) }   // live preview (full decode still saves)
            } catch {
                recorder = nil
                QuickToast.shared.show(L("toast.dictation.failed"))
            }
        }
    }

    /// Stop the recorder and transcribe the captured WAV (reusing the standard result path).
    func stopAndTranscribeDictation() {
        guard isRecordingDictation else { return }
        // Capture what the user SAW streaming (confirmed + the live tail) BEFORE stopStreamingLoop clears it.
        let streamed = streamedDictationText()
        stopStreamingLoop()   // end the live-preview loop
        // Stop pressed before capture began (e.g. during the first-run mic-permission prompt → the recorder
        // isn't created yet): silently cancel. Don't show a "didn't catch anything" error for a non-recording.
        guard let rec = recorder else { recordingStartedAt = nil; return }
        let wav = rec.stop()
        recorder = nil
        recordingStartedAt = nil
        guard let wav else { QuickToast.shared.show(L("error.dictation.empty")); return }
        if streamed.isEmpty {
            // No streamed preview (streaming off, or it produced nothing) → the plain record-then-transcribe path.
            phase = .preparing(L("dictation.label"))    // claim the phase synchronously (like handleDrop)
            Task { await finishDictation(wav: wav) }
        } else {
            // Hybrid: save the streamed text INSTANTLY, then refine it in place with the full decode. Claim the
            // single-flight lane SYNCHRONOUSLY here (refiningDictations → isBusy) so nothing can start a
            // concurrent job in the gap before the async refine begins. phase stays .idle (no busy chip — the
            // per-item "refining" badge is the only signal); the refine releases the lane when it finishes.
            let id = UUID()
            refiningDictations.insert(id)
            Task { await refineDictation(wav: wav, streamed: streamed, id: id) }
        }
    }

    /// The streamed preview as one string (confirmed prefix + the live tail) — what the user was looking at
    /// when they hit Stop. Empty when streaming wasn't running.
    private func streamedDictationText() -> String {
        guard isStreamingDictation else { return "" }
        return [dictationConfirmedText, dictationHypothesisText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Hybrid streaming save: insert the streamed preview as a record IMMEDIATELY (instant, WYSIWYG result,
    /// flagged "refining" in the UI), then run the full offline decode and replace the text in place for max
    /// accuracy. The instant result is never lost — an empty or failed decode keeps the streamed text. Paste
    /// + copy + the completion signal all fire on the instant insert, so Stop feels instantaneous.
    func refineDictation(wav: URL, streamed: String, id: UUID) async {
        defer { try? FileManager.default.removeItem(at: wav) }   // throwaway temp; keepAudio copies what it needs
        // Release the lane FIRST at exit (pumpQueues then sees isBusy false and can start a queued job).
        defer { pumpQueues() }
        defer { refiningDictations.remove(id) }
        let model = selectedModel

        // 1) Instant: the streamed text, marked refining (caller already claimed the lane via refiningDictations).
        let item = TranscriptItem(
            id: id,
            sourceName: Self.dictationTitle(date: Date()),
            language: language,              // best-known now; the refine corrects it
            durationSec: 0,                  // the refine fills the real duration
            model: model,
            text: streamed,
            segments: [],
            sourcePath: nil,                 // dictation has no re-transcribable source file
            sourceBookmark: nil
        )
        history.insert(item, at: 0)
        selection = id
        refiningDictations.insert(id)        // idempotent (caller pre-inserted); keeps the badge + the lane
        HistoryStore.save(history)
        if autoCopy || dictationPasteIntoFrontmost { copy(item.text) }
        if soundOnComplete { CompletionSound.success() }
        if dictationPasteIntoFrontmost { pasteDictationResult() }
        else { dictationToast(empty: false, failed: false) }

        // 2) Refine: full offline decode replaces the text in place (badge clears via the defer either way).
        do {
            try await engine.ensureLoaded(model: model, progress: { _ in })   // silent — the badge is the signal
            let lang = language.isEmpty ? nil : language
            let r = try await engine.transcribe(wavPath: wav.path, language: lang,
                                                model: model, translate: translateToEnglish)
            let clean = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Replace the text ONLY if the decode found something AND the user hasn't taken ownership by editing
            // it (the lane being busy hides the edit pencil, but guard anyway — never clobber a user edit). An
            // empty decode keeps the streamed text.
            if !clean.isEmpty, let idx = history.firstIndex(where: { $0.id == id }), !history[idx].isEdited {
                history[idx].text = clean
                history[idx].segments = r.segments
                history[idx].durationSec = r.duration
                history[idx].language = r.language
                invalidateDerivedData(for: id)   // refined text → drop vector/lemmas/insights from the rough stream
                HistoryStore.save(history)
            }
        } catch {
            // Refine failed → keep the instant streamed text (already saved, copied, pasted). Nothing to undo.
        }
        await refreshSemanticIndex()   // title/summary/search from the FINAL dictation text, not the rough stream (inline → test-safe)
        // Keep the audio if requested — regardless of whether the decode refined the text (the record exists).
        if keepDictationAudio { await keepDictationAudioFor(id, wav: wav) }
        await pruneAudioCache()
    }

    /// Transcribe a finished dictation WAV and fold the result into history. Bypasses `wavConverter`
    /// (the WAV is already 16 kHz mono). Best-effort + always toasts (dictation has no in-window chip flow).
    func finishDictation(wav: URL) async {
        defer { try? FileManager.default.removeItem(at: wav) }   // throwaway temp; keepAudio copies what it needs
        defer { pumpQueues() }   // resume the shared lane: a manual drop or watched file may have queued during the dictation
        let model = selectedModel

        // Drop a near-silent / too-short clip before spinning up the model. (A real WAV opens via
        // AVAudioFile; a non-audio path returns nil → fall through and let the engine decide.)
        let dur = await Task.detached(priority: .userInitiated) { AudioConverter.duration(of: wav.path) }.value
        if let dur, dur < 0.4 {
            phase = .idle
            dictationToast(empty: true, failed: false)
            return
        }

        do {
            phase = .loadingModel
            try await engine.ensureLoaded(model: model, progress: progressHandler())
            phase = .transcribing(L("dictation.label"))
            let lang = language.isEmpty ? nil : language
            let r = try await engine.transcribe(wavPath: wav.path, language: lang,
                                                model: model, translate: translateToEnglish)
            let clean = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else {              // engine heard nothing → don't insert a blank note
                phase = .idle
                dictationToast(empty: true, failed: false)
                return
            }
            let item = TranscriptItem(
                sourceName: Self.dictationTitle(date: Date()),
                language: r.language,
                durationSec: r.duration,
                model: model,
                text: clean,
                segments: r.segments,
                sourcePath: nil,                     // dictation has no re-transcribable source file
                sourceBookmark: nil
            )
            history.insert(item, at: 0)
            selection = item.id
            HistoryStore.save(history)
            Task { await refreshSemanticIndex() }   // extractive title/summary + search embedding (P1)
            // Paste-into-frontmost (opt-in) needs the text on the clipboard for the synthetic ⌘V.
            if autoCopy || dictationPasteIntoFrontmost { copy(item.text) }
            if keepDictationAudio { await keepDictationAudioFor(item.id, wav: wav) }
            phase = .idle
            if soundOnComplete { CompletionSound.success() }
            if dictationPasteIntoFrontmost { pasteDictationResult() }
            else { dictationToast(empty: false, failed: false) }
        } catch {
            // Dictation is toast-driven (no in-window chip): report via toast + sound and leave phase .idle,
            // so we don't strand a `.failed` chip whose "Try again" would replay an unrelated earlier drop.
            phase = .idle
            if soundOnComplete { CompletionSound.failure() }
            dictationToast(empty: false, failed: true)
        }
        await pruneAudioCache()
    }

    /// Opt-in: paste the dictation into the frontmost app. The text is already on the clipboard, so if
    /// Accessibility isn't granted we fall back to a "it's on your clipboard" note + a one-time AX prompt
    /// (never auto-prompted — only when the user has enabled paste and a dictation actually completes).
    private func pasteDictationResult() {
        // Don't synthesize ⌘V into our OWN window (e.g. dictation stopped via the in-window Stop button) —
        // that would paste into Parla's search / edit field. Fall back to clipboard-only (text is copied).
        if PasteService.isSelfFrontmost {
            dictationToast(empty: false, failed: false)
            return
        }
        if attemptPaste() {
            dictationToast(empty: false, failed: false)   // pasted into the active app — normal done signal
        } else {
            // Not Accessibility-trusted. Prompt at most ONCE (the Settings caption promises "asks once");
            // the clipboard-fallback toast still shows every time so the text is never silently lost.
            if !UserDefaults.standard.bool(forKey: Keys.dictationPasteAXPrompted) {
                UserDefaults.standard.set(true, forKey: Keys.dictationPasteAXPrompted)
                PasteService.requestAccessibility()
            }
            QuickToast.shared.show(L("toast.dictation.paste.needsax"))
        }
    }

    /// Copy the kept dictation audio into the item (shared by the plain and hybrid-refine save paths).
    private func keepDictationAudioFor(_ id: UUID, wav: URL) async {
        let kept = await Self.keepAudio(from: wav, id: id)
        if (kept.file != nil || kept.playable != nil),
           let idx = history.firstIndex(where: { $0.id == id }) {
            history[idx].audioFile = kept.file
            history[idx].audioPlayable = kept.playable
            HistoryStore.save(history)
        }
    }

    private func dictationToast(empty: Bool, failed: Bool) {
        if empty { QuickToast.shared.show(L("error.dictation.empty")) }
        else if failed { QuickToast.shared.show(L("toast.failed")) }
        else { QuickToast.shared.show(autoCopy ? L("toast.done.copied") : L("toast.done")) }
    }

    /// Synthesized sidebar label, e.g. "Dictation · 25 Jun 2026 at 2:03 PM".
    static func dictationTitle(date: Date) -> String {
        Lf("dictation.title", date.formatted(date: .abbreviated, time: .shortened))
    }
}
