import AppKit
import SwiftUI

// MARK: - FloatingBannerController
//
// Purpose: Manages a single borderless floating banner window at the top of
// the active screen. Used today by the pre-break heads-up (which carries
// the snooze action).
//
// Architecture role: AppKit window controller for one floating UI surface.
// Knows about NSWindow, NSPanel styles, and Spaces collection behavior;
// the SwiftUI content lives in FloatingBannerView.swift.
//
// About the UI/ folder:
// UI/ hosts SwiftUI surfaces that aren't tied to a single feature — the
// Settings window and these floating-banner pieces. Feature-specific views
// (the break overlay, the menu-bar popover) stay inside their feature
// folder; anything cross-cutting lives here.
//
// Key types defined:
//   - FloatingBannerController: @MainActor class owning the window
//   - BannerWindow: private NSPanel subclass that disables key/main status
//
// Used by:
//   - BreakWellApp (constructs)
//   - PreBreakNotifier (calls show with countdown content + snooze action)
//   - presentHandler closure (calls show for any banner-level firing)
//
// Depends on:
//   - AppKit's NSPanel + NSWorkspace
//   - SwiftUI's NSHostingView to embed the SwiftUI content
//
// Swift concepts a learner will see here:
//   - NSPanel + .nonactivatingPanel style: panels can receive clicks
//     without forcing the owning app to become frontmost. Without this,
//     clicking a snooze button would steal focus from whatever app the
//     user was actually working in.
//   - .canJoinAllSpaces / .fullScreenAuxiliary / .stationary: combined,
//     these make a window appear on every Space, follow into fullscreen
//     apps, and not animate between Spaces. The right combo for a
//     "system-wide notification" feel.
//   - Layer-level transparency control on NSHostingView: SwiftUI normally
//     draws into a layer with an opaque background; we force it clear so
//     the rounded SwiftUI content doesn't leak a rectangular ghost.

/// Shows a borderless floating banner at the top-center of the main display.
/// Stays above normal apps without taking focus. Optional auto-dismiss.
///
/// Example usage:
/// ```swift
/// let banner = FloatingBannerController()
/// let state = FloatingBannerState(
///     title: "Time for a sip of water",
///     body: "Stay hydrated.",
///     icon: .symbol(name: "drop.fill", color: .cyan)
/// )
/// banner.show(state)            // auto-dismisses after 8 seconds
/// banner.show(state, autoDismissAfter: 0) // stays until banner.dismiss()
/// ```
@MainActor
final class FloatingBannerController {
    private var window: BannerWindow?
    private var dismissTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    /// Currently-shown state. Callers can keep their own reference and
    /// mutate it to live-update the banner (e.g. countdown title).
    private(set) var currentState: FloatingBannerState?

    private let topInset: CGFloat = 36
    private let minWidth: CGFloat = 260
    private let maxWidth: CGFloat = 700

    /// Show the banner. Caller retains the state object and can mutate it
    /// to update the title (live countdowns) or swap actions on the fly —
    /// the SwiftUI view is @Observable on `FloatingBannerState`, so changes
    /// re-render automatically.
    ///
    /// `autoDismissAfter` of 0 disables auto-dismiss; the caller is then
    /// responsible for calling `dismiss()`.
    func show(_ state: FloatingBannerState, autoDismissAfter: TimeInterval = 8) {
        dismissTask?.cancel()
        if let existing = window {
            existing.orderOut(nil)
            window = nil
        }
        currentState = state

        let win = BannerWindow(
            contentRect: .zero,
            // .nonactivatingPanel is the key style here — it lets the user
            // click action buttons without making BreakWell the frontmost
            // app (which would steal focus from whatever they were doing).
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        // Let NSWindow render the shadow — it follows the opaque content's
        // shape exactly (rounded), so we don't get a rectangular cutoff.
        win.hasShadow = true
        // statusBar level keeps the banner visible regardless of which app
        // is frontmost — `.floating` gets demoted when our app deactivates.
        win.level = .statusBar
        // Show on every Space + over fullscreen apps + don't animate
        // between Spaces. Reads as a system-wide notification.
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.hidesOnDeactivate = false
        win.ignoresMouseEvents = false
        win.animationBehavior = .none

        let view = FloatingBannerView(state: state, onDismiss: { [weak self] in
            self?.dismiss()
        })
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // Ensure the hosting view's own CALayer doesn't paint an opaque
        // rectangular backing behind the SwiftUI rounded content. Without
        // this, the corners outside the rounded shape would show a gray
        // rectangle in some macOS versions.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        win.contentView = hosting

        // SwiftUI lays out the hosting view; we read the natural size and
        // clamp to our min/max width budget before placing the window.
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
        // `[weak self]` so the auto-dismiss task can't keep the controller
        // alive after the rest of the app has let it go.
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

    /// Some macOS focus changes can briefly drop our window behind another
    /// app's frontmost window. Listen for "any app activated" and pull
    /// ourselves back forward so the banner stays on top.
    private func installActivationObserver() {
        guard activationObserver == nil else { return }
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

    /// Compute the window's frame so its content sits centered horizontally
    /// at the top of the screen, with `topInset` clearance below the menu bar.
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

/// Private NSPanel subclass. The overrides are what make this a true
/// "doesn't steal focus" window: even with `.nonactivatingPanel`, a panel
/// can still become key/main unless we explicitly say otherwise.
private final class BannerWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
