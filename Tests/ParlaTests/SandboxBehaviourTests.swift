import XCTest
@testable import ParlaCore
@testable import Parla

/// Two features cannot survive the App Sandbox that the Mac App Store requires: synthesizing a ⌘V into another
/// app needs Accessibility, which a containerised process is never granted; and `parla://transcribe?path=…`
/// rebuilds a URL from a string, which carries no sandbox extension, so the app may not open the file however
/// real it is.
///
/// The requirement is not that they work — it is that they FAIL OUT LOUD. A silent no-op is the worst of the
/// three outcomes, worse than the feature being absent, because the user cannot tell "broken" from "I did it
/// wrong" and has nothing to report.
final class SandboxBehaviourTests: ParlaLogicTestCase {

    /// The paste path must not send a sandboxed user to grant a permission that does not exist for them. The
    /// preference can genuinely still be ON: macOS migrates the preferences plist into the container by bundle
    /// identifier, so a setting made in the direct-download build arrives switched on in the store build.
    @MainActor func testAnUnavailablePasteAdvisesTheClipboardRatherThanAPermission() {
        // The "ask once" latch lives in the REAL UserDefaults and survives between runs, so without this the
        // second half below passes or fails depending on whether this suite has ever run on this machine.
        UserDefaults.standard.removeObject(forKey: AppModel.Keys.dictationPasteAXPrompted)
        defer { UserDefaults.standard.removeObject(forKey: AppModel.Keys.dictationPasteAXPrompted) }

        let m = AppModel(engine: FakeEngine())
        m.dictationPasteIntoFrontmost = true
        m.pasteIsSelfFrontmost = { false }
        m.attemptPaste = { false }                      // never trusted, and never will be
        var promptedForAccessibility = false
        m.requestPasteAccessibility = { promptedForAccessibility = true }
        var toast: String?
        m.showToast = { text, _ in toast = text }

        m.pasteIsAvailable = { false }                  // the sandboxed build
        m.pasteDictationResult()

        XCTAssertFalse(promptedForAccessibility,
                       "a sandboxed app must not ask for a permission it can never be granted")
        XCTAssertEqual(toast, L("toast.dictation.paste.unavailable"))

        // …while the ordinary build keeps the existing behaviour exactly: prompt once, and say what is missing.
        toast = nil
        m.pasteIsAvailable = { true }
        m.pasteDictationResult()
        XCTAssertTrue(promptedForAccessibility, "an unsandboxed build still offers the one-time prompt")
        XCTAssertEqual(toast, L("toast.dictation.paste.needsax"))
    }

    /// A `parla://` link that resolves to nothing used to return in silence, so a Raycast script or a Shortcut
    /// appeared to fire and nothing whatsoever happened. Under the sandbox that becomes the NORMAL outcome
    /// rather than a typo.
    @MainActor func testAParlaURLThatOpensNothingSaysSoInsteadOfReturningSilently() {
        let m = AppModel(engine: FakeEngine())
        var toast: String?
        m.showToast = { text, _ in toast = text }

        m.handleParlaURL(URL(string: "parla://transcribe?path=/nonexistent/nowhere.ogg")!)

        XCTAssertNotNil(toast, "the user must be told, or the link looks like it did something")
        XCTAssertTrue(toast == L("toast.url.nofiles") || toast == L("toast.url.sandboxed"))
        XCTAssertTrue(m.history.isEmpty, "…and nothing may be transcribed from a path that resolved to nothing")
    }

    /// The detector itself, pinned against the host running the tests. `swift test` is not containerised, so
    /// this is the branch that ships to everyone who builds from source.
    func testSandboxDetectionMatchesTheHost() {
        XCTAssertEqual(Sandbox.isActive, ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)
        XCTAssertFalse(Sandbox.isActive, "a `swift test` process is not sandboxed")
        XCTAssertTrue(PasteService.isAvailable, "…so paste-into-frontmost is available in this build")
    }
}
