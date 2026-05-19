import AppKit
import SwiftUI

// MARK: - BreakOverlayController
//
// Purpose: AppKit-level controller for the fullscreen break overlay. Manages
// one borderless NSWindow per connected display, listens for screen-change
// events to rebuild as monitors come and go, and handles the double-press
// ESC shortcut to skip.
//
// Architecture role: Bridge between SwiftUI (BreakOverlayView) and AppKit
// (NSWindow, NSEvent monitors). Lives here instead of in the coordinator
// because dealing with windows is decidedly UI-layer concern.
//
// Key types defined:
//   - BreakOverlayController: the class that owns the windows
//   - BreakOverlayState: @Observable state shared with the SwiftUI view
//   - OverlayWindow: private NSWindow subclass that overrides canBecomeKey
//
// Used by:
//   - OverlayPresenter (constructs, calls show/update/hide as phase changes)
//
// Depends on:
//   - AppKit for NSWindow, NSScreen, NSEvent, NSAnimationContext
//   - SwiftUI's NSHostingView to embed the SwiftUI content tree
//
// Swift concepts a learner will see here:
//   - @MainActor on the class: every property and method runs on the main
//     thread, which is required for AppKit window APIs.
//   - NSAnimationContext.runAnimationGroup: AppKit's animation API. The
//     completion handler isn't typed @MainActor, but it runs there — we
//     assert that with MainActor.assumeIsolated.
//   - NSEvent.addLocalMonitorForEvents: registers a block that gets every
//     key event delivered to our app's windows. Returning nil "swallows"
//     the event; returning the event lets it propagate normally.
//   - Static @MainActor observers stored as `Any?`: NSNotificationCenter
//     hands back an opaque observer token we need to keep alive (and pass
//     back when deregistering).

/// AppKit-backed overlay covering every connected display.
///
/// One borderless `NSWindow` per `NSScreen`; rebuilt when screens connect
/// or disconnect mid-break. Fades out via `NSAnimationContext` on hide so
/// the transition feels native instead of yanking.
///
/// Example usage (called from OverlayPresenter):
/// ```swift
/// let controller = BreakOverlayController(
///     onSkip: { /* end the firing */ },
///     onSnooze: { seconds in /* dismiss, drop marker, refire in N */ }
/// )
/// controller.show(remaining: 20, message: ...)
/// // ... per tick ...
/// controller.update(remaining: 19)
/// // ... eventually ...
/// controller.hide()
/// ```
@MainActor
final class BreakOverlayController {
    private let state = BreakOverlayState()
    /// Called when the user presses Esc twice or clicks Skip break.
    private let onSkip: () -> Void
    /// Called when the user clicks one of the "Snooze +Nm" buttons.
    /// Argument is the postpone offset in seconds (300/600/900). The
    /// coordinator dismisses the break, drops a snoozed-reminder marker,
    /// and reschedules the next firing for `now + seconds`.
    private let onSnooze: (TimeInterval) -> Void
    /// One window per screen.
    private var windows: [OverlayWindow] = []
    private var screenChangeObserver: NSObjectProtocol?
    /// Opaque token returned by NSEvent.addLocalMonitorForEvents — kept so
    /// we can deregister later. Apple's API hands back `Any?` here.
    private var keyMonitor: Any?
    private var isShowing = false
    /// NSApp.presentationOptions snapshot taken at show() time so we can
    /// restore exactly what was in place before. Optional so we don't
    /// double-snapshot if show() is called twice without a hide().
    private var previousPresentationOptions: NSApplication.PresentationOptions?

    // Double-press ESC: we record the time of the most recent ESC and only
    // dismiss when a second one arrives within the window.
    private var lastEscapeAt: Date?
    private let doubleEscapeWindow: TimeInterval = 1.5

    init(onSkip: @escaping () -> Void, onSnooze: @escaping (TimeInterval) -> Void) {
        self.onSkip = onSkip
        self.onSnooze = onSnooze
    }

    func show(remaining: TimeInterval, message: BreakMessage) {
        state.remaining = remaining
        state.title = message.title
        state.message = message.description
        isShowing = true
        lastEscapeAt = nil
        rebuildWindowsForCurrentScreens()
        // Bring our app forward so the borderless window receives key events.
        // Without this, the windows would render but ESC wouldn't reach us.
        NSApp.activate(ignoringOtherApps: true)
        installPresentationOptions()
        installScreenChangeObserver()
        installKeyMonitor()
    }

    func update(remaining: TimeInterval) {
        state.remaining = remaining
    }

    func hide() {
        isShowing = false
        lastEscapeAt = nil
        restorePresentationOptions()
        removeScreenChangeObserver()
        removeKeyMonitor()

        // Take a local snapshot so the animation completion can close them
        // even after `windows` is cleared (we want a new show() to be able
        // to build a fresh set immediately, not wait for the fade).
        let windowsToClose = windows
        windows.removeAll()

        // AppKit's animation grouping API. Animates any `.animator()` calls
        // inside the closure with the supplied duration / timing curve.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for window in windowsToClose {
                // `.animator()` is the proxy that turns property assignments
                // into animated changes. Setting alpha to 0 fades the window out.
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            // NSAnimationContext completion runs on the main thread but
            // isn't annotated @MainActor; assert isolation explicitly to
            // satisfy Swift 6 strict-concurrency checking.
            MainActor.assumeIsolated {
                for window in windowsToClose {
                    Self.teardownWindow(window)
                }
                // `windowsToClose` was the only remaining strong reference;
                // when this closure returns it goes out of scope and the
                // OverlayWindow instances deallocate. Their SwiftUI subtree
                // (AuroraBackground / TimelineView) is fully released —
                // without this teardown the 30 fps blob loop would keep
                // running invisibly forever after a break ended.
            }
        })
    }

    // MARK: - Screen handling

    /// Tear down any existing windows and create one per current `NSScreen`.
    /// Called both initially and whenever the screen layout changes (a
    /// monitor plugged in / removed / resolution changed).
    private func rebuildWindowsForCurrentScreens() {
        for window in windows {
            Self.teardownWindow(window)
        }
        windows.removeAll()

        for (index, screen) in NSScreen.screens.enumerated() {
            let window = makeOverlayWindow(for: screen)
            windows.append(window)
            if index == 0 {
                // Only the primary screen's window becomes key — that's
                // where ESC events are routed. The rest are just visible.
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFront(nil)
            }
        }
    }

    /// Fully release an overlay window so its embedded SwiftUI tree
    /// (including `AuroraBackground`'s `TimelineView(.animation)`) stops
    /// rendering. Order matters:
    ///   1. `contentView = nil` detaches the `NSHostingView`; SwiftUI
    ///      then tears down the root view and cancels its TimelineView /
    ///      `.task` modifiers.
    ///   2. `orderOut(nil)` makes sure it's off-screen.
    ///   3. `close()` ends the window lifecycle (delegate notification,
    ///      removal from window list). With `isReleasedWhenClosed = false`,
    ///      this is purely a lifecycle hook — actual deallocation is up
    ///      to ARC, which fires once the caller drops its last strong
    ///      reference.
    ///
    /// Static so it can run from inside the `runAnimationGroup` completion
    /// without retaining `self`.
    private static func teardownWindow(_ window: OverlayWindow) {
        window.contentView = nil
        window.orderOut(nil)
        window.close()
    }

    private func makeOverlayWindow(for screen: NSScreen) -> OverlayWindow {
        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // .screenSaver level: above almost everything (including the menu
        // bar's dropdowns and floating panels). The overlay is meant to be
        // unavoidable for the break duration.
        window.level = .screenSaver
        // Make it appear on every Space, including fullscreen ones, and
        // stay visible when the user cmd-tabs to another app.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none

        // Embed the SwiftUI overlay view via NSHostingView (AppKit ↔ SwiftUI
        // bridge). The state object is shared by reference so updates from
        // the controller automatically flow through to the view.
        let root = BreakOverlayView(
            state: state,
            onSkip: { [weak self] in self?.onSkip() },
            onSnooze: { [weak self] seconds in self?.onSnooze(seconds) }
        )
        window.contentView = NSHostingView(rootView: root)
        window.setFrame(screen.frame, display: false)
        return window
    }

    private func installScreenChangeObserver() {
        guard screenChangeObserver == nil else { return }
        // didChangeScreenParametersNotification fires when screen count,
        // resolution, or arrangement changes. We rebuild every window from
        // scratch on that — simpler than diffing old vs new screens.
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShowing else { return }
                self.rebuildWindowsForCurrentScreens()
            }
        }
    }

    private func removeScreenChangeObserver() {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
    }

    // MARK: - Presentation options — block Cmd+Tab / Cmd+H / Cmd+Q

    /// Lock the user into the overlay while it's showing. The window's
    /// `.screenSaver` level covers everything visually, but it doesn't
    /// stop the system app switcher (Cmd+Tab) — that's handled by the
    /// kernel/loginwindow at a layer above any window level. The right
    /// hook for that is `NSApplication.presentationOptions`, which the
    /// app sets while it's active to opt out of process switching.
    ///
    /// Options used:
    ///   - `.disableProcessSwitching`: blocks Cmd+Tab / Cmd+` so the user
    ///     can't slip out behind the overlay.
    ///   - `.disableHideApplication`: blocks Cmd+H, which would also
    ///     hide the overlay along with the rest of the app.
    ///   - `.hideDock` + `.hideMenuBar`: AppKit *requires*
    ///     `.disableProcessSwitching` to be paired with either `.hideDock`
    ///     or `.autoHideDock`; without one of those, assigning the option
    ///     throws `NSInvalidArgumentException`. We pick the hide-outright
    ///     variants (not auto-hide) because the overlay already covers the
    ///     whole screen — the dock and menu bar would be visually behind
    ///     the overlay anyway, so suppressing them avoids a one-frame flash
    ///     if the user's mouse drifts into the menu-bar / dock edge.
    ///
    /// We deliberately do NOT add `.disableForceQuit` — the user should
    /// always be able to bail out of the app via Cmd+Opt+Esc if something
    /// goes wrong; the goal is gentle pressure, not entrapment.
    ///
    /// Quirk: `disableProcessSwitching` only takes effect while our app
    /// is the frontmost active app. `show()` calls `NSApp.activate(...)`
    /// before we get here, so by the time the options are assigned we are
    /// (or are about to be) frontmost. If the user later clicks a visible
    /// gap to another app (shouldn't be possible — the overlay covers the
    /// whole screen rect including the menu bar area), focus would leave
    /// us and the options would silently stop applying; they re-engage
    /// automatically when we're frontmost again.
    private func installPresentationOptions() {
        guard previousPresentationOptions == nil else { return }
        previousPresentationOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [
            .disableProcessSwitching,
            .disableHideApplication,
            .hideDock,
            .hideMenuBar
        ]
    }

    private func restorePresentationOptions() {
        guard let previous = previousPresentationOptions else { return }
        NSApp.presentationOptions = previous
        previousPresentationOptions = nil
    }

    // MARK: - Key handling — double-press ESC to skip

    /// Installs a local event monitor that watches every keyDown the app
    /// receives. We're interested only in ESC (keyCode 53); other keys are
    /// passed through unchanged by returning the event from the block.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // keyCode 53 is Esc on every Mac keyboard layout (it maps to the
            // physical key, not a localized character).
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated {
                guard let self, self.isShowing else { return }
                let now = Date()
                // Two presses within the window → skip. One press →
                // remember the time; if the next one arrives in time, we
                // skip; otherwise the timer effectively resets.
                if let last = self.lastEscapeAt, now.timeIntervalSince(last) < self.doubleEscapeWindow {
                    self.lastEscapeAt = nil
                    self.onSkip()
                } else {
                    self.lastEscapeAt = now
                }
            }
            // Returning nil tells AppKit "we handled it, don't propagate".
            // ESC won't reach the underlying app while the overlay is up.
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

/// Observable state shared between the controller and the SwiftUI overlay
/// view. The controller mutates these properties; the view reacts.
///
/// @Observable means assigning to `remaining`, `title`, etc. automatically
/// triggers a re-render of any view body that read them.
@MainActor
@Observable
final class BreakOverlayState {
    var remaining: TimeInterval = 0
    var title: String = ""
    var message: String = ""
}

/// Borderless windows are by default not allowed to become "key" (receive
/// keyboard events). We override that here so ESC reaches our event monitor.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
