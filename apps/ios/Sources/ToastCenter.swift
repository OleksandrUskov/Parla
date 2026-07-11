#if os(iOS)
import SwiftUI

/// iOS toast surface — the counterpart of the macOS `QuickToast.shared` floating panel. `AppModel`'s
/// `showToast`/`hideToast` seams are inert by default (Core stays UI-toolkit-free); `AppModel.iOS()` wires them
/// to this shared center and the root mounts `.parlaToast()` to render it. Without it, ALL dictation feedback
/// (mic-permission-denied, busy, failed, empty, done/copied) and the batch-complete toasts were silently
/// invisible on iOS — the seam stayed its Core no-op default. (Full-review D1/F1.)
///
/// A single `@MainActor @Observable` singleton (mirrors `AppModel`'s style): a Main-actor-isolated `static let`
/// so building the instance is isolation-clean under Swift 6, and reachable from the `AppModel.iOS()` factory
/// which runs before any view exists.
@MainActor @Observable final class ToastCenter {
    static let shared = ToastCenter()
    private init() {}

    struct Toast: Equatable { let text: String; let sticky: Bool }
    private(set) var current: Toast?

    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    /// Show `text`. A non-sticky toast auto-dismisses after a beat; a sticky one stays until `hide()` (used for
    /// long-running states the caller ends explicitly). A new toast cancels any pending auto-dismiss.
    func show(_ text: String, sticky: Bool) {
        dismissTask?.cancel()
        current = Toast(text: text, sticky: sticky)
        guard !sticky else { return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }

    func hide() {
        dismissTask?.cancel()
        current = nil
    }
}

/// The floating toast pill, mounted once at the root. Reading `center.current` in `body` (an `@Observable`)
/// is what tracks changes — no `@ObservedObject` needed.
struct ToastOverlay: ViewModifier {
    let center: ToastCenter

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = center.current {
                Text(toast.text)
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 80)   // sit above the tab bar (transient — exact inset is easy to tune)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: center.current)
    }
}

extension View {
    /// Mount the iOS toast surface (dictation + batch feedback). `@MainActor` so the shared-center access is clean.
    @MainActor func parlaToast() -> some View { modifier(ToastOverlay(center: .shared)) }
}
#endif
