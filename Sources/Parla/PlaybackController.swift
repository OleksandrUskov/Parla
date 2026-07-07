import Foundation
import ParlaCore
import AVFoundation

/// Player for the recording's source audio (feature 06). A wrapper over AVAudioPlayer + a 0.1s ticker for progress.
/// This is ephemeral UI state — it lives in the card's @State, NOT in AppModel.
@MainActor
@Observable
final class PlaybackController {
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var loadedURL: URL?

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    /// Loads the recording's audio. A nil URL → unload. Idempotent by URL.
    func load(_ url: URL?) {
        guard loadedURL != url else { return }
        stop()
        player = nil; duration = 0; currentTime = 0; loadedURL = url
        guard let url else { return }
        // AVAudioPlayer can't open Ogg/Opus directly — on failure we stay «without a player» (canPlay=false).
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

    /// Seek with auto-start playback (clicking a segment = «play from here»).
    func seek(to t: Double) {
        guard let p = player else { return }
        p.currentTime = min(max(0, t), max(0, duration - 0.05))
        currentTime = p.currentTime
        if !p.isPlaying { p.play(); isPlaying = true; startTicker() }
    }

    /// Dragging the scrubber: seek without auto-start.
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
            MainActor.assumeIsolated { self?.tick() }   // Timer on the main runloop → guaranteed main thread
        }
    }
    private func stopTicker() { ticker?.invalidate(); ticker = nil }

    private func tick() {
        guard let p = player else { return }
        currentTime = p.currentTime
        if !p.isPlaying {                                // played through to the end
            isPlaying = false; stopTicker()
            if currentTime >= duration - 0.15 { currentTime = duration }
        }
    }
    // No deinit: the ticker is deterministically torn down via stop()/stopTicker() (pause/end/load/
    // onDisappear), and the controller lives for the app's entire runtime (@State of the single card).
    // This sidesteps the «@MainActor deinit trap» (a nonisolated deinit can't touch the isolated ticker).
}
