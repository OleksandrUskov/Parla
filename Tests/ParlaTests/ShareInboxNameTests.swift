import XCTest
@testable import ParlaCore

/// The iOS Share Extension stamps a UUID into every filename it writes into its flat inbox, and that name used
/// to travel all the way into the note. Two consequences, one cosmetic and one not: every note shared from iOS
/// was titled `voice-<36 hex characters>.ogg`, and long-audio RESUME could never match a re-share, because a job
/// is identified by its source's name, size and modification time and the name was freshly random every time.
///
/// The one path resume exists for — a jetsam mid-job, then re-share the same voice note — was the one path it
/// could not serve. The first fix keyed identity on content but kept the name in it, and the test that
/// "proved" the re-import case modelled the FILE PICKER, which preserves names. Twice in one session a test
/// asserted the right property over an input set that omitted the real case.
final class ShareInboxNameTests: ParlaLogicTestCase {

    func testTheExtensionsUniquenessStampIsRemoved() {
        let id = UUID().uuidString
        XCTAssertEqual(ShareInboxName.original(from: "voice-\(id).ogg"), "voice.ogg")
        XCTAssertEqual(ShareInboxName.original(from: "Голосовое сообщение-\(id).m4a"), "Голосовое сообщение.m4a")
        XCTAssertEqual(ShareInboxName.original(from: "audio-\(id).dat"), "audio.dat")
        XCTAssertEqual(ShareInboxName.original(from: "file-\(id)"), "file", "the extension may be absent")
    }

    /// The decisive property: the SAME file shared twice must produce the same name, or resume cannot match it.
    func testTwoSharesOfTheSameFileAgreeOnTheName() {
        let a = "voice-\(UUID().uuidString).ogg"
        let b = "voice-\(UUID().uuidString).ogg"
        XCTAssertNotEqual(a, b, "precondition: the extension really does randomise the name")
        XCTAssertEqual(ShareInboxName.original(from: a), ShareInboxName.original(from: b))
    }

    /// …while the user's own names are left completely alone. The match is a trailing hyphen plus exactly a
    /// well-formed UUID; anything else is theirs.
    func testAUsersOwnFilenameIsNeverAltered() {
        for untouched in ["report-v2.ogg", "voice.ogg", "meeting-2026-08-16.m4a", "a-b-c.wav",
                         "voice-not-a-uuid-at-all.ogg", "-\(UUID().uuidString).ogg", "\(UUID().uuidString).ogg",
                         "", ".ogg", "voice-12345678-1234-1234-1234-12345678901.ogg"] {
            XCTAssertEqual(ShareInboxName.original(from: untouched), untouched)
        }
    }
}
