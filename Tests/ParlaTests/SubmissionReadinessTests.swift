import XCTest
@testable import ParlaCore

/// Claims about the SUBMITTED bundle that no runtime assertion can reach.
///
/// `build_app.sh` writes the macOS Info.plist after xcodebuild has already run, so there is no way to obtain it
/// without a full release build — which is exactly why these went unnoticed. Scanned in the source instead,
/// with comment lines stripped, because a substring test that matches inside a comment passes forever while the
/// thing it guards is gone; that happened in this repo the same week.
final class SubmissionReadinessTests: ParlaLogicTestCase {

    private func code(of path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("<!--") }
            .joined(separator: "\n")
    }

    /// The keys App Store Connect needs. Without the encryption declaration every single upload stops in
    /// "Missing Compliance" until it is answered by hand — an avoidable delay on every release, forever.
    func testTheMacBundleDeclaresWhatASubmissionRequires() throws {
        let script = try code(of: "build_app.sh")
        for key in ["ITSAppUsesNonExemptEncryption", "NSHumanReadableCopyright",
                    "LSApplicationCategoryType", "LSMinimumSystemVersion", "NSMicrophoneUsageDescription"] {
            XCTAssertTrue(script.contains("<key>\(key)</key>"), "the macOS Info.plist no longer declares \(key)")
        }
        // …and iOS, which already had it, must keep it.
        let ios = try code(of: "apps/ios/Parla-iOS-Info.plist")
        XCTAssertTrue(ios.contains("ITSAppUsesNonExemptEncryption"))
    }

    /// Apple's SF Symbols licence forbids using the symbols — or anything confusingly similar — in an app icon.
    /// The macOS icon was DRAWN from `waveform` for months: a rejection, not a matter of taste. It now
    /// rasterises the project's own artwork, and this is what stops that being quietly undone.
    func testTheAppIconIsRealArtworkAndNotAnSFSymbol() throws {
        let generator = try code(of: "make_icon.swift")
        XCTAssertFalse(generator.contains("systemSymbolName"),
                       "the app icon is being drawn from an SF Symbol again — Apple's licence forbids that")
        XCTAssertTrue(generator.contains("AppIcon-1024.png"), "the generator must read the real artwork")

        let master = repoRoot.appendingPathComponent("apps/ios/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: master.path),
                      "the master artwork is missing — both platforms' icons come from this one file")
        let bytes = (try? Data(contentsOf: master))?.count ?? 0
        XCTAssertGreaterThan(bytes, 10_000, "the master artwork looks like a placeholder")
    }

    /// A build that loses its icon must FAIL, not print a tick over a faceless bundle. Three steps used to
    /// swallow their errors — `swift`, `sips` and `iconutil` — and the app is rejected without an icon.
    func testTheIconStepCannotFailSilently() throws {
        let script = try code(of: "build_app.sh")
        guard let iconBlock = script.range(of: "Generating the icon")
            .map({ String(script[$0.lowerBound...].prefix(1400)) }) else {
            return XCTFail("the icon step moved — this guard is now blind")
        }
        XCTAssertFalse(iconBlock.contains("iconutil -c icns \"$ISET\" -o Resources/AppIcon.icns >/dev/null 2>&1 || true"),
                       "iconutil failure is being swallowed again")
        XCTAssertTrue(iconBlock.contains("icon render failed"), "a failed render must abort the build")
        XCTAssertTrue(iconBlock.contains("AppIcon.icns is empty"), "an empty icns must abort the build")
    }


    /// There are now TWO macOS Info.plists: the heredoc `build_app.sh` writes for the direct-download build, and
    /// the file the Xcode target uses for the App Store build. They must agree on everything a FEATURE depends
    /// on, because a divergence is a deep link, a Handoff, or a Services menu item that works in one build and
    /// silently not in the other — the worst kind of difference, since both builds look fine.
    func testTheTwoMacInfoPlistsAgreeOnEverythingLoadBearing() throws {
        let script = try code(of: "build_app.sh")
        let store = try String(contentsOf: repoRoot.appendingPathComponent("apps/mac/Parla-macOS-Info.plist"),
                               encoding: .utf8)
        // The identity values are DERIVED from the two things build_app.sh actually authors, not written out
        // here. This test exists to prove the two plists AGREE — not that they say one particular name — and a
        // hardcoded name turned it into a rename detector: it went red on the rebrand and invited someone to
        // update the strings, which preserves the wording and loses the check.
        guard let bundleID = shellValue(of: "BUNDLE_ID", in: script), let appName = shellValue(of: "APP", in: script) else {
            return XCTFail("build_app.sh no longer authors APP / BUNDLE_ID — this test cannot check what it claims")
        }
        let namespace = bundleID.split(separator: ".").prefix(2).joined(separator: ".")

        // A scheme that differs by one letter is a dead link, not a warning — so these are compared as VALUES.
        for value in [String]([
            "<string>\(bundleID).url</string>",             // URL type name, derived from the bundle ID
            "<string>\(appName.lowercased())</string>",     // the URL scheme IS the lowercased app name
            "\(namespace).viewTranscript",                  // Handoff activity type, in the app's namespace
            "transcribeFiles",                              // the Services selector
            "<string>\(appName)</string>",                  // NSPortName — Services breaks if this differs
            "public.app-category.productivity",
            "ITSAppUsesNonExemptEncryption",
            "NSMicrophoneUsageDescription",
        ]) {
            XCTAssertTrue(script.contains(value), "build_app.sh's plist no longer carries \(value)")
            XCTAssertTrue(store.contains(value), "the App Store plist no longer carries \(value)")
        }
        // …and the store plist is ALWAYS the gated build, with no --store switch to forget.
        XCTAssertTrue(store.contains("<key>ParlaStoreBuild</key><true/>"),
                      "the Mac App Store build must be gated unconditionally — there is no ungated variant of it")
    }

    /// Every sandbox entitlement is something App Review can ask us to justify, so the set is pinned: adding one
    /// "just in case" should be a deliberate act with a reason, not a quiet edit.
    func testTheSandboxAsksForExactlyWhatTheFeaturesNeed() throws {
        let spec = try code(of: "apps/mac/project.yml")
        let required = ["com.apple.security.app-sandbox",
                        "com.apple.security.network.client",              // the one-time model download
                        "com.apple.security.files.user-selected.read-write",  // the folder-watch sidecar
                        "com.apple.security.files.bookmarks.app-scope",   // watched folder + re-transcribe
                        "com.apple.security.device.audio-input"]          // dictation
        for entitlement in required {
            XCTAssertTrue(spec.contains(entitlement), "the macOS target no longer requests \(entitlement)")
        }
        let declared = spec.components(separatedBy: "com.apple.security.").count - 1
        XCTAssertEqual(declared, required.count,
                       "the entitlement set changed — each one is a question at review, so justify it here")
        for never in ["temporary-exception", "cs.allow-unsigned-executable-memory", "cs.disable-library-validation",
                      "network.server", "device.camera", "personal-information"] {
            XCTAssertFalse(spec.contains(never), "\(never) invites a review question we have no answer for")
        }
    }

    /// An App Shortcut phrase may only interpolate an AppEntity or AppEnum — never an IntentFile. macOS shipped
    /// a phrase that did, and because a SwiftPM build never runs `appintentsmetadataprocessor`, nothing caught
    /// it: the app went out with NO Metadata.appintents at all, so Shortcuts and Siri could not see a single
    /// intent. iOS had already hit and fixed this. The Xcode target is what finally surfaced it on macOS.
    func testNoAppShortcutPhraseInterpolatesAFileParameter() throws {
        for path in ["Sources/Parla/ParlaIntents.swift", "apps/ios/Sources/ParlaIntents.swift"] {
            let text = try code(of: path)
            XCTAssertFalse(text.contains("$file)"),
                           "\(path) interpolates a file into a spoken phrase — the metadata export halts, and "
                           + "the app then ships with no App Intents metadata whatsoever")
        }
    }


    /// `build_app.sh` assembles the bundle by hand, and for months it left out the one thing Xcode does for
    /// free: App Intents metadata. Without `Metadata.appintents` Shortcuts, Spotlight and Siri see NOTHING,
    /// while the README advertises three intents by name. It is fixable rather than a limit of the script —
    /// xcodebuild already emits the `.swiftconstvalues` the processor needs, they were simply never consumed.
    func testTheHandAssembledBundleAlsoGetsItsAppIntentsMetadata() throws {
        let script = try code(of: "build_app.sh")
        XCTAssertTrue(script.contains("appintentsmetadataprocessor"),
                      "the from-source build no longer produces App Intents metadata — Shortcuts/Siri would be "
                      + "silently dead in every build that is not made by Xcode")
        XCTAssertTrue(script.contains("swiftconstvalues"), "the processor needs the compiler's const values")
        // And it must be FATAL. A feature vanishing in silence is the exact failure this closes.
        XCTAssertTrue(script.contains("Metadata.appintents/extract.actionsdata"),
                      "nothing verifies the metadata is non-empty")
        XCTAssertTrue(script.contains("Refusing to ship a bundle whose advertised automation is absent"),
                      "a missing metadata step must abort the build, not warn")
    }

    /// The signature seals `Contents/Resources`, so ANY step that writes into the bundle AFTER `codesign`
    /// breaks that seal — and the `--verify` sitting right beside it still passes, because it ran before the
    /// mutation. Not hypothetical: the App Intents step was appended to the BOTTOM of the script, and the
    /// resulting .app failed both `codesign --verify --deep --strict` and `spctl -a -t exec` with "a sealed
    /// resource is missing or invalid" while the build printed a green ✅. Pinned as an ORDER rather than a
    /// line number, so the next step appended at the end goes red here instead of shipping a broken seal.
    func testNothingWritesIntoTheBundleAfterItIsSigned() throws {
        let script = try code(of: "build_app.sh")
        guard let signing = script.range(of: "codesign --force") else {
            return XCTFail("build_app.sh no longer signs the bundle — this test cannot check what it claims")
        }
        // Verbs that CREATE or REWRITE bundle content. Read-only inspection (`otool`, `codesign --verify`) and
        // the final `open` are deliberately absent — they cannot invalidate a signature.
        let mutations = ["appintentsmetadataprocessor", "cp ", "mv ", "rm ", "mkdir", "ditto", "touch ",
                         "plutil", "install_name_tool", "sed -i", "defaults write", "cat >"]
        // Continuations first: `xcrun appintentsmetadataprocessor \` carries no `$APPDIR` on its own line —
        // the `--output "$APPDIR/…"` is one line below it. Scanning raw lines let exactly this bug through.
        let afterSigning = script[signing.upperBound...]
            .replacingOccurrences(of: "\\\n", with: " ")
        for var line in afterSigning.split(separator: "\n").map(String.init) {
            // An `|| { rm -rf "$tmp"; … }` error branch cleans up scratch space; it never builds the bundle,
            // and flagging it would make this guard cry wolf next to the real cause on the same line.
            if let bail = line.range(of: "||") { line = String(line[..<bail.lowerBound]) }
            guard line.contains("$APPDIR") else { continue }
            for verb in mutations where line.contains(verb) {
                XCTFail("`\(verb.trimmingCharacters(in: .whitespaces))` writes into the bundle after it is "
                        + "signed, breaking the seal that `codesign --verify` above has already checked: \(line)")
            }
        }
        guard let intents = script.range(of: "appintentsmetadataprocessor") else {
            return XCTFail("the App Intents step is gone — its own test covers that, this one builds on it")
        }
        XCTAssertTrue(intents.lowerBound < signing.lowerBound,
                      "App Intents metadata lands in Contents/Resources after the bundle is sealed")
    }
    /// The README's test count had gone stale by TWO HUNDRED — it advertised "360+" against a real 560, in two
    /// places, alongside two more stale counts in CI comments. Nobody is harmed by an understated number, but it
    /// is the first figure a pedant checks, and four disagreeing copies of it say something about doc discipline
    /// that the code does not deserve. So the claim is pinned in both directions: the README may never OVERSTATE
    /// (that would be a false claim), and it may not fall more than a release's worth of tests behind either.
    func testTheReadmeTestCountMatchesTheSuite() throws {
        let testsDir = repoRoot.appendingPathComponent("Tests/ParlaTests")
        let files = try FileManager.default.subpathsOfDirectory(atPath: testsDir.path)
            .filter { $0.hasSuffix(".swift") }
        var actual = 0
        for f in files {
            let src = try String(contentsOf: testsDir.appendingPathComponent(f), encoding: .utf8)
            actual += src.components(separatedBy: "func test").count - 1
        }
        XCTAssertGreaterThan(actual, 100, "counting the suite failed — the guard below would be meaningless")

        let readme = try code(of: "README.md")
        guard let range = readme.range(of: #"(\d+)\+? pure-logic unit tests"#, options: .regularExpression),
              let claimed = Int(readme[range].prefix(while: \.isNumber)) else {
            return XCTFail("README no longer states a pure-logic test count — this test cannot check what it claims")
        }
        XCTAssertLessThanOrEqual(claimed, actual,
                                 "README claims \(claimed) pure-logic tests but the suite has \(actual) — never overstate")
        XCTAssertLessThanOrEqual(actual - claimed, 60,
                                 "README claims \(claimed) but the suite has \(actual): the number has gone stale again")
    }
}
