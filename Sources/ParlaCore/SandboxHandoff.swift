#if os(macOS)
import Foundation

/// Hands this install's library to the sandboxed (Mac App Store) build, because macOS will not.
///
/// ## What was measured, and what it overturns
///
/// `StorageRoot` was named after the bundle identifier on the stated theory that macOS migrates a newly
/// sandboxed app's data into its container **by bundle identifier**. That theory is FALSE on macOS 26, and it
/// was measured three independent ways — a never-before-launched app, an app launched unsandboxed first and
/// then sandboxed (the real upgrade path), and a LaunchServices launch. In all three the container's
/// `Application Support/<bundle-id>` did not exist and the container metadata's `RedirectedPaths` was empty.
/// The rename remains correct — it is the convention, and the rebrand needs it — but it buys no migration.
///
/// What macOS *does* migrate is `Library/Preferences/<bundle-id>.plist`. So doing nothing produces the worst
/// shape available: the app arrives **configured but empty**, remembering a watched folder it cannot watch and
/// a model it cannot find, with every byte still on disk and unreachable — a sandboxed process cannot read
/// `~/Library/Application Support`, and `NSOpenPanel` will not walk anyone into `~/Library`.
///
/// Three further facts, also measured:
/// - an unsandboxed process CAN pre-create the container tree, and `containermanagerd` **adopts** it: it writes
///   its metadata alongside, adds the standard symlinks, and the pre-seeded data is fully readable. Verified
///   with the real app over a 5.3 GB library;
/// - adoption **suppresses** the preferences migration. Data and settings are therefore not two independent
///   problems but one trade — fix the data and you lose the settings — which is why this stages BOTH;
/// - `clonefile` copies that library in 0.07 s for zero bytes, because APFS shares the blocks.
///
/// ## Why this is safe to do without asking
///
/// It replaces only a staged copy it made itself, and it stops forever the moment the store build has used one.
/// That is decided by a marker file written INSIDE the staged library: present means "this is a copy the direct
/// build left here, and a newer one may replace it"; absent means the store build has claimed the container and
/// what is in it is the user's live library, which must never be overwritten. `claimContainer()` is what removes
/// it, and the sandboxed build calls that on launch.
///
/// ⚠️ The obvious marker — `containermanagerd`'s own `.com.apple.containermanagerd.metadata.plist` — was tried
/// first and is WRONG, which only a live run revealed: simply `mkdir`-ing the container path causes the daemon
/// to write that file within seconds, with no app and no sandboxed process involved. It therefore means "a
/// container directory exists", not "a sandboxed process has adopted it". Using it would have frozen the staged
/// library at whatever the first launch found and never refreshed it again — stale, and looking like it worked.
/// The unit tests could not have caught that: their `home` is a temp directory the daemon does not watch.
///
/// It is also free or nothing: `clonefile` fails on a volume that cannot clone, and that failure is reported
/// rather than papered over with a real copy, because silently duplicating a multi-gigabyte library on someone's
/// disk once per launch is not a thing to do quietly.
public enum SandboxHandoff {

    /// What `stage` did, spelled out so a test asserts the branch rather than a side effect.
    public enum Outcome: Equatable, Sendable {
        /// Running inside a container already — this is the store build, and it must never write its own input.
        case skippedSandboxed
        /// A sandboxed process has adopted the container: its library is the live one now.
        case skippedContainerInUse
        /// Nothing to hand over.
        case skippedNoLibrary
        /// The volume cannot clone, so the copy would be real. Declined out loud.
        case skippedCloneUnsupported
        /// The bundle identifier did not survive being used as a path component, so the directory this would
        /// have removed is not the one it names. Same lesson as `IntentFileName`: a string that names a thing
        /// is not automatically safe to join onto a path.
        case skippedUnsafeDestination
        /// The library — and the preferences beside it — are waiting in the container.
        case staged
    }

    /// `~/Library/Containers/<bundle-id>/Data`, the home a sandboxed process is given.
    public static func containerData(home: URL, bundleID: String) -> URL {
        home.appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
    }

    /// Where the sandboxed build will look for its library — `StorageRoot.defaultURL()` resolved inside the
    /// container, which is exactly what `.applicationSupportDirectory` returns to a contained process.
    public static func stagedLibrary(home: URL, bundleID: String) -> URL {
        containerData(home: home, bundleID: bundleID)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
    }

    /// Where the sandboxed build will read its defaults from once the OS stops migrating them for us.
    public static func stagedPreferences(home: URL, bundleID: String) -> URL {
        containerData(home: home, bundleID: bundleID)
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent("\(bundleID).plist")
    }

    /// Written beside the staged library to say "the direct build put this here". Its ABSENCE beside an
    /// existing library is what means the store build owns it, so the file lives inside the copy it describes
    /// and disappears with it.
    public static let markerName = ".staged-by-direct-build"

    /// Defaults that describe the state of THIS container's machine rather than the user's choices, and so
    /// must not travel with the library.
    ///
    /// 🔴 `didCompileModel` is the one that matters, and it was measured: the Core ML compile cache lives in
    /// the container (129 MB of it appeared there during this test), so a store build inherits none of it and
    /// pays the first compile again — 431 s for the shipping 626 MB model on this machine, against 10 s for
    /// every run after. The app has a caption for exactly that wait, and it is gated on this flag being false.
    /// Carrying the flag across therefore suppresses the one explanation the user gets and turns the store
    /// build's FIRST transcription into seven silent minutes of "Loading model…" — which is also the first
    /// thing an App Review tester would do with it.
    public static let nonPortableDefaults = ["didCompileModel"]

    /// The marker as the DIRECT build addresses it — from the real home, reaching into the container.
    public static func stagingMarker(home: URL, bundleID: String) -> URL {
        stagedLibrary(home: home, bundleID: bundleID).appendingPathComponent(markerName)
    }

    /// Take ownership of the container: from now on the library in it is the user's live one and no
    /// direct-download build may replace it. The sandboxed build calls this on launch.
    ///
    /// ⚠️ It takes the LIBRARY, not a home, because the two sides do not agree on what a home is: inside a
    /// container `homeDirectoryForCurrentUser` already IS `~/Library/Containers/<id>/Data`, so reusing
    /// `stagedLibrary(home:)` here would append the container path to itself and remove nothing. The sandboxed
    /// build's library is simply its `StorageRoot.url`.
    ///
    /// Idempotent, and a no-op when there was never a staging to claim.
    public static func claimContainer(library: URL = StorageRoot.url) {
        try? FileManager.default.removeItem(at: library.appendingPathComponent(markerName))
    }

    /// Stage the library and the preferences into the container the store build will be given.
    ///
    /// Every parameter has a production default and is injectable, so the tests exercise this against a temp
    /// tree rather than against the real `~/Library` — the same shape as every other store seam here.
    @discardableResult
    public static func stage(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleID: String = Bundle.main.bundleIdentifier ?? "com.parla.app",
        liveLibrary: URL? = nil,
        livePreferences: URL? = nil,
        isSandboxed: Bool = Sandbox.isActive
    ) -> Outcome {
        // A contained process writing into its own container's staging area would be staging data for itself.
        guard !isSandboxed else { return .skippedSandboxed }

        let fm = FileManager.default
        let source = liveLibrary ?? StorageRoot.url
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            return .skippedNoLibrary
        }

        let destination = stagedLibrary(home: home, bundleID: bundleID)

        // The one guard that protects real user data, checked BEFORE anything is removed: a library in the
        // container that we did not leave there belongs to the store build, and is the only copy of everything
        // recorded since it took over.
        if fm.fileExists(atPath: destination.path),
           !fm.fileExists(atPath: stagingMarker(home: home, bundleID: bundleID).path) {
            return .skippedContainerInUse
        }
        // This function removes a directory, so it verifies that the directory it is about to remove is the one
        // it thinks it named. An identifier carrying `/` or `..` collapses under `appendingPathComponent` and
        // would aim the removal somewhere else entirely.
        guard destination.path.contains("/Library/Containers/"), destination.lastPathComponent == bundleID else {
            return .skippedUnsafeDestination
        }

        // A stale staging from an earlier launch. Safe to drop — the marker check above proved no sandboxed
        // process has ever opened this container, so nothing but us has written here.
        try? fm.removeItem(at: destination)
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        // `clonefile` rather than `copyItem`: it is recursive, it shares blocks instead of duplicating them,
        // and — the reason it is the right call here — it FAILS on a volume that cannot clone instead of
        // quietly making a real multi-gigabyte copy.
        guard clonefile(source.path, destination.path, 0) == 0 else {
            try? fm.removeItem(at: destination)
            return .skippedCloneUnsupported
        }

        // Written only after the copy succeeded, so a failed staging never claims to be one of ours: without
        // this file the next launch treats what is there as the store build's and leaves it alone.
        try? Data().write(to: destination.appendingPathComponent(markerName))

        // Settings second, and only because adoption suppressed the migration that would have brought them.
        let prefsSource = livePreferences
            ?? home.appendingPathComponent("Library/Preferences", isDirectory: true)
                .appendingPathComponent("\(bundleID).plist")
        if let data = try? Data(contentsOf: prefsSource),
           var settings = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
            for key in nonPortableDefaults { settings.removeValue(forKey: key) }
            if let filtered = try? PropertyListSerialization.data(fromPropertyList: settings,
                                                                 format: .binary, options: 0) {
                let prefsDestination = stagedPreferences(home: home, bundleID: bundleID)
                try? fm.createDirectory(at: prefsDestination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                try? filtered.write(to: prefsDestination, options: .atomic)
            }
        }
        // A plist that will not parse is not staged at all, rather than copied through: with the library
        // present the store build skips onboarding anyway, so the cost is a language and a model choice —
        // against handing a corrupt defaults domain to a build that cannot be repaired from inside.

        return .staged
    }
}
#endif
