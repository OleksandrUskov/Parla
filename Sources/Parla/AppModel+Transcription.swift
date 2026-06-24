import SwiftUI
import AppKit

/// Конвейер расшифровки: дроп → (конвертация → загрузка модели → распознавание) → история,
/// плюс «перераспознать» (фича 01), переиспользующее тот же `transcribeOne`.
extension AppModel {
    func handleDrop(urls: [URL]) {
        guard !isBusy, downloadingModel == nil else { return }
        phase = .preparing("…")   // синхронно занимаем фазу — закрываем гонку двойного дропа
        Task { await transcribe(urls: urls) }
    }

    func transcribe(urls: [URL]) async {
        var files: [URL] = []
        for url in urls {
            if url.hasDirectoryPath { files.append(contentsOf: Self.audioFiles(in: url)) }
            else { files.append(url) }
        }
        guard !files.isEmpty else {
            phase = .failed("Не нашёл аудиофайлов")
            return
        }
        let total = files.count
        let jobStart = Date()
        var failures: [String] = []
        var succeeded = 0
        for (i, url) in files.enumerated() {
            // Позицию в очереди показываем только для батча (>1 файла); одиночный дроп выглядит как раньше.
            let batch = total > 1 ? BatchProgress(index: i + 1, total: total, done: i) : nil
            do {
                let r = try await transcribeOne(url: url, model: selectedModel, batch: batch)
                let item = TranscriptItem(
                    sourceName: url.lastPathComponent,
                    language: r.language,
                    durationSec: r.duration,
                    model: selectedModel,
                    text: r.text.isEmpty ? "(тишина — ничего не распознано)" : r.text,
                    segments: r.segments,
                    sourcePath: url.path,                       // запоминаем исходник для «перераспознать»
                    sourceBookmark: makeSourceBookmark(url)
                )
                // РЕЗУЛЬТАТ ПОКАЗЫВАЕМ СРАЗУ — не ждём копирование/рендишен аудио для плеера.
                history.insert(item, at: 0)
                selection = item.id
                HistoryStore.save(history)
                if autoCopy, !r.text.isEmpty { copy(item.text) }
                succeeded += 1
                rememberSource(url)            // для «повторить последний файл»
                // Аудио для плеера готовим ПОСЛЕ показа текста; патчим запись по id (плеер появится чуть позже).
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
        phase = failures.isEmpty ? .idle : .failed("Не удалось: \(failures.joined(separator: "; "))")

        // Уведомление: только если задание «стоило ожидания» и окно не на переднем плане.
        // Frontmost читаем в КОНЦЕ — переключение во время батча как раз и должно уведомить.
        let elapsed = Date().timeIntervalSince(jobStart)
        if BatchNotifier.shouldNotify(total: total, elapsed: elapsed, frontmost: NSApp.isActive) {
            await BatchNotifier.post(succeeded: succeeded, failed: failures.count)
        }

        // Тост для быстрого режима (хоткей/меню-бар) — у пользователя нет открытого окна с чипом.
        if quickModeRun {
            quickModeRun = false
            if !failures.isEmpty {
                QuickToast.shared.show("Не удалось распознать")
            } else {
                QuickToast.shared.show(autoCopy ? "Готово · скопировано в буфер" : "Готово")
            }
        }

        await pruneAudioCache()   // держим аудио-кэш в рамках лимита (текст не трогаем)
    }

    /// Один файл → EngineResult: конвертация → загрузка модели (со скачиванием при надобности) →
    /// распознавание. Фазы выставляет сам (с учётом позиции в батче). Бросает на ошибке.
    /// Общий путь для свежего дропа и «перераспознать».
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

    // MARK: Перераспознать (фича 01)

    /// Можно ли перераспознать запись: движок свободен и исходник доступен.
    func canRetranscribe(_ item: TranscriptItem) -> Bool {
        !isBusy && downloadingModel == nil && item.hasResolvableSource
    }

    /// Перезапустить запись на другой модели, заменив её содержимое НА МЕСТЕ (тот же id/позиция).
    func retranscribe(_ item: TranscriptItem, with model: String) {
        guard !isBusy, downloadingModel == nil else { return }
        guard model != item.model else { return }            // та же модель — пересчитывать нечего
        phase = .preparing(item.sourceName)                   // синхронно занимаем фазу — закрываем гонку (как handleDrop)
        Task { await runRetranscribe(item, with: model) }
    }

    private func runRetranscribe(_ item: TranscriptItem, with model: String) async {
        // Резолвим исходник ВНУТРИ задачи: файл мог исчезнуть между открытием меню и подтверждением.
        switch item.resolveSource() {
        case .missing:
            phase = .failed("Файл-источник «\(item.sourceName)» не найден — перетащи его заново")
        case .found(let url, let scoped):
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let r = try await transcribeOne(url: url, model: model)
                // Если аудио было выселено кэшем, а исходник сейчас в руках — восстанавливаем копию
                // для плеера (иначе свежеперераспознанная запись осталась бы без плеера). ДО мутации.
                var restored: (file: String?, playable: String?)?
                if let cur = history.first(where: { $0.id == item.id }),
                   cur.audioFile == nil, cur.audioPlayable == nil {
                    restored = await Self.keepAudio(from: url, id: item.id)
                }
                // Индекс резолвим ПОСЛЕ всех await — история могла сдвинуться (фоновая расшифровка).
                if let idx = history.firstIndex(where: { $0.id == item.id }) {
                    var updated = history[idx]
                    updated.language    = r.language
                    updated.durationSec = r.duration
                    updated.model       = model
                    updated.text        = r.text.isEmpty ? "(тишина — ничего не распознано)" : r.text
                    updated.segments    = r.segments
                    updated.date        = Date()
                    updated.edited      = nil   // свежее распознавание → сбрасываем флаг ручной правки (таймкоды снова валидны)
                    updated.editedAt    = nil
                    if let restored {
                        updated.audioFile = restored.file
                        updated.audioPlayable = restored.playable
                    }
                    history[idx] = updated      // замена НА МЕСТЕ: id/позиция/sourcePath сохранены
                    selection = updated.id
                    HistoryStore.save(history)
                    if autoCopy, !r.text.isEmpty { copy(updated.text) }
                }
                phase = .idle
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                phase = .failed("Не удалось перераспознать: \(msg)")
            }
        }
        refreshDownloaded()   // целевая модель могла только что скачаться
    }
}
