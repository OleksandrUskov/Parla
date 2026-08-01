import Foundation
import Observation
import StoreKit

/// StoreKit-2 owner of the one-time "buy-forever" Pro entitlement (Branch 1 / Phase 3). Server-less: the
/// entitlement is Apple-side (on-device JWS `VerificationResult` — no receipt server, no accounts, no backend).
/// A single `@Observable isPro` drives the whole paywall; both apps construct ONE instance, inject it into the
/// SwiftUI environment, and call `start()` once from their launch `.task`.
///
/// Cross-platform pure StoreKit 2 (iOS 17 + macOS 14). Family Sharing is OFF (the product is non-shareable).
/// The in-app Offer-Code redeem sheet is presented by the UI layer (iOS-only; macOS 14 has no in-app sheet).
///
/// Degrades gracefully with no store: an ad-hoc build (or offline) leaves `proProduct` nil and `isPro` false —
/// the paywall shows a "temporarily unavailable" state instead of crashing. `start()` is intentionally NOT
/// called under unit tests, so the manager stays inert (no network, no entitlement scan) unless a test opts in.
@MainActor
@Observable
public final class PurchaseManager {
    /// Does the user currently own Pro? Truth = a verified, non-revoked entitlement for `ProGate.proProductID`
    /// in `Transaction.currentEntitlements` (refunds/revocations drop out of that set automatically). A dev
    /// override wins when set — for manually verifying the gate + paywall in the built app before a real IAP exists.
    public var isPro: Bool { devOverride ?? storeEntitled }

    /// The purchasable Pro product once loaded (nil until `start()` loads it, or if the store is unreachable).
    public private(set) var proProduct: Product?

    /// A purchase / restore is in flight — drives the paywall spinner + disables its buttons.
    public private(set) var purchasing = false

    /// Last user-facing purchase/restore error (localized) for inline display; cleared on the next attempt.
    public private(set) var lastError: String?

    /// StoreKit-derived ownership (the `currentEntitlements` scan). Private so `isPro` is the only public read.
    private var storeEntitled = false

    /// DEBUG-only dev/QA override read once from `UserDefaults` at init — `"debugProState"` = `"pro"` | `"free"`
    /// forces the entitlement; unset = real StoreKit. Always nil in release builds (see init), so it can't ship.
    private let devOverride: Bool?

    /// The lifetime `Transaction.updates` listener — catches transactions that happen OUTSIDE `purchase()`
    /// (offer-code redemptions, Ask-to-Buy approvals, a purchase on another device). Cancelled on deinit.
    /// `nonisolated(unsafe)`: mutated only on the main actor during the object's life; the nonisolated `deinit`
    /// reads it after all references are gone (no concurrent access), so cancelling there is race-free.
    nonisolated(unsafe) private var updatesTask: Task<Void, Never>?

    public init() {
        // DEBUG-ONLY so it can NEVER ship: a plain UserDefaults bypass in a release build (this repo is public)
        // would let anyone `defaults write … debugProState pro` to unlock Pro for free. Release builds get nil.
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "debugProState") {
        case "pro":  devOverride = true
        case "free": devOverride = false
        default:     devOverride = nil
        }
        #else
        devOverride = nil
        #endif
    }

    deinit { updatesTask?.cancel() }

    /// Begin observing transactions, resolve the current entitlement, and load the product for display.
    /// Idempotent (the listener is single-flight). The apps call this once from their launch `.task`; unit
    /// tests deliberately don't, so the manager never touches the store unless asked.
    public func start() async {
        if updatesTask == nil {
            updatesTask = Task { [weak self] in
                // Start BEFORE any entitlement scan so no transaction slips between launch and listening.
                for await update in Transaction.updates {
                    await self?.handle(update)
                }
            }
        }
        await refreshEntitlements()
        await loadProduct()
    }

    /// Load the Pro product (price/title) for the paywall. Best-effort — leaves `proProduct` nil on any failure
    /// (offline, ad-hoc build with no StoreKit config), and the paywall degrades to "unavailable".
    public func loadProduct() async {
        proProduct = try? await Product.products(for: [ProGate.proProductID]).first
    }

    /// Buy Pro. Returns true on a verified purchase (`isPro` flips reactively). `.userCancelled` / `.pending`
    /// return false with no error — a pending Ask-to-Buy lands later through the updates listener.
    @discardableResult
    public func purchase() async -> Bool {
        guard let product = proProduct else { return false }   // button is disabled while nil; belt-and-suspenders
        purchasing = true
        lastError = nil
        defer { purchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()          // stop it reappearing in updates; required even for non-consumables
                await refreshEntitlements()
                return isPro
            case .userCancelled, .pending:
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Explicit "Restore Purchases" (an App-Store review requirement). Syncs with the App Store — which may
    /// prompt for the Apple-ID password — then re-resolves the entitlement.
    public func restore() async {
        purchasing = true
        lastError = nil
        defer { purchasing = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Internals

    /// Recompute ownership from the on-device entitlements — the authoritative "owns Pro right now" set
    /// (a refunded/revoked transaction is absent here, so ownership is lost the moment Apple revokes).
    private func refreshEntitlements() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result else { continue }   // never trust an unverified (tampered) payload
            if t.productID == ProGate.proProductID, t.revocationDate == nil { owned = true }
        }
        storeEntitled = owned
    }

    /// Handle a transaction delivered by `Transaction.updates`: finish it, then re-resolve the entitlement.
    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        await transaction.finish()
        await refreshEntitlements()
    }

    /// Unwrap a StoreKit `VerificationResult`, throwing on an unverified (untrusted) payload.
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error): throw error
        case .verified(let safe):       return safe
        }
    }

    #if DEBUG
    /// Test/preview hook: force the store-derived entitlement without a live store.
    public func previewSetPro(_ on: Bool) { storeEntitled = on }
    #endif
}
