import AppKit
import SwiftUI

/// AppKit-backed overlay covering every connected display.
/// One borderless window per `NSScreen`; rebuilt when screens connect/disconnect.
@MainActor
final class BreakOverlayController {
    private let state = BreakOverlayState()
    private let onSkip: () -> Void
    private let onExtend: (TimeInterval) -> Void
    private var windows: [OverlayWindow] = []
    private var screenChangeObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var isShowing = false

    private var lastEscapeAt: Date?
    private let doubleEscapeWindow: TimeInterval = 1.5

    init(onSkip: @escaping () -> Void, onExtend: @escaping (TimeInterval) -> Void) {
        self.onSkip = onSkip
        self.onExtend = onExtend
    }

    func show(remaining: TimeInterval, content: BreakContent, message: BreakMessage) {
        state.remaining = remaining
        state.content = content
        state.title = message.title
        state.message = message.description
        isShowing = true
        lastEscapeAt = nil
        rebuildWindowsForCurrentScreens()
        NSApp.activate(ignoringOtherApps: true)
        installScreenChangeObserver()
        installKeyMonitor()
    }

    func update(remaining: TimeInterval) {
        state.remaining = remaining
    }

    func hide() {
        isShowing = false
        lastEscapeAt = nil
        removeScreenChangeObserver()
        removeKeyMonitor()

        let windowsToClose = windows
        windows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for window in windowsToClose {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            // NSAnimationContext completion runs on the main thread but isn't
            // annotated @MainActor; assert the isolation explicitly.
            MainActor.assumeIsolated {
                for window in windowsToClose {
                    window.orderOut(nil)
                }
            }
        })
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

        let root = BreakOverlayView(
            state: state,
            onSkip: { [weak self] in self?.onSkip() },
            onExtend: { [weak self] seconds in self?.onExtend(seconds) }
        )
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

    // MARK: - Key handling — double-press ESC to skip

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated {
                guard let self, self.isShowing else { return }
                let now = Date()
                if let last = self.lastEscapeAt, now.timeIntervalSince(last) < self.doubleEscapeWindow {
                    self.lastEscapeAt = nil
                    self.onSkip()
                } else {
                    self.lastEscapeAt = now
                }
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
    var title: String = ""
    var message: String = ""
    /// Presentation metadata for the currently-firing break. Defaults to
    /// eye-rest so the state object has a sensible value at construction.
    var content: BreakContent = .eyeRest
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
