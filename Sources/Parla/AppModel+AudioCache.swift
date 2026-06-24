import Foundation

/// Управление кэшем аудио для плеера (фича 06): копирование исходника, авто-уборка (LRU + сироты),
/// ручная очистка. ТЕКСТ РАСШИФРОВОК НИКОГДА НЕ ТРОГАЕТСЯ — только копии аудио.
extension AppModel {
    /// Скопировать исходник + при необходимости отрендерить m4a — в фоне. Best-effort.
    nonisolated static func keepAudio(from url: URL, id: UUID) async -> (file: String?, playable: String?) {
        await Task.detached(priority: .utility) {
            let file = AudioStore.copy(from: url, id: id)
            let needsRender = !AudioStore.directlyPlayable.contains(url.pathExtension.lowercased())
            let playable = needsRender ? AudioStore.makePlayable(from: url, id: id) : nil
            return (file, playable)
        }.value
    }

    /// Очистить кэш аудио (кнопка в настройках): снести файлы и обнулить ссылки в истории.
    func clearAudioCache() {
        AudioStore.clearAll()
        for i in history.indices {
            history[i].audioFile = nil
            history[i].audioPlayable = nil
        }
        HistoryStore.save(history)
    }

    /// Лимит аудио-кэша. Скрытый оверрайд для архивистов (в UI пикача нет):
    /// `defaults write <bundle-id> PARLA_AUDIO_CAP_MB -int N` (0 — без ограничения). По умолчанию 500 МБ.
    private var audioCacheCapBytes: Int64 {
        let mb = UserDefaults.standard.object(forKey: "PARLA_AUDIO_CAP_MB") as? Int ?? 500
        return Int64(max(0, mb)) * 1_048_576
    }

    /// Авто-уборка аудио-кэша: снести сирот + (если задан кэп) выселить аудио самых старых записей.
    /// ТЕКСТ РАСШИФРОВОК НЕ ТРОГАЕТСЯ — только копии аудио для плеера. Зовём после каждой
    /// расшифровки и на старте. Тяжёлая ФС-работа — off-main; мутация истории — на main.
    func pruneAudioCache() async {
        let snapshot = history
        let cap = audioCacheCapBytes
        // Защищаем именно ОТОБРАЖАЕМУЮ/играющую запись: карточка и плеер привязаны к selectedItem,
        // а не к raw selection (при активном поиске или nil-selection они расходятся → selectedItem
        // откатывается на filteredHistory.first).
        let protectedAtStart: Set<UUID> = selectedItem.map { [$0.id] } ?? []
        var evicted: [UUID] = await Task.detached(priority: .utility) {
            AudioStore.pruneOrphans(keeping: snapshot)               // сироты — всегда
            guard cap > 0 else { return [] }                        // 0 = без лимита
            return AudioStore.enforceAudioCap(snapshot, capBytes: cap,
                                              sizeOf: { AudioStore.bytes(of: $0) },
                                              protected: protectedAtStart)
        }.value
        // TOCTOU: пока шёл off-main проход (main-актор был свободен), юзер мог переключиться на старую
        // запись и нажать play — исключаем текущую отображаемую запись из выселения на этапе применения.
        if let nowShown = selectedItem?.id { evicted.removeAll { $0 == nowShown } }
        guard !evicted.isEmpty else { return }
        let evictedSet = Set(evicted)
        for item in snapshot where evictedSet.contains(item.id) { AudioStore.remove(item) }   // удаляем файлы
        for i in history.indices where evictedSet.contains(history[i].id) {                   // обнуляем ссылки
            history[i].audioFile = nil
            history[i].audioPlayable = nil
        }
        HistoryStore.save(history)
    }
}
