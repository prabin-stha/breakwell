import AppKit
import SwiftUI

/// Shows a borderless floating banner at the top-center of the main display.
/// Stays above normal apps without taking focus. Optional auto-dismiss.
@MainActor
final class FloatingBannerController {
    private var window: BannerWindow?
    private var dismissTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private(set) var currentState: FloatingBannerState?

    private let topInset: CGFloat = 36
    private let minWidth: CGFloat = 260
    private let maxWidth: CGFloat = 700

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
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        // Let NSWindow render the shadow — it follows the opaque content's
        // shape exactly (rounded), so no rectangular cutoff.
        win.hasShadow = true
        // statusBar level keeps the banner visible regardless of which app is
        // frontmost — floating gets demoted when our app deactivates.
        win.level = .statusBar
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.hidesOnDeactivate = false
        win.ignoresMouseEvents = false
        win.animationBehavior = .none

        let view = FloatingBannerView(state: state, onDismiss: { [weak self] in
            self?.dismiss()
        })
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // Ensure the hosting view's own layer doesn't paint an opaque
        // rectangular backing behind the SwiftUI rounded content.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        win.contentView = hosting

        hosting.layout()
        let fitting = hosting.fittingSize
        let width = min(max(fitting.width, minWidth), maxWidth)
        let height = max(fitting.height, 60)
        win.setFrame(topCenterFrame(width: width, height: height), display: false)

        win.orderFront(nil)
        self.window = win
        installActivationObserver()

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
        removeActivationObserver()
        window?.orderOut(nil)
        window = nil
    }

    // MARK: - Re-assert front on app activation

    private func installActivationObserver() {
        guard activationObserver == nil else { return }
        // When any app activates, push our banner back to the front so it
        // doesn't get visually demoted in the focus transition.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.window?.orderFront(nil)
            }
        }
    }

    private func removeActivationObserver() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
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

private final class BannerWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
