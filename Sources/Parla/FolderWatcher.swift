import Foundation
import CoreServices   // FSEvents — system framework, no new dependencies

/// Folder watcher via FSEvents (recursive). It makes no decisions itself — it debounces
/// «something changed under this path» and calls `onChange` on the main thread. The decision about what
/// to actually do is made by `AppModel` through the pure `FolderScan` core.
///
/// For unstable volumes (network/cloud) there's a poll fallback with the same `onChange`.
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
        // passRetained + release callback: the stream holds a +1 on self, so takeUnretainedValue in
        // the callback is safe even during teardown — the callback runs on a background queue, and the object stays alive
        // as long as the stream lives. The +1 is balanced by FSEventStreamRelease in stop(). This closes
        // the use-after-free on «stopped watching right when an event arrived».
        let infoPtr = Unmanaged.passRetained(self).toOpaque()
        var ctx = FSEventStreamContext(
            version: 0,
            info: infoPtr,
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<FolderWatcher>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            me.coalesceAndNotify()
        }
        // sinceWhen = SinceNow → ONLY future events; existing files don't «surface»
        // (part of the «only new ones after enabling» policy).
        let created = FSEventStreamCreate(
            nil, cb, &ctx,
            [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounce,                                   // built-in FSEvents coalescing
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents))
        guard let s = created else {
            // Create failed and the release callback will NOT fire → balance the +1 manually.
            Unmanaged<FolderWatcher>.fromOpaque(infoPtr).release()
            startPolling()
            return
        }
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

    /// Collapse a burst of events into a single pass: the first one calls onChange after `debounce`,
    /// the rest within that window are ignored.
    private func coalesceAndNotify() {
        lock.lock(); let already = pending; pending = true; lock.unlock()
        guard !already else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.pending = false; self.lock.unlock()
            MainActor.assumeIsolated { self.onChange() }   // asyncAfter(.main) → guaranteed main thread
        }
    }

    private func startPolling() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                guard let self else { return }                  // weak — otherwise the timer holds self forever
                MainActor.assumeIsolated { self.onChange() }
            }
        }
    }

    // nonisolated — only C calls into FSEvents/the timer, no @MainActor (avoiding the deinit trap).
    // In FSEvents mode the stream holds a +1 on self (passRetained), so deinit fires only
    // AFTER stop() and here it's a safety no-op; in polling mode it silences the timer on dealloc.
    deinit { stop() }
}
