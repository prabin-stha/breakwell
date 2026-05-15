import AppKit
import SwiftUI

/// Borderless floating card pinned to the top-center of the active screen.
/// Auto-dismisses after 30s if untouched. Persists across Space changes and
/// fullscreen apps so it doesn't get "lost" when you switch windows.
@MainActor
final class ProminentCardController {
    private var window: CardWindow?
    private var dismissTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    private let settings: Settings
    private let hydration: HydrationState
    private let autoDismissAfter: TimeInterval = 30

    init(settings: Settings, hydration: HydrationState) {
        self.settings = settings
        self.hydration = hydration
    }

    func show(content: ReminderContent) {
        dismiss()

        let win = CardWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        // Let NSWindow paint a native shadow that follows the rounded content.
        win.hasShadow = true
        win.level = .statusBar
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.hidesOnDeactivate = false
        win.animationBehavior = .none

        let view = ProminentCardView(
            content: content,
            hydration: hydration,
            onConfirm: { [weak self] in
                self?.hydration.recordDrink()
                self?.dismiss()
            },
            onSkip: { [weak self] in
                self?.dismiss()
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        win.contentView = hosting

        hosting.layout()
        let size = hosting.fittingSize
        win.setFrame(centeredFrame(size: size), display: false)

        win.orderFront(nil)
        self.window = win

        if settings.soundEnabled {
            NSSound(named: "Bottle")?.play()
        }

        installActivationObserver()

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
        removeActivationObserver()
        window?.orderOut(nil)
        window = nil
    }

    private func centeredFrame(size: NSSize) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: size)
        }
        let frame = screen.visibleFrame
        let x = frame.midX - size.width / 2
        let y = frame.midY - size.height / 2
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

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
}

/// NSPanel with `.nonactivatingPanel` style — clicks on its buttons fire
/// SwiftUI actions without bringing BreakWell to the foreground or stealing
/// keyboard focus from the user's current app.
private final class CardWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
