import SwiftUI
import AppKit

// MARK: - FloatingBannerView
//
// Purpose: SwiftUI content for the floating banner — header strip with
// icon + title + live timer, body copy, and a footer of action buttons.
//
// Architecture role: View layer for the floating banner UI. The
// presenter / App layer builds a `FloatingBannerState` and hands it to
// the controller, which embeds this view.
//
// Key types defined:
//   - HeadsUpMessage: prefix/emphasis/suffix body-copy struct
//   - FloatingBannerState: @Observable state passed to the view
//   - FloatingBannerView: the banner content
//   - PulsingDot, PrimaryPillButton, SnoozeGroupPill, SnoozeOptionButton:
//     subviews of the banner
//
// Used by:
//   - FloatingBannerController (constructs a FloatingBannerView from state)
//   - PreBreakNotifier (builds a FloatingBannerState for the pre-break heads-up)
//
// Swift / SwiftUI concepts a learner will see here:
//   - @Observable on a class used as view state: reading `state.timer`
//     inside the view body subscribes that view to timer changes.
//   - .contentTransition(.numericText()): smooth digit-by-digit transitions
//     for the countdown timer instead of crossfading the whole string.
//   - .overlay(alignment:): stacks a view over the parent with an alignment
//     anchor. Used for the close button at top-right.
//   - TimelineView(.animation): deterministic time-driven animations that
//     survive Space switches / app re-attach.

/// Body copy for the editorial pre-break heads-up. The phrase is broken
/// into three pieces so the view can render the `emphasis` portion in
/// italic + accent colour while the surrounding text stays in the normal
/// body style — single-string approaches would need attributed-string
/// parsing for the same effect, which is more machinery than it earns.
struct HeadsUpMessage: Sendable, Equatable {
    let prefix: String
    let emphasis: String
    let suffix: String

    /// Fallback used when no message is supplied to `FloatingBannerState`
    /// (or when the random pool is empty — defensive).
    static let defaultMessage = HeadsUpMessage(
        prefix: "The clock's almost up. Step ",
        emphasis: "away from the work",
        suffix: " — and meet it back here in a few minutes."
    )
}

/// Observable state shared between the controller and the SwiftUI view.
/// `timer` is the only mutating field — the caller writes a new string
/// on every tick to drive the live countdown, and the view re-renders
/// automatically via `@Observable`.
@MainActor
@Observable
final class FloatingBannerState {
    let title: String
    let actions: [Action]
    /// Short countdown text rendered top-right ("0:08"). Updated each tick
    /// by the caller. Carried separately from `title` because the layout
    /// uses `title` as a static section header ("A SMALL PAUSE") and
    /// this field for the dynamic timer.
    var timer: String
    /// Body copy. Picked once when the banner is created so the text
    /// doesn't shuffle mid-display — the user is reading it as the
    /// countdown ticks down.
    let bodyMessage: HeadsUpMessage

    struct Action: Identifiable {
        let id = UUID()
        let label: String
        let isPrimary: Bool
        let handler: @Sendable () -> Void
    }

    init(
        title: String,
        actions: [Action] = [],
        timer: String = "",
        bodyMessage: HeadsUpMessage = .defaultMessage
    ) {
        self.title = title
        self.actions = actions
        self.timer = timer
        self.bodyMessage = bodyMessage
    }
}

/// The actual view rendered inside the borderless floating window.
///
/// **Editorial layout** (experimental). The pre-break heads-up reads like
/// a small magazine card: cream paper background, serif typography, dashed
/// dividers between sections, italic accent phrase in the body, text-button
/// actions. Replaces the earlier "system notification" layout entirely.
///
/// Layout rows top → bottom:
///   1. Header strip — clock icon + "A SMALL PAUSE" (left); italic "starts
///      in 0:08" (right).
///   2. Dashed divider.
///   3. Body — large serif text with one italicized red phrase.
///   4. Dashed divider.
///   5. Footer strip — primary action (underlined red serif, left); secondary
///      action (italic muted serif, right).
struct FloatingBannerView: View {
    let state: FloatingBannerState
    let onDismiss: () -> Void

    // Single warm-peach accent carries the visual signature of the banner:
    // hourglass icon, timer pill, italic emphasis phrase, "Begin now"
    // pill, and the pill's soft glow. Kept bright enough to read against
    // the dark card background while staying within a friendly tone
    // (it's a "pause" prompt, not an alarm).
    private let accent = Color(red: 0.98, green: 0.62, blue: 0.45)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .padding(.vertical, 11)

            // Single hairline divider between header and body. The earlier
            // editorial layout had dashed dividers above AND below the body;
            // the new look uses one quiet line to separate header from
            // content, and lets the footer sit directly under the body
            // without a visual break (the footer's pill shapes provide their
            // own boundary).
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 1)

            bodyText
                .padding(.top, 16)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)

            footerRow
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 18)
        // Dark card. Two layers: a deep near-black tint over `.ultraThinMaterial`
        // so a hint of the desktop bleeds through at the edges without
        // washing out the body copy. Filling the shape directly (rather
        // than chaining `.background().clipShape(...)`) avoids the
        // rectangular-ghost artifact some macOS versions render at the
        // rounded corners.
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(red: 0.06, green: 0.07, blue: 0.10).opacity(0.78))
                )
        )
        // Subtle glass-rim highlight along the top edge — same trick as
        // the prior layout, kept because it still reads as "panel"
        // rather than "flat rectangle".
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.18),
                            .white.opacity(0.04)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
        )
        // Entrance animation is owned entirely by FloatingBannerController
        // (NSWindow alphaValue fade-in/out). We deliberately do NOT add a
        // SwiftUI `.onAppear`-driven slide here: when the banner's NSWindow
        // gets hidden + reshown on Space changes or app switches, AppKit
        // re-fires `onAppear` on the embedded SwiftUI hierarchy, which
        // would re-trigger any animation gated on view appearance. Keeping
        // the entrance at the window-alpha layer means Space switches just
        // re-show an already-built view at full alpha — no visual reset.
        .frame(width: 440, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
    }

    // MARK: - Header

    @ViewBuilder
    private var headerRow: some View {
        HStack(alignment: .center, spacing: 10) {
            // SF Symbol hourglass — bottom-half-filled variant gives the
            // two-tone look (outline frame + accent fill) without us
            // hand-drawing the shape.
            Image(systemName: "hourglass.bottomhalf.filled")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(accent)

            Text(state.title)
                .font(.system(size: 11, weight: .medium))
                .tracking(1.8)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.55))

            Spacer(minLength: 8)

            timerPill

            // Close X — replaces the old text "close" footer button.
            // Hangs in the top-right where macOS users expect a dismiss
            // affordance.
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// "Starts in 0:21" capsule with a small pulsing accent dot. The
    /// pulse reads as a "live / in-progress" indicator — heartbeat-style
    /// scale + opacity loop so it's noticeable without being distracting.
    private var timerPill: some View {
        HStack(spacing: 6) {
            PulsingDot(color: accent, size: 4)
            Text("Starts in \(state.timer)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(accent)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.default, value: state.timer)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(accent.opacity(0.10))
        )
        .overlay(
            Capsule()
                .strokeBorder(accent.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Body

    /// Three concatenated `Text` segments:
    ///   - prefix in plain serif (white-ish)
    ///   - emphasis in italic + warm accent
    ///   - suffix in plain serif
    /// Strings come from `state.bodyMessage`, picked once per banner
    /// appearance in PreBreakNotifier.
    private var bodyText: Text {
        let bodyFont = Font.system(size: 18, weight: .regular, design: .serif)
        let msg = state.bodyMessage
        return Text(msg.prefix)
            .font(bodyFont)
            .foregroundColor(.white.opacity(0.92))
        + Text(msg.emphasis)
            .font(bodyFont.italic())
            .foregroundColor(accent)
        + Text(msg.suffix)
            .font(bodyFont)
            .foregroundColor(.white.opacity(0.92))
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerRow: some View {
        HStack(spacing: 12) {
            if let primary = state.actions.first(where: { $0.isPrimary }) {
                PrimaryPillButton(label: primary.label, color: accent, action: primary.handler)
            }
            // Snooze group: a single bordered capsule grouping the three
            // time options under a quiet "SNOOZE" label. Reads as one
            // multi-option control rather than three loose buttons —
            // matches the conceptual model ("pick a duration") and saves
            // horizontal space vs spelled-out "snooze 5m" repeated thrice.
            SnoozeGroupPill(actions: state.actions.filter { !$0.isPrimary })
            Spacer()
        }
    }

}

// MARK: - Pulsing dot

/// Small filled circle that breathes — scales up and dims slightly, then
/// settles back. Used in the timer pill to signal "live countdown" at a
/// glance.
///
/// Time-driven via `TimelineView(.animation)` rather than the more typical
/// `withAnimation(...).repeatForever(...)` on `.onAppear`. The repeat-forever
/// pattern resets every time the embedding NSWindow gets hidden + reshown
/// (Space changes, app switches), causing a visible stutter. Computing the
/// scale/opacity from the wall clock makes the animation deterministic and
/// continuous across any view re-attach.
private struct PulsingDot: View {
    let color: Color
    let size: CGFloat
    /// Seconds per full pulse cycle (up + back down). 1.8s reads as a
    /// gentle heartbeat without being distracting.
    private let period: Double = 1.8

    var body: some View {
        // 30 fps is enough for a slow 1.8s breathing cycle — uncapped
        // `.animation` would tick at the display's native refresh (60 or
        // 120 fps on ProMotion) and recompute the sine + rebuild the
        // Circle view 2-4× more often than the eye can resolve at this
        // size. Capping here roughly halves the heads-up's CPU cost.
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            // Map time → [0, 1] via a sine wave so the motion eases in and
            // out at both ends rather than snapping. The +1)/2 lifts the
            // sine range from [-1, 1] into [0, 1].
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            let t = (sin(phase * 2 * .pi) + 1) / 2
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .scaleEffect(1.0 + 0.45 * t)
                .opacity(1.0 - 0.45 * t)
        }
    }
}

// MARK: - Footer button styles

/// Solid pill button for the primary action ("Begin now"). Filled with
/// the accent color, dark text on top, with a soft accent-colored glow
/// underneath so it lifts off the dark card.
private struct PrimaryPillButton: View {
    let label: String
    let color: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.85))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(color.opacity(hovering ? 1.0 : 0.92))
                )
                .shadow(color: color.opacity(hovering ? 0.55 : 0.40), radius: 11, x: 0, y: 0)
        }
        .buttonStyle(.plain)
        .onHover { value in
            hovering = value
            if value { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            if hovering { NSCursor.pop(); hovering = false }
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Bordered capsule containing a quiet "SNOOZE" caption and the three
/// time-option buttons. Strips a leading "+" from labels so callers can
/// keep using "+5m" / "+10m" / "+15m" without us pushing presentation
/// rules back into them.
private struct SnoozeGroupPill: View {
    let actions: [FloatingBannerState.Action]

    var body: some View {
        HStack(spacing: 2) {
            Text("SNOOZE")
                .font(.system(size: 10, weight: .medium))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.40))
                .padding(.trailing, 4)

            ForEach(actions) { action in
                SnoozeOptionButton(
                    label: action.label.hasPrefix("+") ? String(action.label.dropFirst()) : action.label,
                    action: action.handler
                )
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

/// Individual time-option button inside the snooze group. Subtle hover
/// background so the user gets click feedback even though the group
/// container does the heavy visual work.
private struct SnoozeOptionButton: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.white.opacity(hovering ? 1.0 : 0.82))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(hovering ? 0.08 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { value in
            hovering = value
            if value { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            if hovering { NSCursor.pop(); hovering = false }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

