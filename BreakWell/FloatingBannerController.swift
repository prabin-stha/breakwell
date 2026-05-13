import AppKit
import SwiftUI

/// Shows a borderless floating banner at the top-center of the main display.
/// Stays above normal apps without taking focus. Optional auto-dismiss.
@MainActor
final class FloatingBannerController {
    private var window: BannerWindow?
    private var dismissTask: Task<Void, Never>?
    private(set) var currentState: FloatingBannerState?

    private let topInset: CGFloat = 36
    private let minWidth: CGFloat = 260
    private let maxWidth: CGFloat = 540

    /// Show the banner. Caller retains the state object and can mutate it to
    /// update the title (live countdowns) or swap actions on the fly.
    /// `autoDismissAfter` of 0 disables auto-dismiss — caller must call dismiss().
    func show(_ state: FloatingBannerState, autoDismissAfter: TimeInterval = 8) {
        dismissTask?.cancel()
        if let existing = window {
            existing.orderOut(nil)
            window = nil
        }
        currentState = state

        let win = BannerWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.ignoresMouseEvents = false
        win.animationBehavior = .none

        let view = FloatingBannerView(state: state, onDismiss: { [weak self] in
            self?.dismiss()
        })
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        win.contentView = hosting

        hosting.layout()
        let fitting = hosting.fittingSize
        let width = min(max(fitting.width, minWidth), maxWidth)
        let height = max(fitting.height, 60)
        win.setFrame(topCenterFrame(width: width, height: height), display: false)

        win.orderFront(nil)
        self.window = win

        guard autoDismissAfter > 0 else { return }
        let delay = autoDismissAfter
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        currentState = nil
        window?.orderOut(nil)
        window = nil
    }

    private func topCenterFrame(width: CGFloat, height: CGFloat) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 0, y: 0, width: width, height: height)
        }
        let frame = screen.visibleFrame
        let x = frame.midX - width / 2
        let y = frame.maxY - height - topInset
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

private final class BannerWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
