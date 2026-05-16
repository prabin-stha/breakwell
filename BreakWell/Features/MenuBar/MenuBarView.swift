import SwiftUI

// MARK: - MenuBarView
//
// Purpose: The SwiftUI content shown when the user clicks BreakWell's menu
// bar icon. Status line at the top, then
// Take-break / Pause / Settings / Quit rows.
//
// Architecture role: Pure SwiftUI view. Reads from `SchedulerViewModel`
// (phase, suppression, manual pause) and `BreakStats`; writes happen
// only through method calls on the view model.
//
// About the Features/MenuBar/ folder:
// Just two files: this view and its view model. The view is intentionally
// dumb — formatting, layout, hover handling. The view model is the bridge
// between SwiftUI's @Observable world and the actor-isolated
// ReminderCoordinator / SuppressionEngine (which can't be observed directly
// from a view body because they're not on the main actor).
//
// Key types defined:
//   - MenuBarView: the main popover-content view
//   - MenuRow: private custom row that mimics an NSMenu item visually but
//     lives inside a `.window`-style popover (where NSMenu can't be used)
//
// Used by:
//   - BreakWellApp (`MenuBarExtra { MenuBarView(...) }`)
//
// Swift / SwiftUI concepts a learner will see here:
//   - `.contentTransition(.symbolEffect(.replace))`: SwiftUI animates the
//     swap between SF Symbols (cup.and.saucer → cup.and.saucer.fill, etc.)
//     rather than crossfading.
//   - `.contentTransition(.numericText())`: same idea but for text — the
//     digits in the countdown slide rather than fade.
//   - `@Environment(\.openSettings)`: SwiftUI ships an environment action
//     that opens the app's Settings scene declared in the App body.
//   - `.transition(.opacity.combined(with: .move(edge: .top)))`: a custom
//     transition for rows that swap in/out (Take break ↔ Take anyway,
//     Pause ↔ Resume). Combined transitions chain multiple effects.
//   - `.contentShape(Rectangle())`: makes the entire row hit-test as a
//     button, including the spacer area, not just the icon + text.

/// The popover content shown by `MenuBarExtra`. Fixed 260pt wide so it
/// matches the visual rhythm of system menus.
struct MenuBarView: View {
    let viewModel: SchedulerViewModel
    let breakStats: BreakStats

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusRow
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                primaryActions
                Divider().padding(.vertical, 4)
                secondaryActions
            }
            .padding(8)
        }
        .frame(width: 260)
        // Animate on the *kind* of phase change (working → firing →
        // deferred) rather than the per-second countdown value, otherwise
        // the whole popover would animate every tick.
        .animation(.smooth(duration: 0.28), value: phaseKind)
        .animation(.smooth(duration: 0.22), value: viewModel.manualPauseSignal.isActive)
    }

    // MARK: - Status

    /// The top row: an SF Symbol + a one-line summary. The symbol and text
    /// both use `.contentTransition` so swapping between states is animated.
    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                // SwiftUI cross-morphs between SF Symbol variants instead
                // of doing a hard cut. Reads as a single icon "shifting".
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Digit slide rather than crossfade for the countdown.
                    .contentTransition(.numericText())
                    .animation(.default, value: statusTitle)
                // Ambient daily-completion stat. Hidden when zero so the
                // popover doesn't display "0 breaks today" first thing in
                // the morning — that reads as a scold, not a stat.
                if breakStats.completedToday > 0 {
                    Text(breaksTodayText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// "1 break today" / "4 breaks today". Singular/plural fork keeps the
    /// copy clean for the common opening-of-day case.
    private var breaksTodayText: String {
        let n = breakStats.completedToday
        return "\(n) \(n == 1 ? "break" : "breaks") today"
    }

    /// Stable string key for the *kind* of phase, used as the animation
    /// driver. Computing this separately means our top-level animation
    /// fires only on kind changes, not on every countdown tick.
    private var phaseKind: String {
        if case .deferred = viewModel.phase { return "deferred" }
        if viewModel.suppression.isActive, case .working = viewModel.phase { return "suppressed" }
        switch viewModel.phase {
        case .working: return "working"
        case .firing: return "firing"
        case .deferred: return "deferred"
        }
    }

    /// SF Symbol name for the current state. Order matters: deferred and
    /// suppressed are special cases that override the base phase symbol.
    private var statusSymbol: String {
        if case .deferred = viewModel.phase {
            return "clock.badge.exclamationmark"
        }
        if viewModel.suppression.isActive, case .working = viewModel.phase {
            return "pause.circle"
        }
        switch viewModel.phase {
        case .working: return "cup.and.saucer"
        case .firing: return "cup.and.saucer.fill"
        case .deferred: return "clock.badge.exclamationmark"
        }
    }

    /// Headline text. Includes the suppression reason when paused
    /// ("Paused — meeting") so the user knows *why* nothing's firing.
    private var statusTitle: String {
        if case .deferred = viewModel.phase {
            if let reason = viewModel.suppression.reason {
                return "Break ready — \(reason)"
            }
            return "Break ready"
        }
        if viewModel.suppression.isActive, case .working = viewModel.phase {
            return viewModel.suppression.reason ?? "Paused"
        }
        switch viewModel.phase {
        case .working(let remaining):
            return "Next break in \(formatMMSS(remaining))"
        case .firing(let remaining, _):
            return "On break — \(formatBreakRemaining(remaining))"
        case .deferred:
            return "Break ready"
        }
    }

    // MARK: - Actions

    /// Primary row group: "Take break" + "Pause/Resume". Wrapped in `Group`
    /// so the if/else swap participates in the parent's transition.
    @ViewBuilder
    private var primaryActions: some View {
        Group {
            if case .deferred = viewModel.phase {
                // When suppressed, label clarifies that pressing this
                // overrides the deferral, not "schedule a new break".
                MenuRow("Take break anyway", systemImage: "cup.and.saucer.fill") {
                    viewModel.takeBreakNow()
                }
            } else {
                MenuRow("Take break now", systemImage: "cup.and.saucer.fill") {
                    viewModel.takeBreakNow()
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))

        Group {
            if viewModel.manualPauseSignal.isActive {
                MenuRow("Resume", systemImage: "play.fill") {
                    viewModel.resume()
                }
            } else {
                MenuRow("Pause for 1 hour", systemImage: "pause.fill") {
                    viewModel.pauseForHour()
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // SwiftUI ships this environment value to invoke the app's Settings
    // scene declared in BreakWellApp's body. Pulling it from the
    // environment avoids hard-wiring a window reference.
    @Environment(\.openSettings) private var openSettings

    @ViewBuilder
    private var secondaryActions: some View {
        MenuRow("Settings…", systemImage: "gear") {
            openSettings()
            // `openSettings()` schedules the window but doesn't force the
            // app to activate. Without this call, the window can open
            // behind whatever app the user was in.
            NSApp.activate(ignoringOtherApps: true)
        }
        MenuRow("Quit BreakWell", systemImage: "power") {
            NSApp.terminate(nil)
        }
        // ⌘Q while the popover is showing quits the app — matches what
        // users expect from a menu-bar utility.
        .keyboardShortcut("q")
    }

    // MARK: - Helpers

    /// Format seconds as "M:SS" — used for the "Next break in …" countdown.
    /// Rounding up (`.up`) means we never show "0:00" while the timer is
    /// still ticking down through the final fraction of a second.
    private func formatMMSS(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// During a break the countdown is short — show "M:SS" for ≥60 s and
    /// plain "Ns" below that. Cleaner than "0:42".
    private func formatBreakRemaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        if total >= 60 {
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        return "\(total)s"
    }
}

// MARK: - MenuRow

/// A custom row that mimics an NSMenu item visually but lives inside a
/// `.window`-style popover. We use it because `MenuBarExtra(.window)`
/// renders arbitrary SwiftUI — no real NSMenu — so we can't use `Menu`
/// items here. The trade-off is we re-implement hover + cursor + spacing
/// ourselves.
private struct MenuRow: View {
    let title: String
    let systemImage: String
    var disabled: Bool = false
    let action: () -> Void

    @State private var hovering = false

    init(_ title: String, systemImage: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                Text(title)
                Spacer()
            }
            // Without this, the Spacer area isn't part of the hit zone —
            // the user could click "on" the row in empty space and nothing
            // would happen. `.contentShape(Rectangle())` extends hit-testing
            // to the full visible area.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering && !disabled ? Color.primary.opacity(0.09) : Color.clear)
        )
        .disabled(disabled)
        .foregroundStyle(disabled ? Color.secondary : Color.primary)
        .onHover { value in
            hovering = value
            guard !disabled else { return }
            // NSCursor uses a push/pop stack. Push on hover-enter, pop on
            // hover-exit. Mismatched calls leak — see `onDisappear` below.
            if value {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            // Defensive: if the view goes away mid-hover (popover closes
            // while pointer is on a row), pop the cursor or it stays as a
            // hand pointer on the user's screen.
            if hovering {
                NSCursor.pop()
                hovering = false
            }
        }
        .animation(.smooth(duration: 0.15), value: hovering)
    }
}
