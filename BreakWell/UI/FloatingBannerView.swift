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
//   - BannerProminence: standard vs prominent size tier (currently unused
//     by the editorial layout; left in place for future variants)
//   - FloatingBannerState: @Observable state passed to the view
//   - BannerSizing: a value-type lookup table mapping prominence → numbers
//     (carried over from the prior layout; not read by the editorial view)
//   - FloatingBannerView: the editorial-style banner
//   - DashedLine, EditorialActionButton: subviews
//   - Color.darkened(by:): helper extension (currently unused but kept
//     as a small utility for future button styling)
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

/// Size + emphasis tier for a banner. The pre-break heads-up uses
/// `.prominent`; background reminders like water use `.standard`.
enum BannerProminence: Sendable {
    case standard
    case prominent
}

/// Observable state shared between the controller and the SwiftUI view.
/// Mutating `title`, `timer`, or `actions` re-renders the view automatically.
@MainActor
@Observable
final class FloatingBannerState {
    var title: String
    var body: String?
    let prominence: BannerProminence
    var actions: [Action]
    /// Short countdown text rendered top-right ("0:08"). Updated each tick
    /// by the caller alongside whatever else changes. Carried separately
    /// from `title` because the editorial layout uses `title` as a static
    /// section header ("A SMALL PAUSE") and this field for the dynamic
    /// timer next to it.
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
        body: String? = nil,
        prominence: BannerProminence = .standard,
        actions: [Action] = [],
        timer: String = "",
        bodyMessage: HeadsUpMessage = .defaultMessage
    ) {
        self.title = title
        self.body = body
        self.prominence = prominence
        self.actions = actions
        self.timer = timer
        self.bodyMessage = bodyMessage
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

    @State private var visible = false

    // Palette tuned to the cream-paper aesthetic. All five colors derived
    // from a warm clay/cocoa family so the card reads as a single mood.
    /// Sole custom color in the palette. Everything else (body text,
    /// header, timer, dividers) uses system `.primary` / `.secondary`
    /// so the card adapts cleanly to light and dark glass. The accent is
    /// kept as a fixed warm clay because it's the editorial signature
    /// — the italic emphasis phrase + the "Begin now" underline. Tuned
    /// brighter than the earlier cream-paper version so it stays readable
    /// on dark `.regularMaterial`.
    private let accentClay = Color(red: 0.86, green: 0.38, blue: 0.24)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .padding(.vertical, 11)

            DashedLine()
                .stroke(Color.secondary.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .frame(height: 1)

            bodyText
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)

            DashedLine()
                .stroke(Color.secondary.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .frame(height: 1)

            footerRow
                .padding(.vertical, 11)
        }
        .padding(.horizontal, 22)
        // Glass background — `.regularMaterial` gets us the blur + tint
        // that native macOS panels use. The shape itself owns the fill
        // (rather than `.background(.regularMaterial).clipShape(...)`)
        // so we don't get a rectangular ghost in the corners on some
        // macOS versions.
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
        )
        // Subtle white gradient stroke for the "glass rim" highlight at
        // the top edge — bright at the top, fading to barely-visible at
        // the bottom. This is the small touch that distinguishes "frosted
        // panel" from "flat translucent rectangle".
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.35),
                            .white.opacity(0.05)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
        )
        // Shadow rendered by NSWindow.hasShadow (in FloatingBannerController)
        // so it follows the rounded shape exactly.
        .opacity(visible ? 1 : 0)
        .offset(y: visible ? 0 : -14)
        .onAppear {
            withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
                visible = true
            }
        }
        .frame(width: 460, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
    }

    // MARK: - Header

    @ViewBuilder
    private var headerRow: some View {
        HStack(alignment: .center) {
            // Header label: sans-serif (system default), uses `.secondary`
            // so the small-caps header sits one rung quieter than the
            // body text and adapts cleanly to light/dark glass.
            Text(state.title)
                .font(.system(size: 11, weight: .medium))
                .tracking(1.8)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            // The dynamic timer. `numericText()` content transition slides
            // the digits as they change instead of crossfading.
            Text("starts in \(state.timer)")
                .font(.system(size: 13, design: .serif).italic())
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.default, value: state.timer)
        }
    }

    // MARK: - Body

    /// Editorial body copy. Three segments concatenated:
    ///   - prefix in normal serif (adaptive `.primary`)
    ///   - emphasis in italic + clay accent (custom warm color)
    ///   - suffix in normal serif (adaptive `.primary`)
    /// The actual strings come from `state.bodyMessage`, which the caller
    /// picks once when the banner is created — see the message pool in
    /// `PreBreakNotifier`.
    private var bodyText: Text {
        let bodyFont = Font.system(size: 18, weight: .regular, design: .serif)
        let msg = state.bodyMessage
        return Text(msg.prefix)
            .font(bodyFont)
            .foregroundColor(.primary)
        + Text(msg.emphasis)
            .font(bodyFont.italic())
            .foregroundColor(accentClay)
        + Text(msg.suffix)
            .font(bodyFont)
            .foregroundColor(.primary)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerRow: some View {
        HStack(spacing: 22) {
            // Primary (underlined clay) — the "Begin now" affordance.
            if let primary = state.actions.first(where: { $0.isPrimary }) {
                EditorialActionButton(
                    label: primary.label,
                    color: accentClay,
                    style: .primary,
                    action: primary.handler
                )
            }
            // Snooze + any other non-primary actions, sitting beside the
            // primary one so they read as related "act on the break"
            // options. Rendered with a softer style (italic clay) so
            // hierarchy still favours the primary.
            ForEach(state.actions.filter { !$0.isPrimary }) { action in
                EditorialActionButton(
                    label: action.label,
                    color: accentClay,
                    style: .alternate,
                    action: action.handler
                )
            }
            Spacer()
            // Dismiss / "close" — close the banner without rescheduling.
            // Wired to the same handler the controller uses for its own
            // close, so the break still fires at its scheduled time;
            // this just hides the heads-up.
            EditorialActionButton(
                label: "close",
                color: .secondary,
                style: .secondary,
                action: onDismiss
            )
        }
    }

}

/// Horizontal dashed line for the editorial banner's section dividers.
/// The dash pattern is supplied by the caller via `StrokeStyle`.
private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        return path
    }
}

/// Text-only action button used in the editorial layout's footer.
/// - `.primary`: underlined clay (the headline action — "Begin now")
/// - `.alternate`: italic clay (sibling action — "snooze 5m"). Same hue
///   family as primary but italic + no underline, so it reads as "the
///   other thing you can do" without competing for attention.
/// - `.secondary`: italic muted ("close" / dismiss).
private struct EditorialActionButton: View {
    enum Style { case primary, alternate, secondary }

    let label: String
    let color: Color
    let style: Style
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            labelText
                .opacity(hovering ? 0.78 : 1.0)
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
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    /// `Text` chained styling so we can pick italic / underline per style
    /// without juggling separate view branches.
    private var labelText: Text {
        let base = Text(label)
            .font(.system(size: 14, weight: .regular, design: .serif))
            .foregroundColor(color)
        switch style {
        case .primary:
            return base.underline()
        case .alternate:
            return base.italic()
        case .secondary:
            return base.italic()
        }
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
