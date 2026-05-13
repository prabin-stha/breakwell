import SwiftUI
import AppKit

/// The icon shown on the left of the floating banner.
enum BannerIcon: Sendable {
    case symbol(name: String, color: Color)
    case clock(color: Color)
}

@MainActor
@Observable
final class FloatingBannerState {
    var title: String
    var body: String?
    let icon: BannerIcon
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
        actions: [Action] = []
    ) {
        self.title = title
        self.body = body
        self.icon = icon
        self.actions = actions
    }
}

struct FloatingBannerView: View {
    let state: FloatingBannerState
    let onDismiss: () -> Void

    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                iconView
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.default, value: state.title)
                    if let bodyText = state.body {
                        Text(bodyText)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !state.actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(state.actions) { action in
                        actionButton(action)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 22, y: 8)
        .opacity(visible ? 1 : 0)
        .offset(y: visible ? 0 : -12)
        .onAppear {
            withAnimation(.spring(duration: 0.35, bounce: 0.18)) {
                visible = true
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
    }

    @ViewBuilder
    private var iconView: some View {
        switch state.icon {
        case .symbol(let name, let color):
            Image(systemName: name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
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
            AnimatedClockIcon(tint: color)
        }
    }

    @ViewBuilder
    private func actionButton(_ action: FloatingBannerState.Action) -> some View {
        Button(action: action.handler) {
            Text(action.label)
                .font(.system(size: 12, weight: action.isPrimary ? .semibold : .regular))
                .foregroundStyle(.primary)
                .padding(.horizontal, action.isPrimary ? 12 : 10)
                .padding(.vertical, action.isPrimary ? 6 : 5)
                .background(
                    Capsule()
                        .fill(action.isPrimary ? Color.primary.opacity(0.12) : Color.clear)
                )
                .overlay(
                    Capsule().stroke(
                        Color.secondary.opacity(action.isPrimary ? 0.0 : 0.22),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
    }
}

/// Pink-peach clock badge whose hand rotates significantly each second.
private struct AnimatedClockIcon: View {
    let tint: Color
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
                .shadow(color: tint.opacity(0.35), radius: 6, y: 2)

            tickMarks
            clockHand
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(tickInterval))
                withAnimation(.spring(duration: 0.55, bounce: 0.35)) {
                    angle += degreesPerTick
                }
            }
        }
    }

    private var tickMarks: some View {
        ForEach(0..<12, id: \.self) { i in
            Capsule()
                .fill(.white.opacity(i % 3 == 0 ? 0.95 : 0.55))
                .frame(width: i % 3 == 0 ? 1.5 : 1, height: i % 3 == 0 ? 3.5 : 2.5)
                .offset(y: -14)
                .rotationEffect(.degrees(Double(i) * 30))
        }
    }

    /// Hand grows upward from the center: its center sits at the clock's center,
    /// then we offset by -height/2 so the bottom of the capsule aligns with center
    /// and the top extends out toward 12 o'clock.
    private var clockHand: some View {
        Capsule()
            .fill(.white)
            .frame(width: 1.6, height: 13)
            .offset(y: -6.5)
            .rotationEffect(.degrees(angle))
    }
}
