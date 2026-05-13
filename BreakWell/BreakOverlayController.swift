import AppKit
import SwiftUI

/// AppKit-backed overlay covering every connected display.
/// One borderless window per `NSScreen`; rebuilt when screens connect/disconnect.
@MainActor
final class BreakOverlayController {
    private let state = BreakOverlayState()
    private let onSkip: () -> Void
    private var windows: [OverlayWindow] = []
    private var screenChangeObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var isShowing = false

    init(onSkip: @escaping () -> Void) {
        self.onSkip = onSkip
    }

    // No deinit cleanup: controller lives for the app's lifetime, and `hide()`
    // releases the observer + monitor on every break end.

    func show(remaining: TimeInterval) {
        state.remaining = remaining
        isShowing = true
        rebuildWindowsForCurrentScreens()
        // Bring app to front so windows can become key and receive ESC.
        NSApp.activate(ignoringOtherApps: true)
        installScreenChangeObserver()
        installKeyMonitor()
    }

    func update(remaining: TimeInterval) {
        state.remaining = remaining
    }

    func hide() {
        isShowing = false
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        removeScreenChangeObserver()
        removeKeyMonitor()
    }

    // MARK: - Screen handling

    private func rebuildWindowsForCurrentScreens() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()

        for (index, screen) in NSScreen.screens.enumerated() {
            let window = makeOverlayWindow(for: screen)
            windows.append(window)
            // Make only the first window key — single key window is enough since
            // the ESC monitor below is application-wide.
            if index == 0 {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFront(nil)
            }
        }
    }

    private func makeOverlayWindow(for screen: NSScreen) -> OverlayWindow {
        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none

        let root = BreakOverlayView(state: state, onSkip: { [weak self] in self?.onSkip() })
        window.contentView = NSHostingView(rootView: root)
        window.setFrame(screen.frame, display: false)
        return window
    }

    private func installScreenChangeObserver() {
        guard screenChangeObserver == nil else { return }
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

    // MARK: - Key handling

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        // App-wide local monitor; works regardless of which overlay window is key.
        // Handler runs on the main thread but isn't annotated as such — keep `event`
        // out of the @MainActor block so NSEvent (non-Sendable) doesn't cross isolation.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated {
                guard let self, self.isShowing else { return }
                self.onSkip()
            }
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

/// Observable state shared between controller and SwiftUI overlay view.
@MainActor
@Observable
final class BreakOverlayState {
    var remaining: TimeInterval = 0
}

/// Borderless windows can't become key by default; override so the active overlay can.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
