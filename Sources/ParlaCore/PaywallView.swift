import SwiftUI
import StoreKit

/// The Pro paywall — ONE shared view for macOS + iOS, presented as a sheet by the free-tier length gate (with a
/// `reason`, giving a contextual up-front line) or opened directly from Settings (`reason == nil`, a generic
/// upgrade). Reads the injected `PurchaseManager` for the product/price + the purchase/restore flow, and
/// auto-dismisses the moment the entitlement flips to Pro.
///
/// Server-less by design: no account, no receipt server — the buy/restore is pure StoreKit 2. Degrades
/// gracefully when the store is unreachable (ad-hoc build / offline): the CTA disables and an "unavailable"
/// note shows instead of a dead button.
public struct PaywallView: View {
    @Environment(PurchaseManager.self) private var purchases
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showRedeem = false   // iOS offer-code redeem sheet

    /// Why the paywall opened — drives the contextual line (nil = a generic upgrade, e.g. from Settings).
    let reason: PaywallReason?
    public init(reason: PaywallReason? = nil) { self.reason = reason }

    private struct Feature: Identifiable { let id = UUID(); let icon: String; let title: String; let detail: String }
    private var features: [Feature] {
        [
            .init(icon: "infinity",              title: L("paywall.feature.length"),   detail: L("paywall.feature.length.detail")),
            .init(icon: "list.bullet.rectangle", title: L("paywall.feature.chapters"), detail: L("paywall.feature.chapters.detail")),
            .init(icon: "square.stack.3d.up",    title: L("paywall.feature.batch"),    detail: L("paywall.feature.batch.detail")),
            .init(icon: "captions.bubble",       title: L("paywall.feature.export"),   detail: L("paywall.feature.export.detail")),
            .init(icon: "sparkles",              title: L("paywall.feature.ai"),       detail: L("paywall.feature.ai.detail")),
        ]
    }

    public var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        if let line = contextLine {
                            Text(line)
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        }
                        VStack(spacing: 16) { ForEach(features) { featureRow($0) } }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                footer
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 620)
        #endif
        .preferredColorScheme(.dark)
        .onAppear { purchases.clearError() }   // don't greet a fresh open with a stale error from a prior attempt
        .onChange(of: purchases.isPro) { _, pro in if pro { dismiss() } }   // purchase / restore / redeem succeeded → close
        .task { if purchases.proProduct == nil { await purchases.loadProduct() } }
        #if os(iOS)
        .offerCodeRedemption(isPresented: $showRedeem) { _ in }   // a redeemed code arrives via Transaction.updates → isPro flips → auto-dismiss
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("common.cancel"))
            }
            Image(systemName: "crown.fill").font(.system(size: 34)).foregroundStyle(Brand.gradient)
            Text(L("paywall.title"))
                .font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Brand.gradient)
            Text(L("paywall.subtitle"))
                .font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func featureRow(_ f: Feature) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: f.icon).font(.title3).foregroundStyle(Brand.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.title).font(.headline)
                Text(f.detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let err = purchases.lastError {
                Text(err).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task { await purchases.purchase() }
            } label: {
                Group {
                    if purchases.purchasing { ProgressView() }
                    else { Text(ctaLabel) }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).tint(Brand.accent)
            .disabled(purchases.proProduct == nil || purchases.purchasing)

            HStack(spacing: 16) {
                Button(L("paywall.restore")) { Task { await purchases.restore() } }
                    .disabled(purchases.purchasing)
                // Offer-code redemption (the "first 100 free" mechanic). iOS gets the in-app sheet; macOS 14 has
                // none → open the App Store, where the user redeems (Account → Redeem).
                Button(L("paywall.redeem")) {
                    #if os(iOS)
                    showRedeem = true
                    #else
                    openURL(URL(string: "macappstore://apps.apple.com/redeem?ctx=offercodes")!)
                    #endif
                }
            }
            .buttonStyle(.plain).font(.subheadline).foregroundStyle(Brand.accent)

            Text(L("paywall.reassure")).font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if purchases.proProduct == nil {
                Text(L("paywall.unavailable.note")).font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    private var ctaLabel: String {
        if let price = purchases.proProduct?.displayPrice { return Lf("paywall.cta.price", price) }
        return L("paywall.cta.unavailable")
    }

    /// The contextual up-front line — length-gated ("This recording runs about 12 min…") or feature-locked
    /// ("Export to SRT/VTT/JSON is a Pro feature"). nil for a generic upgrade (from Settings).
    private var contextLine: String? {
        switch reason {
        case .lengthExceeded(_, let dur):
            let minutes = max(1, Int((dur / 60).rounded()))
            return Lf("paywall.length.body", minutes)
        case .featureLocked(let feature):
            switch feature {
            case .export:      return L("paywall.locked.export")
            case .batch:       return L("paywall.locked.batch")
            case .folderWatch: return L("paywall.locked.folderwatch")
            case .aiPower:     return L("paywall.locked.aipower")
            }
        case nil:
            return nil
        }
    }
}

/// A drop-in Settings section (macOS + iOS) for the Pro entitlement: for a free user, an "Unlock Pro" button
/// (opens the paywall) + Restore; for a Pro user, an active-status line. Self-contained — it presents its own
/// paywall sheet, so both apps' Settings just place `ProSettingsSection()` inside their `Form`. Reads the
/// injected `PurchaseManager` (must be in the environment, which both app roots provide).
public struct ProSettingsSection: View {
    @Environment(PurchaseManager.self) private var purchases
    @State private var showPaywall = false
    public init() {}

    public var body: some View {
        Section(L("settings.section.pro")) {
            if purchases.isPro {
                LabeledContent(L("settings.pro.active")) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Brand.accent)
                }
                Text(L("settings.pro.thanks")).font(.caption).foregroundStyle(.secondary)
            } else {
                Button(L("settings.pro.unlock")) { showPaywall = true }
                Button(L("paywall.restore")) { Task { await purchases.restore() } }
                    .disabled(purchases.purchasing)
                Text(L("settings.pro.hint")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView().environment(purchases)
        }
    }
}

/// A drop-in Settings section for the optional "tip the developer" jar (D3). Self-contained: reads the injected
/// `PurchaseManager` for the consumable tip tiers and shows a thank-you after a tip (a tip grants NO entitlement).
/// Placement-guarded per the Branch-2 decision: renders ONLY for an already-Pro user or a heavy free user
/// (≥10 notes), and both apps place it at the BOTTOM (About area), never adjacent to the Pro CTA.
public struct TipJarView: View {
    @Environment(PurchaseManager.self) private var purchases
    @Environment(AppModel.self) private var model
    public init() {}

    public var body: some View {
        let heavyFree = model.history.count >= 10
        if (purchases.isPro || heavyFree), (!purchases.tipProducts.isEmpty || purchases.tipThanks) {
            Section(L("tip.section")) {
                if purchases.tipThanks {
                    Text(L("tip.thanks")).font(.callout)
                } else {
                    Text(L("tip.blurb")).font(.caption).foregroundStyle(.secondary)
                    ForEach(purchases.tipProducts, id: \.id) { p in
                        Button { Task { await purchases.tip(p) } } label: {
                            HStack { Text(p.displayName); Spacer(); Text(p.displayPrice).foregroundStyle(.secondary) }
                        }
                        .disabled(purchases.purchasing)
                    }
                }
            }
        }
    }
}
