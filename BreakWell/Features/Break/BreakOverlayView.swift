import SwiftUI
import AppKit

// MARK: - BreakOverlayView
//
// Purpose: SwiftUI content rendered inside the borderless overlay window.
// Reads from a shared `BreakOverlayState` so the controller can update
// values without rebuilding the view tree.
//
// Architecture role: Pure SwiftUI view layer. Owns visual presentation
// only — the controller above it owns AppKit window plumbing, and the
// presenter above THAT decides when to show/hide.
//
// Key types defined:
//   - BreakOverlayView: the main composed view
//   - OverlayCapsuleButton: pill-shaped button with hover/press states
//   - ClockIndicator: top-of-screen current-time readout
//   - AuroraBackground: animated blob-blur background
//
// Used by:
//   - BreakOverlayController (embeds inside an NSHostingView)
//
// Swift / SwiftUI concepts a learner will see here:
//   - @State: local view-state storage. Triggers re-renders when changed.
//   - @ViewBuilder: lets a property return multiple SwiftUI views without
//     wrapping them in a Group.
//   - .task { ... }: SwiftUI's "run an async function for the lifetime of
//     this view". Cancels automatically when the view goes away.
//   - TimelineView(.animation): a SwiftUI view that re-renders every
//     animation frame, exposing the current time. Used to drive the
//     aurora's smooth motion without a Timer.
//   - GeometryReader: gives the closure body the size of the parent so we
//     can lay out children proportionally.
//   - .contentTransition(.numericText()): animates digit changes by
//     sliding them, rather than fading. Matches Apple's Lock Screen clock.

/// The fullscreen content shown during a break. Aurora background,
/// rotating message, countdown, and a row of capsule buttons.
///
/// State flows in via `BreakOverlayState`. We don't own the state ourselves
/// because the controller needs to mutate it on every tick (for
/// `remaining`) — sharing by reference avoids passing updates through the
/// SwiftUI tree manually.
struct BreakOverlayView: View {
    let state: BreakOverlayState
    let onSkip: () -> Void
    /// Argument is seconds. Caller dismisses the break and reschedules the
    /// next firing N seconds from now (not "current scheduled time + N").
    let onSnooze: (TimeInterval) -> Void

    @State private var visible = false

    var body: some View {
        ZStack {
            AuroraBackground()
            // Subtle dark layer over the aurora for text legibility.
            Color.black.opacity(0.15).ignoresSafeArea()

            VStack(spacing: 0) {
                // Padded below the menu bar / notch area so it's visible
                // on notched MacBooks where our screen-saver-level overlay
                // sits beneath the notch.
                ClockIndicator()
                    .padding(.top, 56)

                Spacer()

                VStack(spacing: 18) {
                    Text(state.title)
                        .font(.system(size: 60, weight: .regular, design: .serif))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.95))
                        .shadow(color: .black.opacity(0.25), radius: 12, y: 2)
                        .padding(.horizontal, 80)

                    Text(state.message)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 80)
                }

                Spacer().frame(height: 80)

                Text(timeString)
                    .font(.system(size: 110, weight: .ultraLight, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .monospacedDigit()
                    // Animates each digit changing rather than crossfading
                    // the whole text. Lock-Screen-style countdown feel.
                    .contentTransition(.numericText())
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 4)

                Spacer()

                bottomControls
                    .padding(.bottom, 32)
            }
        }
        .opacity(visible ? 1 : 0)
        // Implicit animation tied to `state.remaining` — drives the digit
        // transition above without a separate withAnimation call.
        .animation(.default, value: state.remaining)
        .onAppear {
            // Fade in once the window is on screen.
            withAnimation(.easeOut(duration: 0.55)) {
                visible = true
            }
        }
    }

    @ViewBuilder
    private var bottomControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 22) {
                OverlayCapsuleButton(label: "Skip break", prominent: true) {
                    onSkip()
                }
                // Snooze is a single text-styled action, not a capsule —
                // visual weight matches "Skip" being the primary choice
                // and snooze being the lighter alternative.
                SnoozeTextButton(label: "+ 5 min · snooze") {
                    onSnooze(300)
                }
            }

            HStack(spacing: 6) {
                Text("Press")
                EscKeyCap()
                Text("twice to skip")
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.45))
        }
    }

    /// "0:20" / "1:05" style. Round up so the user never sees "0:00" while
    /// the actual seconds-remaining is, say, 0.4.
    private var timeString: String {
        let total = max(0, Int(state.remaining.rounded(.up)))
        let m = total / 60
        let s = total % 60
        return "\(m):\(String(format: "%02d", s))"
    }
}

// MARK: - Text-styled snooze button

/// Lighter sibling of `OverlayCapsuleButton` — no capsule, no border, just
/// text that brightens on hover. Used for the snooze action so its visual
/// weight reads as "secondary option" next to the prominent Skip button.
private struct SnoozeTextButton: View {
    let label: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.7))
        }
        .buttonStyle(.plain)
        .onHover { value in
            hovering = value
            if value {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            // Defensive cursor cleanup — if the view disappears mid-hover
            // (e.g. after the snooze fires), pop the hand cursor so it
            // doesn't stay stuck on the user's screen.
            if hovering {
                NSCursor.pop()
                hovering = false
            }
        }
        .animation(.smooth(duration: 0.15), value: hovering)
    }
}

// MARK: - Esc keycap

/// Renders "Esc" as a small keycap-style pill, used inside the helper text
/// to make "Press Esc twice to skip" read like a keyboard hint rather than
/// a sentence. Pure visual; no interactivity.
private struct EscKeyCap: View {
    var body: some View {
        Text("Esc")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(.white.opacity(0.18), lineWidth: 0.5)
            )
    }
}

// MARK: - Pill button with hover effect

/// Capsule-shaped button that brightens / scales on hover and shrinks on
/// press. Replaces the default SwiftUI Button styling so the overlay's
/// visual language stays consistent across all four buttons.
private struct OverlayCapsuleButton: View {
    let label: String
    var prominent: Bool = false
    let action: () -> Void

    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.white.opacity(hovering ? 0.98 : 0.78))
                .padding(.horizontal, prominent ? 16 : 14)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(.white.opacity(hovering ? 0.10 : 0.0))
                )
                .overlay(
                    Capsule().stroke(
                        .white.opacity(hovering ? 0.55 : (prominent ? 0.32 : 0.18)),
                        lineWidth: 1
                    )
                )
                .scaleEffect(pressed ? 0.96 : (hovering ? 1.04 : 1.0))
        }
        .buttonStyle(.plain)
        .onHover { value in
            hovering = value
            applyCursor(hovering: value)
        }
        // SwiftUI's Button doesn't expose press-state to the body, so we
        // attach a zero-duration long-press gesture purely to read the
        // pressing flag. The actual action still fires via Button.
        .onLongPressGesture(minimumDuration: 0, perform: {}, onPressingChanged: { isPressing in
            pressed = isPressing
        })
        .onDisappear {
            // Defensive: if the view goes away while we have the cursor
            // pushed, we'd leave the hand cursor stuck on the screen.
            if hovering {
                NSCursor.pop()
                hovering = false
            }
        }
        .animation(.smooth(duration: 0.18), value: hovering)
        .animation(.smooth(duration: 0.10), value: pressed)
    }

    /// Switch the cursor to the hand pointer while hovering. NSCursor uses
    /// a push/pop stack — we push when hover starts, pop when it ends.
    private func applyCursor(hovering: Bool) {
        if hovering {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }
}

// MARK: - Time at the top

/// Small "10:30 AM" readout at the top of the overlay. Refreshed every
/// five seconds — minute-resolution display doesn't need anything tighter.
private struct ClockIndicator: View {
    @State private var now = Date()

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    var body: some View {
        Text(formatter.string(from: now))
            .font(.system(size: 13, weight: .regular))
            .tracking(2.0)
            .foregroundStyle(.white.opacity(0.65))
            // `.task` runs the body as an async task for the lifetime of
            // the view; cancelled automatically when the view disappears.
            .task {
                while !Task.isCancelled {
                    now = Date()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
    }
}

// MARK: - Aurora background

/// Animated blob-based aurora background. Four large blurred ovals drift in
/// orbits driven by `sin` / `cos` of a global time. The visual goal is a
/// calm, slowly-shifting glow — never stop, never repeat exactly.
///
/// Uses `TimelineView(.animation)` rather than a Timer because it gives us
/// frame-accurate time-driven updates without spinning a separate clock.
struct AuroraBackground: View {
    var body: some View {
        // 30 fps cap on the redraw cadence. Aurora motion is slow; we
        // don't need 60+ fps. minimumInterval avoids wasting energy.
        TimelineView(.animation(minimumInterval: 1.0/30, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                ZStack {
                    // Deep warm-cocoa base. Earlier versions used a near-
                    // black plum; that combined with saturated red/magenta
                    // blobs gave the overlay a "warning" tone. Cocoa keeps
                    // the screen calm + warm.
                    Color(red: 0.08, green: 0.06, blue: 0.05)

                    // Soft sage — calm, restful, "step outside" energy.
                    blob(Color(red: 0.30, green: 0.55, blue: 0.42),
                         baseX: 0.22, baseY: 0.30,
                         phase: t * 0.10, ampX: 0.10, ampY: 0.08,
                         scale: 1.4, opacity: 0.50, size: geo.size)

                    // Warm honey — the only "alert-ish" hue, kept gentle.
                    blob(Color(red: 0.78, green: 0.55, blue: 0.22),
                         baseX: 0.82, baseY: 0.38,
                         phase: t * 0.08 + 1.0, ampX: 0.10, ampY: 0.10,
                         scale: 1.3, opacity: 0.48, size: geo.size)

                    // Coffee-cream peach — the "cup of tea" mid-tone.
                    blob(Color(red: 0.78, green: 0.50, blue: 0.36),
                         baseX: 0.45, baseY: 0.75,
                         phase: t * 0.09 + 2.5, ampX: 0.14, ampY: 0.10,
                         scale: 1.5, opacity: 0.52, size: geo.size)

                    // Deep teal — anchors the palette so it doesn't drift
                    // entirely warm and feel like a sunset (which can read
                    // as "end of day / urgency").
                    blob(Color(red: 0.18, green: 0.36, blue: 0.40),
                         baseX: 0.68, baseY: 0.70,
                         phase: t * 0.07 + 4.0, ampX: 0.10, ampY: 0.12,
                         scale: 1.2, opacity: 0.45, size: geo.size)
                }
            }
            .ignoresSafeArea()
        }
    }

    /// One blob — large blurred circle at a slowly-orbiting position.
    /// `baseX`/`baseY` is the centre of the orbit; `ampX`/`ampY` is its
    /// radius. The blur is what makes them read as aurora rather than balls.
    @ViewBuilder
    private func blob(
        _ color: Color,
        baseX: CGFloat,
        baseY: CGFloat,
        phase: Double,
        ampX: CGFloat,
        ampY: CGFloat,
        scale: CGFloat,
        opacity: Double,
        size: CGSize
    ) -> some View {
        let dim = min(size.width, size.height) * scale * 0.55
        let x = size.width * (baseX + ampX * CGFloat(sin(phase)))
        let y = size.height * (baseY + ampY * CGFloat(cos(phase * 1.3)))

        Circle()
            .fill(color)
            .frame(width: dim, height: dim)
            .opacity(opacity)
            .blur(radius: 120)
            .position(x: x, y: y)
    }
}
