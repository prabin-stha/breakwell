import SwiftUI

struct MenuBarView: View {
    let viewModel: SchedulerViewModel

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
        .animation(.smooth(duration: 0.28), value: phaseKind)
        .animation(.smooth(duration: 0.22), value: viewModel.manualPauseSignal.isActive)
    }

    // MARK: - Status

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentTransition(.symbolEffect(.replace))
            Text(statusTitle)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.numericText())
                .animation(.default, value: statusTitle)
            Spacer(minLength: 0)
        }
        .frame(height: 28)
    }

    private var phaseKind: String {
        if case .deferred = viewModel.phase { return "deferred" }
        if viewModel.suppression.isActive, case .working = viewModel.phase { return "suppressed" }
        switch viewModel.phase {
        case .working: return "working"
        case .firing: return "firing"
        case .deferred: return "deferred"
        }
    }

    private var statusSymbol: String {
        if case .deferred = viewModel.phase {
            return "clock.badge.exclamationmark"
        }
        if viewModel.suppression.isActive, case .working = viewModel.phase {
            return "pause.circle"
        }
        switch viewModel.phase {
        case .working: return "eye"
        case .firing: return "eye.fill"
        case .deferred: return "clock.badge.exclamationmark"
        }
    }

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

    @ViewBuilder
    private var primaryActions: some View {
        Group {
            if case .deferred = viewModel.phase {
                MenuRow("Take break anyway", systemImage: "eye.fill") {
                    viewModel.takeBreakNow()
                }
            } else {
                MenuRow("Take break now", systemImage: "eye.fill") {
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

    @Environment(\.openSettings) private var openSettings

    @ViewBuilder
    private var secondaryActions: some View {
        MenuRow("Settings…", systemImage: "gear") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        MenuRow("Quit BreakWell", systemImage: "power") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    // MARK: - Helpers

    private func formatMMSS(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func formatBreakRemaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        if total >= 60 {
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        return "\(total)s"
    }
}

/// Plain row that mimics a menu item but lives inside the .window popover.
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering && !disabled ? Color.primary.opacity(0.07) : Color.clear)
        )
        .disabled(disabled)
        .foregroundStyle(disabled ? Color.secondary : Color.primary)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.15), value: hovering)
    }
}
