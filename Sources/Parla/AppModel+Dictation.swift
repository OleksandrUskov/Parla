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

    /// Hotkey / menu-bar / Settings entry point: start recording, or stop+transcribe if already recording.
    func toggleDictation() {
        if isRecordingDictation { stopAndTranscribeDictation() }
        else { startDictation() }
    }

    /// Begin recording after a mic-permission check. Single-flight: refuses while busy/downloading.
    func startDictation() {
        guard canDictate else { QuickToast.shared.show(L("toast.busy")); return }
        recordingStartedAt = Date()                 // claim synchronously (→ isBusy) so a drop can't race in
        Task {
            guard await MicRecorder.ensureMicAccess() else {
                recordingStartedAt = nil
                QuickToast.shared.show(L("toast.mic.denied"))
                return
            }
            let rec = MicRecorder()
            do {
                try rec.start(onAutoStop: { [weak self] in self?.stopAndTranscribeDictation() })
                recorder = rec
                recordingStartedAt = Date()         // re-stamp to the real capture start (after the permission await)
            } catch {
                recordingStartedAt = nil
                recorder = nil
                QuickToast.shared.show(L("toast.dictation.failed"))
            }
        }
    }

    /// Stop the recorder and transcribe the captured WAV (reusing the standard result path).
    func stopAndTranscribeDictation() {
        guard isRecordingDictation else { return }
        let wav = recorder?.stop()
        recorder = nil
        recordingStartedAt = nil
        guard let wav else { QuickToast.shared.show(L("error.dictation.empty")); return }
        phase = .preparing(L("dictation.label"))    // claim the phase synchronously (like handleDrop)
        Task { await finishDictation(wav: wav) }
    }

    /// Transcribe a finished dictation WAV and fold the result into history. Bypasses `wavConverter`
    /// (the WAV is already 16 kHz mono). Best-effort + always toasts (dictation has no in-window chip flow).
    func finishDictation(wav: URL) async {
        defer { try? FileManager.default.removeItem(at: wav) }   // throwaway temp; keepAudio copies what it needs
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
            if autoCopy { copy(item.text) }
            if keepDictationAudio {
                let kept = await Self.keepAudio(from: wav, id: item.id)
                if (kept.file != nil || kept.playable != nil),
                   let idx = history.firstIndex(where: { $0.id == item.id }) {
                    history[idx].audioFile = kept.file
                    history[idx].audioPlayable = kept.playable
                    HistoryStore.save(history)
                }
            }
            phase = .idle
            if soundOnComplete { CompletionSound.success() }
            dictationToast(empty: false, failed: false)
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .failed(Lf("error.transcribe.failed", msg))
            if soundOnComplete { CompletionSound.failure() }
            dictationToast(empty: false, failed: true)
        }
        await pruneAudioCache()
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
