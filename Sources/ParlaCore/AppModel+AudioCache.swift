import Foundation

/// Audio cache management for the player (feature 06): source copy, auto-cleanup (LRU + orphans),
/// manual clear. TRANSCRIPT TEXT IS NEVER TOUCHED — only audio copies.
extension AppModel {
    /// Copy the source + render m4a if needed — in the background. Best-effort. The playback rendition goes
    /// through the injected `decoder` seam (macOS: ffmpeg; iOS: its own), so this stays platform-agnostic.
    public nonisolated static func keepAudio(from url: URL, id: UUID, using decoder: any AudioDecoding) async -> (file: String?, playable: String?) {
        await Task.detached(priority: .utility) {
            let file = AudioStore.copy(from: url, id: id)
            let needsRender = !AudioStore.directlyPlayable.contains(url.pathExtension.lowercased())
            let playable = needsRender ? AudioStore.makePlayable(from: url, id: id, using: decoder) : nil
            return (file, playable)
        }.value
    }

    /// Clear the audio cache (settings button): delete files and null out the references in history.
    public func clearAudioCache() {
        AudioStore.clearAll()
        for i in history.indices {
            history[i].audioFile = nil
            history[i].audioPlayable = nil
        }
        HistoryStore.save(history)
    }

    /// Audio cache limit. Hidden override for archivists (no picker in the UI):
    /// `defaults write <bundle-id> PARLA_AUDIO_CAP_MB -int N` (0 — unlimited). Defaults to 500 MB.
    private var audioCacheCapBytes: Int64 {
        let mb = UserDefaults.standard.object(forKey: "PARLA_AUDIO_CAP_MB") as? Int ?? 500
        return Int64(max(0, mb)) * 1_048_576
    }

    /// Auto-cleanup of the audio cache: delete orphans + (if a cap is set) evict audio of the oldest entries.
    /// TRANSCRIPT TEXT IS NOT TOUCHED — only player audio copies. Called after every
    /// transcription and on startup. Heavy FS work — off-main; history mutation — on main.
    public func pruneAudioCache() async {
        let snapshot = history
        let cap = audioCacheCapBytes
        // Protect specifically the DISPLAYED/playing entry: the card and player are bound to selectedItem,
        // not to the raw selection (under active search or nil-selection they diverge → selectedItem
        // falls back to filteredHistory.first).
        let protectedAtStart: Set<UUID> = selectedItem.map { [$0.id] } ?? []
        var evicted: [UUID] = await Task.detached(priority: .utility) {
            AudioStore.pruneOrphans(keeping: snapshot)               // orphans — always
            guard cap > 0 else { return [] }                        // 0 = unlimited
            return AudioStore.enforceAudioCap(snapshot, capBytes: cap,
                                              sizeOf: { AudioStore.bytes(of: $0) },
                                              protected: protectedAtStart)
        }.value
        // TOCTOU: while the off-main pass was running (the main actor was free), the user could have switched to an old
        // entry and hit play — exclude the currently displayed entry from eviction at the apply stage.
        evicted = AudioStore.applyProtection(evicted, evicting: selectedItem?.id)
        guard !evicted.isEmpty else { return }
        let evictedSet = Set(evicted)
        for item in snapshot where evictedSet.contains(item.id) { AudioStore.remove(item) }   // delete files
        for i in history.indices where evictedSet.contains(history[i].id) {                   // null out references
            history[i].audioFile = nil
            history[i].audioPlayable = nil
        }
        HistoryStore.save(history)
    }
}
