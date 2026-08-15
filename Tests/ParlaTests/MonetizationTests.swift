import XCTest
import os
import AVFoundation
import AppKit
@testable import ParlaCore
@testable import Parla

/// Free/Pro gating: the length cap, the store-build flag and its wiring, the entitlement race, and the queue-depth half of the batch gate.
final class MonetizationTests: ParlaLogicTestCase {
    // MARK: Monetization — free/Pro length gate (Phase 3)

    /// The stateless per-file length gate: FREE covers "up to 5 minutes" (inclusive); a longer file gates a
    /// non-Pro user; Pro is always unlimited; a zero/unknown duration never gates.
    func testProGateLengthBoundaries() {
        XCTAssertEqual(ProGate.freeLimitSec, 300, "free cap is 5 minutes")
        // Free user, at/under the cap → allowed.
        XCTAssertFalse(ProGate.exceedsFreeLimit(durationSec: 1,     isPro: false))
        XCTAssertFalse(ProGate.exceedsFreeLimit(durationSec: 299,   isPro: false))
        XCTAssertFalse(ProGate.exceedsFreeLimit(durationSec: 300,   isPro: false), "exactly 5 min is still free (inclusive)")
        // Free user, over the cap → gated.
        XCTAssertTrue(ProGate.exceedsFreeLimit(durationSec: 300.5,  isPro: false))
        XCTAssertTrue(ProGate.exceedsFreeLimit(durationSec: 301,    isPro: false))
        XCTAssertTrue(ProGate.exceedsFreeLimit(durationSec: 7200,   isPro: false))
        // Pro user → never gated, at any length.
        XCTAssertFalse(ProGate.exceedsFreeLimit(durationSec: 7200,  isPro: true))
        XCTAssertFalse(ProGate.exceedsFreeLimit(durationSec: 301,   isPro: true))
        // Unknown / non-positive duration → never gated (we don't block what we can't measure).
        XCTAssertFalse(ProGate.exceedsFreeLimit(durationSec: 0,     isPro: false))
        XCTAssertFalse(ProGate.exceedsFreeLimit(durationSec: -1,    isPro: false))
    }

    /// The placeholder product ID stays in the `com.parla.*` namespace until the app's final reserved namespace
    /// is flipped in (alongside the bundle IDs). Pins that no premature production-namespace ID leaked into code.
    func testProProductIDIsPlaceholderNamespace() {
        XCTAssertEqual(ProGate.proProductID, "com.parla.pro.lifetime")
        XCTAssertTrue(ProGate.proProductID.hasPrefix("com.parla."), "product ID stays in the placeholder namespace pre-rebrand")
    }


    // MARK: Monetization — is the gate even switched on? (the store-build flag and its wiring)

    /// The `ParlaStoreBuild` decode, including the trap. A plist value of the wrong TYPE used to read as `nil`
    /// and fall through to `false`, i.e. an App Store build with no paywall, no length cap and everything Pro
    /// free — whose only symptom is zero revenue. Truthy-of-any-type now counts, because writing the key at all
    /// can only have meant "this is the store build"; removing it is still how you ask for the full build.
    func testStoreBuildFlagDecodesEveryPlistShapeThatCouldShipUngated() {
        XCTAssertTrue(AppModel.storeBuildFlag(true))            // <true/>
        XCTAssertTrue(AppModel.storeBuildFlag(NSNumber(value: true)))
        XCTAssertTrue(AppModel.storeBuildFlag(1))               // <integer>1</integer>
        XCTAssertTrue(AppModel.storeBuildFlag("true"))          // <string>true</string> — the silent giveaway
        XCTAssertTrue(AppModel.storeBuildFlag("YES"))
        XCTAssertTrue(AppModel.storeBuildFlag("1"))
        XCTAssertFalse(AppModel.storeBuildFlag(nil))            // key absent → the from-source FULL build
        XCTAssertFalse(AppModel.storeBuildFlag(false))
        XCTAssertFalse(AppModel.storeBuildFlag(0))
        XCTAssertFalse(AppModel.storeBuildFlag("false"))
        XCTAssertFalse(AppModel.storeBuildFlag("no"))
        XCTAssertFalse(AppModel.storeBuildFlag(["not": "a flag"]))
        XCTAssertEqual(AppModel.storeBuildInfoKey, "ParlaStoreBuild")
    }

    /// A store build must gate on the LIVE entitlement, not on the fail-open default. This is the distinction
    /// that pays for the app: an untouched `PurchaseManager` answers `grantsUnlimited == true`, which is exactly
    /// what the unwired default answers — so the gate only proves itself once the first entitlement scan has
    /// landed and the manager starts saying "no".
    @MainActor func testStoreBuildGatesOnTheLiveEntitlementRatherThanTheFailOpenDefault() {
        let m = AppModel(engine: FakeEngine())
        let pm = PurchaseManager()
        m.isStoreBuild = true
        m.installStoreGate(pm, startingStore: false)   // `false` ONLY here: the manager stays inert in tests

        // Before StoreKit's first scan the gate fails open on purpose — never block a payer mid-cold-launch.
        XCTAssertTrue(m.isProUser(), "an unresolved entitlement must not gate anyone")

        // Scan landed, this user owns nothing → the gate must now say no. An unwired model would still say yes.
        pm.previewSetEntitlementsResolved(true)
        XCTAssertFalse(m.isProUser(), "a resolved non-payer must be gated — the wiring is what makes this false")

        // …and a payer stays unlimited.
        pm.previewSetPro(true)
        XCTAssertTrue(m.isProUser())
    }

    /// `installStoreGate` must also hand the gate a way to wait for FACT. Without `resolveEntitlements` the
    /// fail-open window is re-runnable — quit, relaunch, drop an over-cap file, repeat — which is how a
    /// trade-off becomes an unlimited workaround.
    @MainActor func testStoreBuildInstallsTheWaitForFactSeam() async {
        let m = AppModel(engine: FakeEngine())
        let pm = PurchaseManager()
        m.isStoreBuild = true
        m.installStoreGate(pm, startingStore: false)
        pm.previewSetEntitlementsResolved(true)
        await m.resolveEntitlements()          // the default is a no-op; the wired one consults the manager
        XCTAssertFalse(m.isProUser())
    }

    /// The other half of the contract: a from-source build is the FULL app and the gate must not be installed.
    @MainActor func testNonStoreBuildIsLeftCompletelyUngated() {
        let m = AppModel(engine: FakeEngine())
        let pm = PurchaseManager()
        XCTAssertFalse(m.isStoreBuild, "the Core default is the ungated build")
        m.installStoreGate(pm, startingStore: false)
        pm.previewSetEntitlementsResolved(true)
        XCTAssertTrue(m.isProUser(), "a from-source build stays unlimited no matter what the store says")
    }

    /// The invariant no type can express: that the apps actually CALL the thing. The wiring used to be three
    /// loose statements inside a SwiftUI `.task`; deleting them left every gate reading the fail-open default
    /// with the whole suite green and the Settings "Unlock Pro" section still rendering, because that section
    /// keys on `isStoreBuild` rather than on the wiring — a giveaway that looks exactly like a working store.
    /// Same shape as `testNoShippingCodeDetectsXCTest`: a claim about the build that only a file scan can hold.
    func testBothAppsInstallTheStoreGate() throws {
        for entry in ["Sources/Parla/ParlaApp.swift", "apps/ios/Sources/ParlaiOSApp.swift"] {
            let src = try String(contentsOf: repoRoot.appendingPathComponent(entry), encoding: .utf8)
            XCTAssertTrue(src.contains("installStoreGate(purchases)"),
                          "\(entry) no longer installs the store gate — the app would ship ungated")
            XCTAssertFalse(src.contains("startingStore:"),
                           "\(entry) must not opt out of starting StoreKit: without start() the entitlement "
                           + "never resolves, grantsUnlimited fails open forever, and everything is free")
        }
    }

    /// The paywall must not sell a capability the platform it is running on cannot perform. Folder watching is
    /// FSEvents-based (macOS only), yet the bullet list was built unconditionally, so the iOS paywall promised
    /// "…or auto-transcribe a watched folder" — in the title too ("Batch & folder watch"). That is an
    /// accurate-metadata problem at App Review and a broken promise to anyone who paid on iPhone; the iOS
    /// purchase unlocks iOS only, since the differing bundle IDs rule out a Universal Purchase today.
    func testPaywallNeverSellsFolderWatchWhereItDoesNotExist() {
        let withWatch = ProGate.paywallBullets(folderWatch: true)
        let without   = ProGate.paywallBullets(folderWatch: false)
        // Same promise SHAPE either way — the platform loses a capability, not a whole bullet.
        XCTAssertEqual(withWatch.count, without.count)
        XCTAssertEqual(withWatch.count, 5)
        XCTAssertTrue(withWatch.contains { $0.key == "paywall.feature.batch" })
        XCTAssertFalse(without.contains { $0.key == "paywall.feature.batch" },
                       "the folder-watch bullet must not appear where there is no folder watching")
        XCTAssertTrue(without.contains { $0.key == "paywall.feature.queue" })
        // …and the text behind it must not mention a watched folder in ANY language.
        for lang in ["en", "ru", "uk"] {
            activateLocalization(lang)
            let claims = without.flatMap { [L($0.titleKey), L($0.detailKey)] }.joined(separator: " ").lowercased()
            for banned in ["watched folder", "папку", "папки", "теку", "теки"] {
                XCTAssertFalse(claims.contains(banned),
                               "\(lang): the watch-less paywall still mentions a folder — “\(banned)”")
            }
        }
        activateLocalization("en")
    }

    /// Every key the paywall renders must resolve in all three catalogues. `testLocalizationKeyParity` only
    /// compares the catalogues to EACH OTHER, so a key that exists in none of them — a typo, or a bullet added
    /// without its strings — passes parity and ships as a raw `paywall.feature.…` on the buy screen.
    func testPaywallBulletKeysResolveInEveryCatalogue() {
        func keys(_ lang: String) -> Set<String> {
            let url = repoRoot.appendingPathComponent("Localization/\(lang).lproj/Localizable.strings")
            return Set((NSDictionary(contentsOf: url) as? [String: String] ?? [:]).keys)
        }
        let catalogues = ["en": keys("en"), "ru": keys("ru"), "uk": keys("uk")]
        let everyBullet = ProGate.paywallBullets(folderWatch: true) + ProGate.paywallBullets(folderWatch: false)
        for (lang, present) in catalogues {
            XCTAssertGreaterThan(present.count, 100, "\(lang) catalogue looks empty/unreadable")
            for bullet in everyBullet {
                XCTAssertTrue(present.contains(bullet.titleKey),  "\(lang) is missing \(bullet.titleKey)")
                XCTAssertTrue(present.contains(bullet.detailKey), "\(lang) is missing \(bullet.detailKey)")
            }
        }
    }

    /// The one inch of the platform split that tests cannot execute is the `#if` behind this constant — so pin
    /// it against the host that IS running: these tests are a macOS bundle, and macOS is where folder watching
    /// lives. If the constant is ever inverted or hardcoded, this goes red here rather than on a user's iPhone.
    func testFolderWatchCapabilityMatchesTheHostPlatform() {
        #if os(macOS)
        XCTAssertTrue(ProGate.platformHasFolderWatch)
        #else
        XCTAssertFalse(ProGate.platformHasFolderWatch)
        #endif
    }

    /// exportIsGated: a free user is blocked (with a paywall) on the Pro formats only; a Pro user never is.
    @MainActor func testExportGateFreeVsPro() {
        let m = AppModel(engine: FakeEngine())
        m.isProUser = { false }
        XCTAssertFalse(m.exportIsGated(.txt));      XCTAssertNil(m.paywallReason)
        XCTAssertFalse(m.exportIsGated(.markdown)); XCTAssertNil(m.paywallReason)
        XCTAssertTrue(m.exportIsGated(.srt))
        guard case .featureLocked(.export)? = m.paywallReason else { return XCTFail("SRT should upsell for a free user") }
        m.paywallReason = nil
        XCTAssertTrue(m.exportIsGated(.vtt));  m.paywallReason = nil
        XCTAssertTrue(m.exportIsGated(.json)); m.paywallReason = nil
        // Pro user: nothing gated.
        m.isProUser = { true }
        for fmt in ExportFormat.allCases { XCTAssertFalse(m.exportIsGated(fmt)) }
        XCTAssertNil(m.paywallReason)
    }

    /// Batch (a multi-file drop) is Pro: a free user transcribes NONE of them and sees the upsell.
    @MainActor func testBatchGateBlocksMultiFileForFree() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "a", language: "en", segments: [], duration: 1),
                                            EngineResult(text: "b", language: "en", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }; m.soundOnComplete = false; m.history = []; m.autoCopy = false
            m.isProUser = { false }
            let a = makeTempSource("a.m4a"), b = makeTempSource("b.m4a")
            defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }

            await m.transcribe(urls: [a, b])

            XCTAssertTrue(m.history.isEmpty, "a free multi-file batch transcribes nothing")
            XCTAssertEqual(fake.transcribeCalls, 0)
            guard case .featureLocked(.batch)? = m.paywallReason else { return XCTFail("batch should upsell") }
        }
    }

    /// A single-file drop is never batch-gated (a free user still gets one-at-a-time transcription).
    @MainActor func testBatchGateAllowsSingleFileForFree() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "ok", language: "en", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }; m.soundOnComplete = false; m.history = []; m.autoCopy = false
            m.isProUser = { false }
            m.mediaDuration = { _ in 60 }   // short → not length-gated either
            let a = makeTempSource("a.m4a")
            defer { try? FileManager.default.removeItem(at: a) }

            await m.transcribe(urls: [a])

            XCTAssertEqual(m.history.count, 1)
            XCTAssertNil(m.paywallReason)
        }
    }

    /// A Pro user transcribes a whole batch (no gate).
    @MainActor func testBatchGateProProcessesAll() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "a", language: "en", segments: [], duration: 1),
                                            EngineResult(text: "b", language: "en", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }; m.soundOnComplete = false; m.history = []; m.autoCopy = false
            m.isProUser = { true }
            let a = makeTempSource("a.m4a"), b = makeTempSource("b.m4a")
            defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }

            await m.transcribe(urls: [a, b])

            XCTAssertEqual(m.history.count, 2)
            XCTAssertNil(m.paywallReason)
        }
    }

    /// Folder-watch is Pro: enabling it upsells a free user; turning it off / a Pro user is never gated.
    @MainActor func testFolderWatchEnableGate() {
        let m = AppModel(engine: FakeEngine())
        m.isProUser = { false }
        XCTAssertTrue(m.folderWatchEnableGated(true))
        guard case .featureLocked(.folderWatch)? = m.paywallReason else { return XCTFail("enabling watch should upsell") }
        m.paywallReason = nil
        XCTAssertFalse(m.folderWatchEnableGated(false))   // turning OFF is never gated
        XCTAssertNil(m.paywallReason)
        m.isProUser = { true }
        XCTAssertFalse(m.folderWatchEnableGated(true))    // Pro → not gated
        XCTAssertNil(m.paywallReason)
    }

    /// Generative AI power (model downloads, manual ✨ regenerate, per-chapter summaries) is Pro.
    @MainActor func testAiPowerGateFreeVsPro() {
        let m = AppModel(engine: FakeEngine())
        m.isProUser = { false }
        XCTAssertTrue(m.aiPowerIsGated())
        guard case .featureLocked(.aiPower)? = m.paywallReason else { return XCTFail("AI power should upsell") }
        m.paywallReason = nil
        m.isProUser = { true }
        XCTAssertFalse(m.aiPowerIsGated())
        XCTAssertNil(m.paywallReason)
    }

    /// Related is Pro but AUTO-computed on note open → a free user gets an EMPTY Related section, and it must NOT
    /// pop the paywall (that would fire on every note open).
    @MainActor func testRelatedClearedForFreeWithoutPaywall() {
        let m = AppModel(engine: FakeEngine())
        m.isProUser = { false }
        m.relatedIDs = [UUID(), UUID()]
        m.refreshRelatedNotes()
        XCTAssertTrue(m.relatedIDs.isEmpty, "a free user gets no Related")
        XCTAssertNil(m.paywallReason, "Related absence must NOT pop the paywall (it's auto-called on open)")
    }

    /// Folder-watch is Pro even after a refund: a persisted/running watcher's files are DROPPED for a non-Pro user
    /// at the drain (no transcribe, no paywall). Closes the review's launch-re-arm gate gap.
    @MainActor func testFolderWatchDrainDropsFilesForFreeUser() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "x", language: "en", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }; m.soundOnComplete = false; m.history = []
            m.isProUser = { false }
            // TWO files, not one. With a single-element queue this test passed identically with the Pro guard
            // deleted: removeFirst() and removeAll() both leave it empty and the count at 0, and transcribeCalls
            // is read before the un-awaited Task at the end of drainQueue can run — so nothing here could tell
            // the two branches apart. Two files make removeFirst() leave one behind, and `phase` (claimed
            // SYNCHRONOUSLY by the Pro branch) is the second discriminator.
            m.watchQueue = [URL(fileURLWithPath: "/tmp/parla-watched-1.m4a"),
                            URL(fileURLWithPath: "/tmp/parla-watched-2.m4a")]
            m.watchQueueCount = 2
            m.drainQueue()
            XCTAssertTrue(m.watchQueue.isEmpty, "a free user's watched files are ALL dropped, not transcribed")
            XCTAssertEqual(m.watchQueueCount, 0)
            XCTAssertEqual(m.phase, .idle, "the Pro branch claims the phase synchronously — a free user's never does")
            XCTAssertEqual(fake.transcribeCalls, 0)
        }
    }

    /// Download-tier semantic search is Pro (mirrors Related): a free user gets no semantic hits even if the embed
    /// model is still on disk (e.g. post-refund).
    @MainActor func testSemanticSearchClearedForFreeUser() async {
        let m = AppModel(engine: FakeEngine())
        m.isProUser = { false }
        m.semanticHitIDs = [UUID()]
        await m.refreshSemanticSearch()
        XCTAssertTrue(m.semanticHitIDs.isEmpty, "a free user gets no semantic search hits")
    }


    // MARK: Free-tier length gate (Phase 3)

    /// A non-Pro user dropping an over-cap file: it's skipped BEFORE any engine work (never decoded/transcribed),
    /// history stays empty, phase returns to .idle, and the paywall reason is set so the UI can upsell.
    @MainActor func testFreeLengthGateSkipsOverCapFileAndSetsPaywall() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "should not run", language: "ru", segments: [], duration: 600)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.isProUser = { false }                 // free tier
            m.mediaDuration = { _ in 600 }          // 10-minute file (over the 5-min cap)
            let src = makeTempSource()
            defer { try? FileManager.default.removeItem(at: src) }

            await m.transcribe(urls: [src])

            XCTAssertTrue(m.history.isEmpty, "over-cap file must not be transcribed for a free user")
            XCTAssertEqual(fake.transcribeCalls, 0, "no engine work should start for a gated file")
            XCTAssertEqual(fake.ensureLoadedCalls, 0)
            if case .idle = m.phase {} else { XCTFail("phase should be .idle after a pure-gate outcome") }
            guard case .lengthExceeded(let name, let dur)? = m.paywallReason else {
                return XCTFail("paywallReason should be .lengthExceeded")
            }
            XCTAssertEqual(name, src.lastPathComponent)
            XCTAssertEqual(dur, 600, accuracy: 0.001)
        }
    }

    /// A non-Pro user's file UNDER the cap transcribes normally — no gate, no paywall.
    @MainActor func testFreeUnderCapTranscribesNormally() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "ok", language: "ru", segments: [], duration: 60)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            m.isProUser = { false }
            m.mediaDuration = { _ in 60 }           // 1-minute file (under the cap)
            let src = makeTempSource()
            defer { try? FileManager.default.removeItem(at: src) }

            await m.transcribe(urls: [src])

            XCTAssertEqual(m.history.count, 1)
            XCTAssertEqual(fake.transcribeCalls, 1)
            XCTAssertNil(m.paywallReason)
        }
    }

    /// A Pro user is never length-gated — an over-cap file transcribes and the paywall never fires.
    @MainActor func testProUserBypassesLengthGate() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "long", language: "ru", segments: [], duration: 7200)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            m.isProUser = { true }                  // Pro (also the fail-open default)
            m.mediaDuration = { _ in 7200 }         // 2-hour file — never probed for Pro, never gated
            let src = makeTempSource()
            defer { try? FileManager.default.removeItem(at: src) }

            await m.transcribe(urls: [src])

            XCTAssertEqual(m.history.count, 1, "Pro transcribes any length")
            XCTAssertEqual(fake.transcribeCalls, 1)
            XCTAssertNil(m.paywallReason)
        }
    }

    /// Re-transcribe is a fresh transcription → the length gate must apply there too: a non-Pro user re-running
    /// an over-cap history note is blocked (old transcript untouched, no engine work) and the paywall shows.
    @MainActor func testRetranscribeGatedForFreeOverCapNote() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "NEW-should-not-apply", language: "en", segments: [], duration: 600)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.autoCopy = false
            m.isProUser = { false }
            let item = TranscriptItem(sourceName: "long.m4a", language: "en", durationSec: 600,
                                      model: "old-model", text: "OLD-keep-me", segments: [], sourcePath: "/tmp/parla-nope.m4a")
            m.history = [item]

            m.retranscribe(item, with: "new-model")
            await m.currentTranscriptionTask?.value   // nil when gated (no task spawned) → no-op

            XCTAssertEqual(m.history.first?.text, "OLD-keep-me")   // untouched
            XCTAssertEqual(m.history.first?.model, "old-model")    // not re-transcribed
            XCTAssertEqual(fake.transcribeCalls, 0)                // no engine work started
            guard case .lengthExceeded? = m.paywallReason else { return XCTFail("gated re-transcribe should show the paywall") }
        }
    }

    /// A Pro user re-transcribes an over-cap note normally (no gate).
    @MainActor func testRetranscribeProOverCapProceeds() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "NEW", language: "en", segments: [], duration: 600)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.autoCopy = false
            m.isProUser = { true }
            let src = makeTempSource("long.m4a")
            defer { try? FileManager.default.removeItem(at: src) }
            let item = TranscriptItem(sourceName: "long.m4a", language: "en", durationSec: 600,
                                      model: "old-model", text: "OLD", segments: [], sourcePath: src.path)
            m.history = [item]

            m.retranscribe(item, with: "new-model")
            await m.currentTranscriptionTask?.value

            XCTAssertEqual(m.history.first?.text, "NEW")           // replaced in place
            XCTAssertEqual(m.history.first?.model, "new-model")
            XCTAssertEqual(fake.transcribeCalls, 1)
            XCTAssertNil(m.paywallReason)
        }
    }

    /// PurchaseManager stays inert until `start()`: no entitlement, no product, no store contact — so a unit
    /// test can construct one without touching StoreKit. The DEBUG preview hook flips isPro for previews/tests.
    @MainActor func testPurchaseManagerInertUntilStart() {
        UserDefaults.standard.removeObject(forKey: "debugProState")   // ensure no dev override leaks in
        let pm = PurchaseManager()
        XCTAssertFalse(pm.isPro)
        XCTAssertNil(pm.proProduct)
        XCTAssertTrue(pm.tipProducts.isEmpty)
        XCTAssertFalse(pm.tipThanks)
        XCTAssertFalse(pm.entitlementsResolved)
        XCTAssertTrue(pm.grantsUnlimited, "gate fails open until entitlements resolve — never block a payer mid-launch")
        #if DEBUG
        pm.previewSetPro(true)
        XCTAssertTrue(pm.isPro)
        XCTAssertTrue(pm.grantsUnlimited)
        #endif
    }

    @MainActor func testTranscribeFailureRecordsAndLeavesHistory() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(throwOnTranscribe: true)
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }   // don't touch the notification center in tests
            m.soundOnComplete = false          // no completion beeps during tests
            m.history = []                     // ignore any legacy Murmur history migrated on the dev machine
            // src is .m4a → AVFoundation path: no converter involved (the engine throws before any audio work).
            let src = makeTempSource()
            defer { try? FileManager.default.removeItem(at: src) }

            await m.transcribe(urls: [src])

            XCTAssertTrue(m.history.isEmpty)               // a failed file never lands in history
            XCTAssertEqual(fake.transcribeCalls, 1)
            if case .failed = m.phase {} else { XCTFail("phase should be .failed") }
        }
    }

    @MainActor func testTranscribeBatchInsertsAllNewestFirst() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [
                EngineResult(text: "one",   language: "en", segments: [], duration: 1),
                EngineResult(text: "two",   language: "en", segments: [], duration: 1),
                EngineResult(text: "three", language: "en", segments: [], duration: 1),
            ])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }   // don't touch the notification center in tests
            m.soundOnComplete = false          // no completion beeps during tests
            m.history = []                     // ignore any legacy Murmur history migrated on the dev machine
            m.autoCopy = false
            // all .m4a → AVFoundation path: no converter involved (covered for ffmpeg by testTranscribeUsesConverterForOpus).
            let srcs = [makeTempSource("a.m4a"), makeTempSource("b.m4a"), makeTempSource("c.m4a")]
            defer { srcs.forEach { try? FileManager.default.removeItem(at: $0) } }

            await m.transcribe(urls: srcs)

            XCTAssertEqual(m.history.count, 3)
            XCTAssertEqual(fake.transcribeCalls, 3)
            XCTAssertEqual(m.history.first?.text, "three")   // insert(at:0) → last processed is newest
            if case .idle = m.phase {} else { XCTFail("phase should be .idle") }
        }
    }

    @MainActor func testTranscribeEmptyFolderFailsWithoutTouchingEngine() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine()
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }   // don't touch the notification center in tests
            m.soundOnComplete = false          // no completion beeps during tests
            m.history = []                     // ignore any legacy Murmur history migrated on the dev machine
            let emptyDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("empty-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: emptyDir) }

            await m.transcribe(urls: [emptyDir])

            XCTAssertTrue(m.history.isEmpty)
            XCTAssertEqual(fake.transcribeCalls, 0)          // no audio → engine never invoked
            if case .failed = m.phase {} else { XCTFail("phase should be .failed (no audio)") }
        }
    }

    @MainActor func testTranscribeMissingSourceStillSavesTranscript() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "text", language: "ru", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }   // don't touch the notification center in tests
            m.soundOnComplete = false          // no completion beeps during tests
            m.history = []                     // ignore any legacy Murmur history migrated on the dev machine
            m.autoCopy = false
            // ghost .m4a → AVFoundation path: the engine still runs (it doesn't read the file), keepAudio
            // gracefully no-ops on the missing source. No converter stub — none is reached.
            let ghost = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).m4a")

            await m.transcribe(urls: [ghost])

            XCTAssertEqual(m.history.count, 1)               // transcript is kept even if the source vanished
            XCTAssertEqual(m.history.first?.text, "text")
            XCTAssertNil(m.history.first?.audioFile)         // no source on disk → no player copy (graceful)
            XCTAssertNil(m.history.first?.audioPlayable)
        }
    }


    // MARK: The entitlement race — a gate must decide on fact, not on the fail-open guess

    /// THE abuse this closes. `grantsUnlimited` reports Pro until StoreKit's first scan lands, so a free user who
    /// dropped an over-cap file inside that launch window got it through — and could re-run the window at will by
    /// quitting and relaunching. The gate now awaits resolution first. Modelled exactly: `isProUser` starts
    /// answering "yes" (unresolved) and the seam flips it to the truth, as the real resolution does.
    @MainActor func testTheLengthGateWaitsForTheRealEntitlementBeforeDeciding() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine(), ai: NoopAIService(), embedder: FakeEmbedder())
            m.postNotification = { _, _ in }; m.soundOnComplete = false
            var resolved = false
            m.isProUser = { !resolved }                    // unresolved → fails OPEN, exactly like grantsUnlimited
            m.resolveEntitlements = { resolved = true }    // …and the scan says: not a subscriber
            m.mediaDuration = { _ in 1800 }                // 30 minutes — far past the 5-minute free cap

            await m.transcribe(urls: [URL(fileURLWithPath: "/tmp/parla-long.m4a")])

            XCTAssertTrue(resolved, "the gate must ask before it decides")
            XCTAssertTrue(m.history.isEmpty, "an over-cap file must not slip through the launch window")
            XCTAssertNotNil(m.paywallReason, "…and the user is told why")
        }
    }

    /// The queue gate's launch-window half. `enqueueManual` is synchronous and cannot wait, so during the
    /// window it lets a stacked job through on the fail-open guess. The job is now MARKED at enqueue time and
    /// re-gated inside transcribe, which does wait — so the drop-one-at-a-time bypass closes there too.
    @MainActor func testAStackedJobIsRegatedOnceTheRealEntitlementArrives() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine(), ai: NoopAIService(), embedder: FakeEmbedder())
            m.postNotification = { _, _ in }; m.soundOnComplete = false
            var resolved = false
            m.isProUser = { !resolved }                    // unresolved → fails OPEN, as at cold launch
            m.resolveEntitlements = { resolved = true }
            m.mediaDuration = { _ in 10 }                  // short: the LENGTH gate must not be what stops it

            await m.transcribe(urls: [URL(fileURLWithPath: "/tmp/parla-b.m4a")], queuedBehindAnother: true)

            XCTAssertTrue(m.history.isEmpty, "a job stacked behind another is the Pro batch feature")
            XCTAssertEqual(m.paywallReason, .featureLocked(.batch))
        }
    }

    /// …and a job that was NOT stacked is untouched — free is "one at a time", not "none".
    @MainActor func testAnUnstackedJobIsNotRegated() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "ок", language: "ru", segments: [], duration: 1)])
            let m = AppModel(engine: fake, ai: NoopAIService(), embedder: FakeEmbedder())
            m.postNotification = { _, _ in }; m.soundOnComplete = false
            m.isProUser = { false }; m.mediaDuration = { _ in 10 }

            await m.transcribe(urls: [URL(fileURLWithPath: "/tmp/parla-a.m4a")])

            XCTAssertEqual(m.history.count, 1, "a free user's single file still goes through")
            XCTAssertNil(m.paywallReason)
        }
    }

    /// The enqueue side must RECORD the stacking even when the guess lets it past the synchronous gate.
    @MainActor func testEnqueueMarksAJobStackedBehindRunningWork() {
        let m = AppModel(engine: FakeEngine(), ai: NoopAIService(), embedder: FakeEmbedder())
        m.isProUser = { true }              // fail-open, as during the launch window
        m.downloadingModel = "x"            // hold the lane shut so the queue stays observable
        m.enqueueManual([URL(fileURLWithPath: "/tmp/a.m4a")])
        m.enqueueManual([URL(fileURLWithPath: "/tmp/b.m4a")])

        XCTAssertEqual(m.transcriptionQueue.count, 2)
        XCTAssertFalse(m.transcriptionQueue[0].queuedBehindAnother, "the first job stands alone")
        XCTAssertTrue(m.transcriptionQueue[1].queuedBehindAnother, "the second is stacked — and must be marked")
    }

    /// The other half: a real payer must still never be blocked, whatever the timing.
    @MainActor func testAResolvedPayerIsNotGated() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "ок", language: "ru", segments: [], duration: 1)])
            let m = AppModel(engine: fake, ai: NoopAIService(), embedder: FakeEmbedder())
            m.postNotification = { _, _ in }; m.soundOnComplete = false
            m.isProUser = { true }
            m.mediaDuration = { _ in 1800 }

            await m.transcribe(urls: [URL(fileURLWithPath: "/tmp/parla-long.m4a")])

            XCTAssertEqual(m.history.count, 1, "a payer's 30-minute file goes through")
            XCTAssertNil(m.paywallReason)
        }
    }

    /// An unreachable store must not hang a transcription — the wait is bounded, and on timeout we still fail
    /// OPEN, because a store we cannot reach must never become a paywall for someone who already paid.
    @MainActor func testAwaitEntitlementsGivesUpInsteadOfHanging() async {
        let pm = PurchaseManager()                      // never started → the scan will never land
        let started = Date()
        await pm.awaitEntitlements(timeout: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "bounded, not open-ended")
        XCTAssertFalse(pm.entitlementsResolved)
        XCTAssertTrue(pm.grantsUnlimited, "still fails open on timeout — never block a payer")
    }


    // MARK: Free-tier batch gate — the queue-depth half

    /// batchIsGated only ever inspected the size of ONE drop, and nothing inspected queue depth. A free user
    /// therefore got an unlimited unattended batch by dropping files one at a time — the exact feature the
    /// paywall sells («Queue many files at once»), advertised back at them by the "+N queued" badge.
    @MainActor func testAFreeUserCannotStackASecondJobBehindARunningOne() {
        let m = AppModel(engine: FakeEngine(), ai: NoopAIService(), embedder: FakeEmbedder())
        m.isProUser = { false }
        m.transcriptionQueue = [TranscriptionJob(urls: [URL(fileURLWithPath: "/tmp/a.m4a")])]   // one already waiting

        m.enqueueManual([URL(fileURLWithPath: "/tmp/b.m4a")])

        XCTAssertEqual(m.transcriptionQueue.count, 1, "the second job is refused, not queued")
        XCTAssertEqual(m.paywallReason, .featureLocked(.batch), "…and the user is told why")
    }

    @MainActor func testAProUserCanStackJobs() {
        let m = AppModel(engine: FakeEngine(), ai: NoopAIService(), embedder: FakeEmbedder())
        m.isProUser = { true }
        m.downloadingModel = "x"   // hold the lane shut so the enqueue is observable before it drains
        m.transcriptionQueue = [TranscriptionJob(urls: [URL(fileURLWithPath: "/tmp/a.m4a")])]

        m.enqueueManual([URL(fileURLWithPath: "/tmp/b.m4a")])

        XCTAssertEqual(m.transcriptionQueue.count, 2, "Pro queues freely")
        XCTAssertNil(m.paywallReason)
    }

    /// The gate keys on real transcription work, NOT on `isBusy`: `isBusy` is also true while the MODEL is
    /// downloading, and making a free user wait for the model is not the batch feature they would be upsold for.
    @MainActor func testAModelDownloadDoesNotCountAsAQueuedJob() {
        let m = AppModel(engine: FakeEngine(), ai: NoopAIService(), embedder: FakeEmbedder())
        m.isProUser = { false }
        m.downloadingModel = "whisper"   // busy, but nothing is transcribing

        m.enqueueManual([URL(fileURLWithPath: "/tmp/a.m4a")])

        XCTAssertEqual(m.transcriptionQueue.count, 1, "the drop is accepted and simply waits for the model")
        XCTAssertNil(m.paywallReason)
    }

    /// The FIRST drop must never be gated — free is "one file at a time", not "no files".
    @MainActor func testAFreeUsersFirstDropIsNotGated() {
        let m = AppModel(engine: FakeEngine(), ai: NoopAIService(), embedder: FakeEmbedder())
        m.isProUser = { false }
        m.enqueueManual([URL(fileURLWithPath: "/tmp/a.m4a")])
        XCTAssertNil(m.paywallReason, "an idle free user dropping one file is the free tier working as sold")
    }


}
