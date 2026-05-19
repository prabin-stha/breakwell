import AppKit
import SwiftUI

// MARK: - SnoozeIndicatorController
//
// Purpose: Owns the small floating circular button that appears in the
// top-right of the cursor's current screen whenever a break is snoozed.
// Click → take the snoozed break immediately. Right-click → AppKit
// contextual menu (Take now / Cancel snooze).
//
// Architecture role: AppKit `NSWindowController`-style class — owns a
// borderless `NSPanel`, follows the cursor's screen with a 1-second poll,
// embeds a SwiftUI content view via `NSHostingView`. Sibling of
// `FloatingBannerController` and `ProminentCardController`.
//
// Key types defined:
//   - SnoozeIndicatorController: @MainActor class owning the panel
//   - IndicatorPanel: NSPanel subclass that disables key/main status
//   - IndicatorHostView: NSView subclass that catches right-click to
//     present an NSMenu (SwiftUI's `.contextMenu` is unreliable inside
//     a nonactivating panel, so we use AppKit's native menu here)
//   - SnoozeIndicatorView: the SwiftUI button face
//
// Used by:
//   - BreakWellApp (constructs, subscribes to coordinator's snooze stream
//     and calls show/dismiss as the list changes)
//
// AppKit + SwiftUI concepts a learner will see here:
//   - .nonactivatingPanel + canBecomeKey = false: clicks fire actions
//     without forcing BreakWell to become frontmost.
//   - rightMouseDown override on a host view: SwiftUI's contextMenu
//     attaches to its view but doesn't reliably reach into nonactivating
//     panels. Overriding the AppKit event hook is the robust approach.
//   - Timer-based cursor screen tracking: `NSEvent.mouseLocation` plus
//     `NSScreen.screens.first(where: contains)` to follow the cursor as
//     it moves between monitors. 1-second poll — not a hot path.

/// Closure types kept short so the property declarations + capture lists
/// don't sprawl.
typealias SnoozeIndicatorAction = @MainActor () -> Void

@MainActor
final class SnoozeIndicatorController {
    private var window: IndicatorPanel?
    private var activationObserver: NSObjectProtocol?
    private var cursorPollTimer: Timer?
    /// `true` while a fade-out is mid-flight. If `actuallyShow` is called
    /// during the fade (e.g. heads-up dismisses just as we'd hide), we
    /// flip this off so the completion handler's teardown is a no-op
    /// and the window stays alive for the new fade-in.
    private var pendingTeardown: Bool = false

    // Three independent signals combine to decide whether the panel is on
    // screen:
    //   - `pendingReminder`: intent — there is a snoozed break waiting.
    //   - `headsUpOccluded`: the pre-break heads-up is on screen, so we
    //     hide to avoid two stacked "break is pending" surfaces.
    //   - `suppressionActive`: the user is in a Slack/Zoom-style window
    //     where breaks are suppressed; the indicator shouldn't surface
    //     itself during a meeting/call. Reappears when suppression clears.
    //
    // The panel renders iff `pendingReminder != nil && !any occlusion`.
    // Splitting the two occlusion sources (rather than a single `occluded`
    // bool) means heads-up dismissing during suppression doesn't
    // accidentally reveal the indicator.
    private var pendingReminder: SnoozedReminder?
    private var headsUpOccluded: Bool = false
    private var suppressionActive: Bool = false
    /// True while the break overlay is firing (or deferred waiting to
    /// fire). The overlay itself is at `.screenSaver` window level so it
    /// renders above the indicator's `.floating` panel, BUT the overlay's
    /// SwiftUI content fades in over ~0.55s — during that fade the
    /// indicator would otherwise show through. We instant-hide here so
    /// nothing is left to show through.
    private var breakActive: Bool = false

    /// The trackID closures call back with. Read by `takeAction` and
    /// `cancelAction` when the user clicks the indicator or its menu.
    var currentTrackID: String? { pendingReminder?.trackId }

    private let onTake: (String) -> Void
    private let onCancel: (String) -> Void

    /// Window dimensions. Larger than the 54pt visible circle so the
    /// hover scale-up (1.06×) doesn't push rendered pixels past the
    /// window's edge, where AppKit clips them.
    private let windowWidth: CGFloat = 64
    private let windowHeight: CGFloat = 64
    /// Inset from the top-right corner of the cursor's screen.
    private let edgeInset: CGFloat = 14
    /// How often we re-check which screen the cursor is on. 1 sec is
    /// plenty — the indicator doesn't need frame-rate accuracy here.
    private let cursorPollInterval: TimeInterval = 1.0

    init(
        onTake: @escaping (String) -> Void,
        onCancel: @escaping (String) -> Void
    ) {
        self.onTake = onTake
        self.onCancel = onCancel
    }

    /// Register intent to show the indicator for the given reminder.
    /// The reminder's `snoozedAt` and `nextFireAt` drive the progress
    /// ring. Whether the panel actually appears depends on the current
    /// `occluded` state — if another UI (e.g. the heads-up) is visible
    /// the indicator stays hidden until that clears.
    ///
    /// Idempotent: re-calling with the same reminder is a no-op for the
    /// window (which is identified by being-or-not-being present); the
    /// progress ring keeps animating from the same `snoozedAt`.
    func show(reminder: SnoozedReminder) {
        // If a different reminder swaps in (rare — re-snooze), the
        // SwiftUI view's identity changes via its host re-render. We
        // tear down and rebuild the window so the new timing kicks in
        // immediately.
        let needsRebuild = pendingReminder.map { $0 != reminder } ?? false
        pendingReminder = reminder
        // Re-snooze swap: tear down synchronously so `actuallyShow` builds
        // a fresh window with the new reminder's timing. An animated fade
        // here would leave the old SwiftUI rootView visible (the rebuild
        // path would see `window != nil` and just reverse the fade).
        if needsRebuild { tearDownWindowImmediately() }
        applyVisibility()
    }

    /// Clear the intent. Indicator goes away if currently visible.
    func dismiss() {
        pendingReminder = nil
        applyVisibility()
    }

    /// Hide the indicator while the pre-break heads-up banner is visible.
    /// Two "break is pending" surfaces at once is noisy. Setting back to
    /// `false` re-shows the indicator (subject to other occlusion flags).
    func setHeadsUpVisible(_ value: Bool) {
        guard value != headsUpOccluded else { return }
        headsUpOccluded = value
        applyVisibility()
    }

    /// Hide the indicator while suppression is active (user is in a
    /// Slack/Zoom-style window where breaks are suppressed). The snooze
    /// state in the coordinator is unchanged — the indicator just doesn't
    /// surface during the meeting/call, and reappears when suppression
    /// clears.
    func setSuppressionActive(_ value: Bool) {
        guard value != suppressionActive else { return }
        suppressionActive = value
        applyVisibility()
    }

    /// Hide the indicator while the break overlay is firing/deferred.
    /// When toggling to `true`, the panel is torn down without the usual
    /// fade-out — the overlay's own fade-in would otherwise show the
    /// indicator briefly through its semi-transparent content.
    func setBreakActive(_ value: Bool) {
        guard value != breakActive else { return }
        breakActive = value
        if value {
            // Skip fade: rip the window down right now.
            tearDownWindowImmediately()
        } else {
            applyVisibility()
        }
    }

    /// Reconcile the panel's rendered state with the current intent +
    /// occlusion flags. Called from every state-mutating entry point.
    private func applyVisibility() {
        let shouldShow = pendingReminder != nil
            && !headsUpOccluded
            && !suppressionActive
            && !breakActive
        if shouldShow {
            actuallyShow()
        } else {
            actuallyHide()
        }
    }

    private func actuallyShow() {
        guard let reminder = pendingReminder else { return }
        // If a fade-out was in flight, cancel its teardown — the window
        // is still alive and we just want to reverse the animation back
        // to fully opaque.
        if window != nil {
            if pendingTeardown {
                pendingTeardown = false
                if let panel = window {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.20
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        panel.animator().alphaValue = 1
                    }
                }
            }
            repositionToCursorScreen()
            return
        }

        let panel = IndicatorPanel(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            // `.nonactivatingPanel` is the key bit: clicking the indicator
            // fires its action without yanking focus from whatever app the
            // user was working in.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // NSWindow's built-in shadow renders a soft dark ring around the
        // opaque content, which on a small colored circle reads as a
        // black border. The SwiftUI content provides its own visual
        // weight (gradient fill + bright progress ring), so we skip the
        // system shadow entirely.
        panel.hasShadow = false
        // `.floating` puts the indicator above normal windows but below
        // the break overlay (which uses `.screenSaver`).
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        // Build the SwiftUI view, embed inside our custom host that
        // catches right-click.
        let swiftUIView = SnoozeIndicatorView(
            snoozedAt: reminder.snoozedAt,
            nextFireAt: reminder.nextFireAt,
            onTap: { [weak self] in self?.takeAction() }
        )
        let hosting = NSHostingView(rootView: swiftUIView)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        let container = IndicatorHostView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        container.onRightClick = { [weak self] event in
            self?.presentContextMenu(at: event)
        }
        container.addSubview(hosting)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        panel.contentView = container

        repositionToCursorScreen(panel: panel)
        // Start fully transparent, then fade in via the animator proxy.
        // Setting alpha before orderFront avoids a one-frame opaque flash.
        panel.alphaValue = 0
        panel.orderFront(nil)
        self.window = panel

        installActivationObserver()
        startCursorPolling()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// Synchronous teardown — used by the re-snooze rebuild path where
    /// fading the old window would leave the previous SwiftUI content on
    /// screen until the new one fades in over the top.
    private func tearDownWindowImmediately() {
        stopCursorPolling()
        removeActivationObserver()
        pendingTeardown = false
        window?.orderOut(nil)
        window = nil
    }

    private func actuallyHide() {
        guard let panel = window else { return }
        // Tear down side effects up front — we don't want the cursor
        // poll to keep reframing a fading-out window, and a stale
        // activation observer could re-front during the fade.
        stopCursorPolling()
        removeActivationObserver()
        pendingTeardown = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // The completion runs on the main thread, but it isn't
            // statically @MainActor — hop back explicitly. If a re-show
            // happened during the fade, `pendingTeardown` is already false
            // and we leave the window in place.
            Task { @MainActor [weak self] in
                guard let self, self.pendingTeardown else { return }
                self.pendingTeardown = false
                panel.orderOut(nil)
                self.window = nil
            }
        })
    }

    // MARK: - Actions

    private func takeAction() {
        guard let id = currentTrackID else { return }
        onTake(id)
    }

    private func cancelAction() {
        guard let id = currentTrackID else { return }
        onCancel(id)
    }

    /// Show the context menu at the right-click location. NSMenu's
    /// `popUp(positioning:at:in:)` handles all the placement + dismissal
    /// behaviors a native macOS context menu has.
    private func presentContextMenu(at event: NSEvent) {
        guard let window else { return }

        let menu = NSMenu()
        let takeItem = NSMenuItem(
            title: "Take break now",
            action: #selector(IndicatorActionForwarder.takeNow(_:)),
            keyEquivalent: ""
        )
        let cancelItem = NSMenuItem(
            title: "Cancel snooze",
            action: #selector(IndicatorActionForwarder.cancel(_:)),
            keyEquivalent: ""
        )

        // NSMenuItem's target must be an NSObject. Wrap our closures in
        // a small Objective-C–compatible forwarder so the menu can call
        // back into our action closures. NSMenuItem.target is `weak`,
        // but `NSMenu.popUp(...)` is synchronous — the local `forwarder`
        // reference on this stack frame keeps the object alive for the
        // menu's lifetime, so no extra retention is needed.
        let forwarder = IndicatorActionForwarder(
            onTake: { [weak self] in self?.takeAction() },
            onCancel: { [weak self] in self?.cancelAction() }
        )
        takeItem.target = forwarder
        cancelItem.target = forwarder
        menu.items = [takeItem, cancelItem]

        if let contentView = window.contentView {
            menu.popUp(positioning: nil, at: event.locationInWindow, in: contentView)
        }
        // `forwarder` is referenced after popUp returns to make sure the
        // compiler keeps it on the stack across the (synchronous) call.
        _ = forwarder
    }

    // MARK: - Cursor screen tracking

    private func startCursorPolling() {
        cursorPollTimer?.invalidate()
        cursorPollTimer = Timer.scheduledTimer(
            withTimeInterval: cursorPollInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repositionToCursorScreen()
            }
        }
    }

    private func stopCursorPolling() {
        cursorPollTimer?.invalidate()
        cursorPollTimer = nil
    }

    private func repositionToCursorScreen(panel: IndicatorPanel? = nil) {
        let target = panel ?? window
        guard let target else { return }

        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) })
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let newFrame = NSRect(
            x: visible.maxX - windowWidth - edgeInset,
            y: visible.maxY - windowHeight - edgeInset,
            width: windowWidth,
            height: windowHeight
        )

        // Only update if the frame actually changed — saves CPU and
        // avoids redraw jitter.
        if target.frame != newFrame {
            target.setFrame(newFrame, display: true)
        }
    }

    // MARK: - Re-assert front on app activation

    /// Some focus changes can briefly drop a `.floating`-level window
    /// behind another app's frontmost window. Listening for "any app
    /// activated" and ordering ourselves front again keeps the indicator
    /// visible.
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

// MARK: - NSPanel subclass

/// Private NSPanel that disables key/main status — even with
/// `.nonactivatingPanel`, a panel can still try to become key on click,
/// which would steal keyboard focus from the user's current app.
private final class IndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Host view with right-click

/// AppKit container view that catches right-click events. SwiftUI's
/// `.contextMenu` is unreliable inside nonactivating panels, so we hook
/// the underlying `rightMouseDown(with:)` event and let the controller
/// present a real `NSMenu` from it.
private final class IndicatorHostView: NSView {
    var onRightClick: ((NSEvent) -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }
}

// MARK: - Menu-item action forwarder

/// NSMenuItem's `target` has to be an Objective-C–compatible object, but
/// we want Swift closures. This tiny `NSObject` adapter bridges the two —
/// it owns the closures and the menu items point their selectors at it.
private final class IndicatorActionForwarder: NSObject {
    private let onTakeClosure: () -> Void
    private let onCancelClosure: () -> Void

    init(onTake: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onTakeClosure = onTake
        self.onCancelClosure = onCancel
    }

    @objc func takeNow(_ sender: Any?) { onTakeClosure() }
    @objc func cancel(_ sender: Any?) { onCancelClosure() }
}

// MARK: - SwiftUI face

/// The visible badge — a small stopwatch dial with a circular progress
/// ring at the bezel.
///
/// Visual layering (back to front):
///   1. Track ring at the outer edge — dark, low opacity, the "groove"
///   2. Progress arc on top of the track — bright orange-amber, fills as
///      the snooze window elapses
///   3. Cream dial (gradient, subtly darker at bottom-right)
///   4. Dark brown tick marks (the clock face markings)
///   5. Clay-red rotating hand + matching pivot pin (the "second hand")
///
/// The cream face is the anchor of the design: it lets each other
/// element be a distinct color so the parts read separately. A previous
/// all-amber palette blended every layer into the same wash, and the
/// progress arc was invisible against the dial.
///
/// Click to take the break; right-click is handled by `IndicatorHostView`.
private struct SnoozeIndicatorView: View {
    /// When the snooze was created. Combined with `nextFireAt` to compute
    /// how much of the snooze window has elapsed.
    let snoozedAt: Date
    /// When the break will fire again. Progress reaches 1.0 here.
    let nextFireAt: Date
    let onTap: () -> Void

    @State private var hovering = false

    // Stopwatch palette — built around a cream dial so each element
    // can be a distinct color and read at small size. Previous all-amber
    // palette blended every layer into the same warm wash.
    private let progressColor  = Color(red: 0.96, green: 0.52, blue: 0.18)  // bright orange-amber for the meter
    private let dialTop        = Color(red: 0.98, green: 0.94, blue: 0.86)  // light cream (face top)
    private let dialBottom     = Color(red: 0.92, green: 0.86, blue: 0.76)  // softer cream (face bottom, gives subtle depth)
    private let tickColor      = Color(red: 0.28, green: 0.18, blue: 0.10)  // dark warm brown ticks
    private let handColor      = Color(red: 0.82, green: 0.30, blue: 0.20)  // clay-red second hand
    private let trackColor     = Color(red: 0.28, green: 0.18, blue: 0.10)  // dark, used at low opacity for the progress-ring groove

    private let containerSize: CGFloat = 54
    /// Sized so the dial's outer edge meets the progress ring's inner
    /// edge with no gap. `strokeBorder(lineWidth: ringStroke)` paints
    /// inside the container's outer radius, occupying the outer
    /// `ringStroke` points of the disc — so the dial fits in the
    /// remaining circle: `containerSize - 2 * ringStroke`.
    private let clockSize: CGFloat = 48
    private let ringStroke: CGFloat = 3

    var body: some View {
        // Outer container fills the NSHostingView bounds; the indicator
        // is centered inside it. Without this wrapper, NSHostingView
        // would anchor the smaller content at top-left and the hover
        // scale would push pixels past the window's edge.
        ZStack {
            // `TimelineView` ticks at the chosen cadence so the progress
            // ring visibly moves. 0.5 sec is twice the visual update
            // rate the eye can resolve at this size — smooth enough
            // without burning frames.
            TimelineView(.periodic(from: snoozedAt, by: 0.5)) { context in
                let progress = computeProgress(now: context.date)

                ZStack {
                    // Track ring — dark at low opacity. The dark groove
                    // against the amber progress arc reads clearly on
                    // the cream dial below.
                    Circle()
                        .strokeBorder(trackColor.opacity(0.18), lineWidth: ringStroke)

                    // Filled progress arc. `trim` from 0 → progress,
                    // rotated -90° so it starts at 12 o'clock.
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            progressColor,
                            style: StrokeStyle(lineWidth: ringStroke, lineCap: .round)
                        )
                        // Match `strokeBorder`'s inset so the two rings
                        // align on the same arc.
                        .padding(ringStroke / 2)
                        .rotationEffect(.degrees(-90))
                        // Smooth between the discrete TimelineView updates
                        // so the fill flows continuously between ticks.
                        .animation(.linear(duration: 0.5), value: progress)

                    // Cream stopwatch dial — sized to meet the ring's
                    // inner edge with no gap (see `clockSize`). Dark
                    // ticks + clay-red hand give the face proper contrast
                    // against the cream.
                    StopwatchDial(
                        referenceDate: snoozedAt,
                        dialTop: dialTop,
                        dialBottom: dialBottom,
                        tickColor: tickColor,
                        handColor: handColor,
                        size: clockSize
                    )
                }
            }
            .frame(width: containerSize, height: containerSize)
            .scaleEffect(hovering ? 1.06 : 1.0)
            .contentShape(Circle())
            .onTapGesture(perform: onTap)
            .onHover { value in
                hovering = value
                if value {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if hovering {
                    NSCursor.pop()
                    hovering = false
                }
            }
            .animation(.smooth(duration: 0.18), value: hovering)
            .help("Break pending — click to take now")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Fraction of the snooze window that has elapsed, clamped to [0, 1].
    /// Returns 1.0 immediately if the window has zero or negative span
    /// (defensive — e.g. nextFireAt == snoozedAt would mean "no postpone";
    /// in that case we just show a full ring).
    private func computeProgress(now: Date) -> Double {
        let total = nextFireAt.timeIntervalSince(snoozedAt)
        guard total > 0.001 else { return 1.0 }
        let elapsed = now.timeIntervalSince(snoozedAt)
        return max(0, min(1, elapsed / total))
    }
}

/// Stopwatch dial: a cream-filled circle with dark tick marks around the
/// edge and a brightly-colored rotating hand. Each visible element gets
/// its own parameter so callers can tune the palette without forking the
/// shape logic — the snooze indicator's current colors pair a cream dial
/// with a clay-red hand for a classic stopwatch read.
///
/// Local to this file because the snooze indicator is the only thing
/// that uses it; lift to a shared file if another surface adopts it.
private struct StopwatchDial: View {
    /// Anchor for the hand's rotation. The hand's angle is computed as a
    /// deterministic function of `(now - referenceDate)`, so it survives
    /// any SwiftUI re-render — Space switches and app-activation cycles
    /// no longer reset the hand to 0°.
    let referenceDate: Date
    let dialTop: Color
    let dialBottom: Color
    let tickColor: Color
    let handColor: Color
    let size: CGFloat

    private let tickInterval: TimeInterval = 1
    private let degreesPerTick: Double = 30

    var body: some View {
        // `.periodic` ticks once per second from the reference; each tick
        // re-evaluates the body with a fresh `context.date`. We compute
        // the hand's angle from that date (not from a self-incrementing
        // @State counter) so re-attaching the view doesn't restart the
        // rotation. `.animation(_:value:)` on the rotation effect lets
        // SwiftUI spring between the discrete per-second positions.
        TimelineView(.periodic(from: referenceDate, by: tickInterval)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(referenceDate))
            let angle = floor(elapsed / tickInterval) * degreesPerTick
            ZStack {
                // Subtle top-light-to-bottom-darker gradient gives the flat
                // cream face a hint of dimension — like light falling on a
                // real dial.
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [dialTop, dialBottom],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                tickMarks
                clockHand(angle: angle)

                // Tiny pivot pin at the center where the hand attaches —
                // gives the hand a believable anchor instead of floating in
                // space. Same color as the hand so they read as one piece.
                Circle()
                    .fill(handColor)
                    .frame(width: size * 0.10, height: size * 0.10)
            }
            .frame(width: size, height: size)
            .animation(.spring(duration: 0.55, bounce: 0.35), value: angle)
        }
    }

    /// 12 tick marks around the inside of the dial; majors every 3
    /// (12/3/6/9) are taller and bolder. Pixel floors keep them visible
    /// at small dial sizes where the proportional values would round
    /// below 1pt.
    private var tickMarks: some View {
        let r = size * 0.40
        let majorH = max(2.0, size * 0.10)
        let minorH = max(1.5, size * 0.07)
        return ForEach(0..<12, id: \.self) { i in
            Capsule()
                .fill(tickColor.opacity(i % 3 == 0 ? 0.95 : 0.5))
                .frame(width: i % 3 == 0 ? 1.6 : 1.2,
                       height: i % 3 == 0 ? majorH : minorH)
                .offset(y: -r)
                .rotationEffect(.degrees(Double(i) * 30))
        }
    }

    /// Rotating hand — a thin capsule pivoting from the dial center.
    /// Caller picks the color (typically a saturated accent like clay-red
    /// for a "stopwatch second hand" read).
    private func clockHand(angle: Double) -> some View {
        Capsule()
            .fill(handColor)
            .frame(width: max(1.5, size * 0.04), height: size * 0.36)
            .offset(y: -size * 0.18)
            .rotationEffect(.degrees(angle))
    }
}
