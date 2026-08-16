import XCTest
import StoreKit
import StoreKitTest
@testable import Parla_iOS
import ParlaCore

/// The money path, actually executed.
///
/// Everything downstream of the entitlement — the gates, the length cap, the export split — has been unit
/// tested for a long time by injecting `isProUser`. The methods that DECIDE that entitlement had never run in
/// any test at all: `purchase()`, `restore()`, the private `refreshEntitlements()` / `handle()` /
/// `checkVerified()`, and the `Transaction.updates` listener. They cannot be faked — `Product`,
/// `Transaction` and `VerificationResult` have no public initializers — so the only way to cover them is a
/// real `SKTestSession` against a synthetic store.
///
/// Why this suite lives on iOS rather than in the shared `swift test` suite: `StoreKitTest` links fine under
/// SwiftPM (its framework sits beside XCTest, already on the search path), but at RUNTIME the SwiftPM runner is
/// an unhosted `xctest` process with no bundle identity, and `buyProduct` fails there with `notEntitled` —
/// measured, not assumed. This target is hosted inside the real app bundle, which is what makes StoreKit
/// answer at all. The trade-off is that this coverage runs in CI's simulator job rather than on every
/// `swift test`, which is the honest cost of the only configuration where the flow is reachable.
///
/// `restore()` is the reason this matters beyond correctness: a missing or broken restore is an automatic
/// App Review rejection (Guideline 3.1.1), and until now nothing had ever executed it.
@MainActor
final class StoreKitMoneyPathTests: XCTestCase {

    private var session: SKTestSession!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Probe-and-skip rather than fail: this depends on a simulator behaviour outside our control, and a
        // suite that goes red on someone else's runner configuration teaches nobody anything. A skip is
        // visible in the log; a false red is noise that gets muted.
        do {
            session = try SKTestSession(configurationFileNamed: "Parla")
        } catch {
            throw XCTSkip("no StoreKit test session on this runner: \(error)")
        }
        // NOTE: `clearTransactions()` and NOT `resetToDefaultState()`. Reaching for the bigger reset looked
        // like better hygiene and was measured to be wrong: with it, a freshly bought non-consumable stops
        // appearing in `Transaction.currentEntitlements` at all, and the buy test fails in complete isolation.
        // Clearing transactions is what actually gives each test an empty store.
        session.disableDialogs = true          // never block a headless run on a system sheet
        session.askToBuyEnabled = false
        try session.clearTransactions()        // each test starts owning nothing
    }

    override func tearDown() {
        try? session?.clearTransactions()   // don't leak an entitlement into the next test
        session = nil
        super.tearDown()
    }

    /// The paywall can only show a price if the product loads. A silent failure here (every StoreKit call in
    /// `loadProduct` is `try?`) leaves `proProduct` nil and the CTA permanently disabled — a paywall that
    /// cannot be bought from, which looks like a design choice rather than a bug.
    func testTheProductThePaywallSellsActuallyLoads() async throws {
        let pm = PurchaseManager()
        await pm.loadProduct()
        let product = try XCTUnwrap(pm.proProduct, "the Pro product did not load — the paywall CTA would be dead")
        XCTAssertEqual(product.id, ProGate.proProductID)
        XCTAssertEqual(product.type, .nonConsumable, "Pro is a one-time buy-forever unlock, never a subscription")
    }

    /// Buying grants the entitlement, and — the part that pays — the gate flips with it.
    ///
    /// The purchase here is made OUTSIDE `purchase()`, which is the case `start()`'s `Transaction.updates`
    /// listener exists for: an offer-code redemption, an Ask-to-Buy approval, a purchase made on another
    /// device. That arrival is asynchronous by construction, so this waits for it instead of scanning once and
    /// assuming. Written the assuming way first, it passed in the full suite and failed in isolation — the
    /// suite was lending it time that production would not.
    func testBuyingProUnlocksTheGate() async throws {
        let model = AppModel.iOS()
        let pm = PurchaseManager()
        model.isStoreBuild = true
        model.installStoreGate(pm)

        await pm.start()                                    // resolve entitlements + load products, for real
        XCTAssertTrue(pm.entitlementsResolved, "start() must complete the first entitlement scan")
        XCTAssertFalse(pm.isPro, "nothing has been bought yet")
        XCTAssertFalse(model.isProUser(), "a resolved non-payer is gated")
        XCTAssertTrue(ProGate.exceedsFreeLimit(durationSec: 600, isPro: model.isProUser()),
                      "a 10-minute file must be gated for this user")

        _ = try await session.buyProduct(identifier: ProGate.proProductID)
        let arrived = await Self.eventually(timeout: 10) { pm.isPro }

        XCTAssertTrue(arrived, "the Transaction.updates listener never delivered the purchase")
        XCTAssertTrue(model.isProUser(), "the gate did not follow the purchase")
        XCTAssertFalse(ProGate.exceedsFreeLimit(durationSec: 36_000, isPro: model.isProUser()),
                       "Pro is unlimited length")
    }

    /// Bounded wait for a main-actor condition. Returns whether it came true, so the caller asserts with its
    /// own message rather than dying inside a helper.
    private static func eventually(timeout: TimeInterval,
                                   _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// Restore is not a nicety: shipping without a working one is an automatic rejection under Guideline
    /// 3.1.1. This is the first time `restore()` has ever been executed.
    func testRestoreRecoversAPurchaseOnAFreshInstall() async throws {
        _ = try await session.buyProduct(identifier: ProGate.proProductID)

        // A fresh install: a brand-new manager that has never seen this purchase.
        let pm = PurchaseManager()
        await pm.restore()

        XCTAssertNil(pm.lastError, "restore reported an error: \(pm.lastError ?? "")")
        XCTAssertTrue(pm.isPro, "restore did not recover the purchase")
        XCTAssertTrue(pm.entitlementsResolved)
    }

    /// Ownership must be lost when Apple takes it back. `refreshEntitlements` reads `currentEntitlements`,
    /// which a refunded transaction drops out of — this pins that the server-less model actually honours a
    /// refund, with no receipt server anywhere to ask.
    func testARefundRevokesPro() async throws {
        let transaction = try await session.buyProduct(identifier: ProGate.proProductID)
        let pm = PurchaseManager()
        await pm.start()
        XCTAssertTrue(pm.isPro)

        try await session.refundTransaction(identifier: UInt(transaction.id))
        await pm.restore()                                  // any path that re-scans entitlements

        XCTAssertFalse(pm.isPro, "a refunded purchase must not keep Pro")
    }

    /// `grantsUnlimited` fails open ONLY until the first scan lands. That window is deliberate — never gate a
    /// payer mid-cold-launch — but it must actually close, or the free tier is bypassable by relaunching.
    func testTheFailOpenWindowClosesOnceStoreKitAnswers() async throws {
        let pm = PurchaseManager()
        XCTAssertTrue(pm.grantsUnlimited, "before the first scan the gate deliberately fails open")
        XCTAssertFalse(pm.entitlementsResolved)

        await pm.start()

        XCTAssertTrue(pm.entitlementsResolved)
        XCTAssertFalse(pm.grantsUnlimited, "the fail-open window must close for a non-payer")

        // …and awaiting it is then instant, which is the fast path `awaitEntitlements` takes in production.
        let started = Date()
        await pm.awaitEntitlements(timeout: 3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "awaiting an already-resolved scan must not wait")
    }
}
