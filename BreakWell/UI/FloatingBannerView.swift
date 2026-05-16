import SwiftUI
import AppKit

// MARK: - FloatingBannerView
//
// Purpose: SwiftUI content for the floating banner — icon, title, body,
// action buttons, and a small close X. Sized per a `BannerProminence` tier
// (`standard` for water-style banners, `prominent` for the pre-break heads-up).
//
// Architecture role: View layer for the floating banner UI. Lives in
// Features/Hydration alongside its controller. The presenter / App layer
// builds a `FloatingBannerState` and hands it to the controller, which
// embeds this view.
//
// Key types defined:
//   - BannerIcon: enum describing how to render the left badge
//   - BannerProminence: standard vs prominent size tier
//   - FloatingBannerState: @Observable state passed to the view
//   - BannerSizing: a value-type lookup table mapping prominence → numbers
//   - FloatingBannerView: the actual view
//   - BannerActionButton, BannerCloseButton, AnimatedClockIcon: subviews
//   - Color.darkened(by:): helper extension for the primary button hue
//
// Used by:
//   - FloatingBannerController (constructs a FloatingBannerView from state)
//   - PreBreakNotifier (builds a FloatingBannerState with .clock icon)
//   - presentHandler closure (builds a state with .symbol icon for water)
//
// Swift / SwiftUI concepts a learner will see here:
//   - @Observable on a class used as view state: reading `state.title`
//     inside the view body subscribes that view to title changes.
//   - .contentTransition(.numericText()): smooth digit-by-digit transitions
//     for the countdown timer instead of crossfading the whole string.
//   - `if let bodyText = state.body`: SwiftUI lets you use `if let` inside
//     a view builder; the conditional rendering "just works".
//   - .overlay(alignment:): stacks a view over the parent with an alignment
//     anchor. Used for the top-right close button.
//   - `NSColor(self).usingColorSpace(.sRGB)`: the canonical way to extract
//     color components from a SwiftUI Color on macOS.

/// The icon shown on the left of the floating banner.
enum BannerIcon: Sendable {
    case symbol(name: String, color: Color)
    /// Animated analog-clock icon used by the pre-break heads-up.
    case clock(color: Color)
}

/// Size + emphasis tier for a banner. The pre-break heads-up uses
/// `.prominent`; background reminders like water use `.standard`.
enum BannerProminence: Sendable {
    case standard
    case prominent
}

/// Observable state shared between the controller and the SwiftUI view.
/// Mutating `title` or `actions` re-renders the view automatically.
///
/// `accentColor` is sourced from the icon — used to tint the primary
/// action button so the visual chain (icon → primary button) stays
/// coherent without an extra parameter.
@MainActor
@Observable
final class FloatingBannerState {
    var title: String
    var body: String?
    let icon: BannerIcon
    let prominence: BannerProminence
    var actions: [Action]

    struct Action: Identifiable {
        let id = UUID()
        let label: String
        let isPrimary: Bool
        let handler: @Sendable () -> Void
    }

    init(
        title: String,
        body: String? = nil,
        icon: BannerIcon,
        prominence: BannerProminence = .standard,
        actions: [Action] = []
    ) {
        self.title = title
        self.body = body
        self.icon = icon
        self.prominence = prominence
        self.actions = actions
    }

    /// Accent color sourced from the icon — used to tint primary action buttons.
    var accentColor: Color {
        switch icon {
        case .symbol(_, let color): return color
        case .clock(let color): return color
        }
    }
}

// MARK: - Sizing per prominence

/// Value-type lookup table mapping a `BannerProminence` to concrete sizes.
/// Kept as a struct (vs scattered constants) so the view body reads from a
/// single object — easier to scan and to tweak when the design changes.
struct BannerSizing {
    let iconSize: CGFloat
    let iconSymbolSize: CGFloat
    let iconSpacing: CGFloat
    let titleSize: CGFloat
    let bodySize: CGFloat
    let contentSpacing: CGFloat
    let hPadding: CGFloat
    let vPadding: CGFloat
    let cornerRadius: CGFloat
    let shadowOpacity: Double
    let shadowRadius: CGFloat
    let shadowY: CGFloat
    let maxWidth: CGFloat
    let buttonHPadding: CGFloat
    let buttonVPadding: CGFloat
    let buttonFontSize: CGFloat

    init(_ prominence: BannerProminence) {
        switch prominence {
        case .standard:
            self.iconSize = 38
            self.iconSymbolSize = 16
            self.iconSpacing = 12
            self.titleSize = 17
            self.bodySize = 13
            self.contentSpacing = 10
            self.hPadding = 14
            self.vPadding = 12
            self.cornerRadius = 16
            self.shadowOpacity = 0.28
            self.shadowRadius = 22
            self.shadowY = 8
            self.maxWidth = 520
            self.buttonHPadding = 10
            self.buttonVPadding = 5
            self.buttonFontSize = 12
        case .prominent:
            self.iconSize = 44
            self.iconSymbolSize = 19
            self.iconSpacing = 14
            self.titleSize = 20
            self.bodySize = 13
            self.contentSpacing = 12
            self.hPadding = 18
            self.vPadding = 15
            self.cornerRadius = 20
            self.shadowOpacity = 0.40
            self.shadowRadius = 30
            self.shadowY = 12
            self.maxWidth = 580
            self.buttonHPadding = 12
            self.buttonVPadding = 6
            self.buttonFontSize = 12
        }
    }
}

/// The actual view rendered inside the borderless floating window.
struct FloatingBannerView: View {
    let state: FloatingBannerState
    let onDismiss: () -> Void

    @State private var visible = false

    private var sizing: BannerSizing { BannerSizing(state.prominence) }

    var body: some View {
        VStack(alignment: .leading, spacing: sizing.contentSpacing) {
            HStack(alignment: .top, spacing: sizing.iconSpacing) {
                iconView
                    .frame(width: sizing.iconSize, height: sizing.iconSize)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.title)
                        .font(.system(size: sizing.titleSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        // Digits glide instead of crossfading — gives the
                        // pre-break countdown its smooth feel.
                        .contentTransition(.numericText())
                        .animation(.default, value: state.title)
                    if let bodyText = state.body {
                        Text(bodyText)
                            .font(.system(size: sizing.bodySize))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            // Allow vertical growth to fit two lines without
                            // forcing the parent HStack to expand horizontally.
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !state.actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(state.actions) { action in
                        BannerActionButton(action: action, sizing: sizing, accentColor: state.accentColor)
                    }
                }
            }
        }
        .padding(.horizontal, sizing.hPadding)
        .padding(.vertical, sizing.vPadding)
        .background(
            // Drawing the rounded shape itself as the background (rather
            // than `.regularMaterial` + `.clipShape`) avoids any rectangular
            // ghost from the clip operation in older macOS versions.
            RoundedRectangle(cornerRadius: sizing.cornerRadius, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: sizing.cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 1)
        )
        // Top-right X close button. Inset matches the body padding so it
        // visually anchors to the rounded corner.
        .overlay(alignment: .topTrailing) {
            BannerCloseButton(onDismiss: onDismiss)
                .padding(.top, sizing.vPadding * 0.55)
                .padding(.trailing, sizing.hPadding * 0.55)
        }
        // Shadow is drawn by NSWindow.hasShadow (in FloatingBannerController)
        // so it follows the rounded content shape — drawing it in SwiftUI
        // would get clipped by the rectangular window edge.
        .opacity(visible ? 1 : 0)
        .offset(y: visible ? 0 : -14)
        .onAppear {
            withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
                visible = true
            }
        }
        // `.frame(maxWidth:) + .fixedSize` is the SwiftUI incantation for
        // "lay out at natural width, but never exceed maxWidth". Without
        // fixedSize the window's GeometryReader-driven hosting view would
        // stretch the banner to the full window width.
        .frame(maxWidth: sizing.maxWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
    }

    @ViewBuilder
    private var iconView: some View {
        switch state.icon {
        case .symbol(let name, let color):
            Image(systemName: name)
                .font(.system(size: sizing.iconSymbolSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: sizing.iconSize, height: sizing.iconSize)
                .background(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.95), color.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
        case .clock(let color):
            AnimatedClockIcon(tint: color, size: sizing.iconSize)
        }
    }
}

/// Hover-aware action button inside the floating banner. Primary buttons
/// fill with a tone of the icon's accent color; secondary buttons render
/// as outlines that fill on hover.
private struct BannerActionButton: View {
    let action: FloatingBannerState.Action
    let sizing: BannerSizing
    let accentColor: Color

    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action.handler) {
            Text(action.label)
                .font(.system(size: sizing.buttonFontSize, weight: action.isPrimary ? .semibold : .regular))
                .foregroundStyle(action.isPrimary ? .white : .primary)
                .padding(.horizontal, action.isPrimary ? sizing.buttonHPadding + 2 : sizing.buttonHPadding)
                .padding(.vertical, action.isPrimary ? sizing.buttonVPadding + 1 : sizing.buttonVPadding)
                .background(
                    Capsule().fill(fillColor)
                )
                .overlay(
                    Capsule().stroke(strokeColor, lineWidth: 1)
                )
                // Tinted drop shadow underneath primary buttons. Brightens
                // slightly on hover so the button feels alive.
                .shadow(
                    color: action.isPrimary ? accentColor.darkened(by: 0.25).opacity(hovering ? 0.38 : 0.25) : .clear,
                    radius: action.isPrimary ? (hovering ? 9 : 6) : 0,
                    y: action.isPrimary ? 2 : 0
                )
                .scaleEffect(pressed ? 0.96 : (hovering ? 1.03 : 1.0))
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
        // Zero-duration long-press gesture just to expose the press flag;
        // the actual action fires through Button's normal handler.
        .onLongPressGesture(minimumDuration: 0, perform: {}, onPressingChanged: { isPressing in
            pressed = isPressing
        })
        .onDisappear {
            if hovering {
                NSCursor.pop()
                hovering = false
            }
        }
        .animation(.smooth(duration: 0.15), value: hovering)
        .animation(.smooth(duration: 0.10), value: pressed)
    }

    private var fillColor: Color {
        if action.isPrimary {
            // Slight tone-down on the accent — barely darker than the icon hue.
            let base = accentColor.darkened(by: 0.10)
            return base.opacity(hovering ? 1.0 : 0.94)
        }
        return Color.primary.opacity(hovering ? 0.08 : 0.0)
    }

    private var strokeColor: Color {
        if action.isPrimary {
            return Color.clear
        }
        return Color.secondary.opacity(hovering ? 0.40 : 0.22)
    }
}

/// Small X close button at the banner's top-right.
private struct BannerCloseButton: View {
    let onDismiss: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary.opacity(hovering ? 1.0 : 0.7))
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(.secondary.opacity(hovering ? 0.22 : 0.12))
                )
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
            if hovering {
                NSCursor.pop()
                hovering = false
            }
        }
        .animation(.smooth(duration: 0.15), value: hovering)
    }
}

/// Pink-peach clock badge whose hand rotates significantly each second.
/// Used only by the pre-break heads-up so the user gets a visual "the
/// countdown is alive" cue alongside the numeric timer.
private struct AnimatedClockIcon: View {
    let tint: Color
    let size: CGFloat
    @State private var angle: Double = 0

    private let tickInterval: TimeInterval = 1
    private let degreesPerTick: Double = 30

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            tint,
                            Color(red: 1.0, green: 0.68, blue: 0.55)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: tint.opacity(0.35), radius: size * 0.18, y: 2)

            tickMarks
            clockHand
        }
        .frame(width: size, height: size)
        // `.task` for periodic hand rotation. Each tick advances the angle
        // and the spring animation does the rest.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(tickInterval))
                withAnimation(.spring(duration: 0.55, bounce: 0.35)) {
                    angle += degreesPerTick
                }
            }
        }
    }

    /// 12 evenly-spaced tick marks around the bezel. Every third one
    /// (the 12/3/6/9 positions) is bigger and brighter to mimic a real
    /// clock face.
    private var tickMarks: some View {
        let r = size * 0.40
        let majorH = size * 0.10
        let minorH = size * 0.07
        return ForEach(0..<12, id: \.self) { i in
            Capsule()
                .fill(.white.opacity(i % 3 == 0 ? 0.95 : 0.55))
                .frame(width: i % 3 == 0 ? 1.6 : 1.2, height: i % 3 == 0 ? majorH : minorH)
                .offset(y: -r)
                .rotationEffect(.degrees(Double(i) * 30))
        }
    }

    /// The rotating hand — a small capsule offset upward from the center
    /// so it pivots from the dial's center point.
    private var clockHand: some View {
        Capsule()
            .fill(.white)
            .frame(width: max(1.5, size * 0.04), height: size * 0.36)
            .offset(y: -size * 0.18)
            .rotationEffect(.degrees(angle))
    }
}

// MARK: - Color darkening helper

extension Color {
    /// Returns the color with each RGB channel multiplied by `(1 - factor)`.
    /// `factor` of 0.5 makes the color roughly half as bright while keeping
    /// its hue. macOS 14 compatible — uses NSColor sRGB component access.
    ///
    /// SwiftUI's Color doesn't expose its components directly; we round-trip
    /// through NSColor in the sRGB color space to read them.
    func darkened(by factor: Double) -> Color {
        let clamped = min(max(factor, 0), 1)
        let multiplier = 1.0 - clamped
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return self }
        return Color(
            red: Double(rgb.redComponent) * multiplier,
            green: Double(rgb.greenComponent) * multiplier,
            blue: Double(rgb.blueComponent) * multiplier,
            opacity: Double(rgb.alphaComponent)
        )
    }
}
