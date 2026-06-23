import AppKit
import SwiftUI

/// Маленькое ненавязчивое окошко-тост у строки меню (для хоткея/быстрых действий).
/// Не крадёт фокус (.nonactivatingPanel) и авто-исчезает. macOS-14-safe (обычные материалы).
@MainActor
final class QuickToast {
    static let shared = QuickToast()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, sticky: Bool = false) {
        let host = NSHostingView(rootView: ToastView(text: text))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 48)

        let p = panel ?? makePanel()
        p.contentView = host
        positionTopTrailing(p)
        p.orderFrontRegardless()
        panel = p

        hideTask?.cancel()
        guard !sticky else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            self?.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hasShadow = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return p
    }

    private func positionTopTrailing(_ p: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        p.setFrame(NSRect(x: f.maxX - 316, y: f.maxY - 64, width: 300, height: 48), display: true)
    }
}

private struct ToastView: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform").foregroundStyle(Brand.gradient)
            Text(text).font(.callout).lineLimit(2)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
        .preferredColorScheme(.dark)
    }
}
