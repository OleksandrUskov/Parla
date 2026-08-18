import Foundation
import ParlaCore   // AppModel.importsRoot — one source of truth with the sweep that deletes from it

/// Bridges iOS document-picker URLs into Parla's transcription pipeline.
///
/// Picked files are **security-scoped** and live OUTSIDE the app sandbox, so we copy each into the container
/// while holding the scope. The container copy is then freely readable by the later async decode AND persists
/// across launches — so `TranscriptItem.sourcePath` points at the container copy and re-transcribe / replay work
/// with NO security-scoped-bookmark machinery (the copy IS the persistence).
enum ImportCoordinator {
    /// Copy each picked URL into `Application Support/Parla/imports/<uuid>/<name>` (a per-item subdir keeps the
    /// original filename clean) and return the container URLs. Best-effort: a file that can't be accessed or
    /// copied is skipped so one bad pick never fails the whole batch. Runs while the security scope is held.
    static func copyIntoContainer(_ picked: [URL]) -> [URL] {
        let fm = FileManager.default
        // One source of truth with the sweep that deletes from here (`AppModel.pruneImportedOrphans`), and a seam
        // the iOS tests can redirect so they never write into the real container.
        let root = AppModel.importsRoot
        var out: [URL] = []
        for src in picked {
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }

            let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            // The per-import UUID DIRECTORY already gives collision-freedom, so the file itself keeps the name
            // the user shared — with the Share Extension's uniqueness stamp stripped. That name reaches the note
            // (and titled every shared note `voice-<36 hex characters>.ogg`), and it is part of what identifies a
            // resumable long job, which a freshly random name could never match. Extension preserved either way:
            // the decoder routes on it.
            let dest = dir.appendingPathComponent(ShareInboxName.original(from: src.lastPathComponent))
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try fm.copyItem(at: src, to: dest)
                out.append(dest)
            } catch {
                try? fm.removeItem(at: dir)   // don't leak an empty/partial import dir
            }
        }
        return out
    }
}
