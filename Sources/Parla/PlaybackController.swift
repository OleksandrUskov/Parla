import Foundation
import AVFoundation

/// Плеер исходного аудио записи (фича 06). Обёртка над AVAudioPlayer + 0.1с тикер для прогресса.
/// Это эфемерное UI-состояние — живёт во @State карточки, НЕ в AppModel.
@MainActor
@Observable
final class PlaybackController {
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var loadedURL: URL?

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    /// Грузим аудио записи. nil-URL → выгружаем. Идемпотентно по URL.
    func load(_ url: URL?) {
        guard loadedURL != url else { return }
        stop()
        player = nil; duration = 0; currentTime = 0; loadedURL = url
        guard let url else { return }
        // AVAudioPlayer не открывает Ogg/Opus напрямую — на ошибке остаёмся «без плеера» (canPlay=false).
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.prepareToPlay()
        player = p
        duration = p.duration
    }

    var canPlay: Bool { player != nil && duration > 0 }

    func togglePlay() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); isPlaying = false; stopTicker() }
        else { p.play(); isPlaying = true; startTicker() }
    }

    /// Перемотка с авто-стартом проигрывания (клик по сегменту = «играй отсюда»).
    func seek(to t: Double) {
        guard let p = player else { return }
        p.currentTime = min(max(0, t), max(0, duration - 0.05))
        currentTime = p.currentTime
        if !p.isPlaying { p.play(); isPlaying = true; startTicker() }
    }

    /// Перетаскивание скрабера: перемотка без авто-старта.
    func scrub(to t: Double) {
        guard let p = player else { return }
        p.currentTime = min(max(0, t), max(0, duration - 0.05))
        currentTime = p.currentTime
    }

    func stop() {
        player?.stop(); player?.currentTime = 0
        isPlaying = false; currentTime = 0; stopTicker()
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }   // Timer на main runloop → точно главный поток
        }
    }
    private func stopTicker() { ticker?.invalidate(); ticker = nil }

    private func tick() {
        guard let p = player else { return }
        currentTime = p.currentTime
        if !p.isPlaying {                                // доиграли до конца
            isPlaying = false; stopTicker()
            if currentTime >= duration - 0.15 { currentTime = duration }
        }
    }
    // Без deinit: тикер детерминированно гасится через stop()/stopTicker() (пауза/конец/load/
    // onDisappear), а контроллер живёт всё время работы приложения (@State единственной карточки).
    // Это обходит «@MainActor deinit trap» (nonisolated deinit не может трогать изолированный ticker).
}
