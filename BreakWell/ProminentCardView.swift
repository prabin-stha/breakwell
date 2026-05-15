import SwiftUI
import AppKit

/// Centered floating card — placeholder content for the hydration reminder.
/// Real hydration state (count, recency) gets wired in the next step.
struct ProminentCardView: View {
    let content: ReminderContent
    let hydration: HydrationState
    let onConfirm: () -> Void
    let onSkip: () -> Void

    @State private var visible = false

    private let accent = Color(red: 0.32, green: 0.72, blue: 0.92)

    var body: some View {
        VStack(spacing: 14) {
            iconBadge

            VStack(spacing: 4) {
                Text(content.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                if let body = content.body {
                    Text(body)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)

            HStack(spacing: 8) {
                CardButton(label: "Log drink", isPrimary: true, accent: accent, action: onConfirm)
                CardButton(label: "Skip", isPrimary: false, accent: accent, action: onSkip)
            }

            Text("\(hydration.todayCount) today")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 1)
        )
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.94)
        .onAppear {
            withAnimation(.spring(duration: 0.4, bounce: 0.18)) {
                visible = true
            }
        }
    }

    @ViewBuilder
    private var iconBadge: some View {
        Image(systemName: "drop.fill")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .background(
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [accent, accent.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .shadow(color: accent.opacity(0.35), radius: 8, y: 2)
    }
}

private struct CardButton: View {
    let label: String
    let isPrimary: Bool
    let accent: Color
    let action: () -> Void

    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: isPrimary ? .semibold : .regular))
                .foregroundStyle(isPrimary ? .white : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(fillColor)
                )
                .overlay(
                    Capsule().stroke(strokeColor, lineWidth: 1)
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
        if isPrimary {
            return accent.opacity(hovering ? 1.0 : 0.92)
        }
        return Color.primary.opacity(hovering ? 0.08 : 0.0)
    }

    private var strokeColor: Color {
        if isPrimary {
            return Color.clear
        }
        return Color.secondary.opacity(hovering ? 0.40 : 0.24)
    }
}
