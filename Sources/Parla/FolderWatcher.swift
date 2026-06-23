import Foundation
import CoreServices   // FSEvents — системный фреймворк, без новых зависимостей

/// Наблюдатель за папкой через FSEvents (рекурсивно). Сам решений не принимает — дебаунсит
/// «что-то изменилось под этим путём» и зовёт `onChange` на главном потоке. Решение, что именно
/// делать, принимает `AppModel` через чистое ядро `FolderScan`.
///
/// Для нестабильных томов (сеть/облако) есть poll-фолбэк с тем же `onChange`.
final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let lock = NSLock()
    private var pollTimer: Timer?
    private var pending = false

    let folder: URL
    let recursive: Bool
    let usePolling: Bool
    private let debounce: TimeInterval
    private let onChange: @MainActor () -> Void

    init(folder: URL, recursive: Bool, usePolling: Bool = false,
         debounce: TimeInterval = 1.0, onChange: @escaping @MainActor () -> Void) {
        self.folder = folder
        self.recursive = recursive
        self.usePolling = usePolling
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() {
        if usePolling { startPolling(); return }
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            me.coalesceAndNotify()
        }
        // sinceWhen = SinceNow → ТОЛЬКО будущие события; существующие файлы не «всплывают»
        // (часть политики «только новые после включения»).
        let created = FSEventStreamCreate(
            nil, cb, &ctx,
            [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounce,                                   // встроенная коалесценция FSEvents
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents))
        guard let s = created else { startPolling(); return }   // фолбэк, если поток не создался
        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(s)
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Схлопываем всплеск событий в один проход: первый зовёт onChange через `debounce`,
    /// остальные в этом окне игнорируются.
    private func coalesceAndNotify() {
        lock.lock(); let already = pending; pending = true; lock.unlock()
        guard !already else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.pending = false; self.lock.unlock()
            MainActor.assumeIsolated { self.onChange() }   // asyncAfter(.main) → точно главный поток
        }
    }

    private func startPolling() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                MainActor.assumeIsolated { self.onChange() }
            }
        }
    }

    deinit { stop() }   // nonisolated — только C-вызовы FSEvents, без @MainActor (избегаем deinit-ловушки)
}
