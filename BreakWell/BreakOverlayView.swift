import SwiftUI
import AppKit

struct BreakOverlayView: View {
    let state: BreakOverlayState
    let onSkip: () -> Void
    let onExtend: (TimeInterval) -> Void

    @State private var visible = false

    var body: some View {
        ZStack {
            AuroraBackground()
            Color.black.opacity(0.15).ignoresSafeArea()

            VStack(spacing: 0) {
                // Padded below the menu bar / notch area so it's visible on
                // notched MacBooks where our screen-saver-level overlay sits
                // beneath the notch.
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
                    .contentTransition(.numericText())
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 4)

                Spacer()

                bottomControls
                    .padding(.bottom, 32)
            }
        }
        .opacity(visible ? 1 : 0)
        .animation(.default, value: state.remaining)
        .onAppear {
            withAnimation(.easeOut(duration: 0.55)) {
                visible = true
            }
        }
    }

    @ViewBuilder
    private var bottomControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                OverlayCapsuleButton(label: "Skip break", prominent: true) {
                    onSkip()
                }
                OverlayCapsuleButton(label: "+ 2 min") { onExtend(120) }
                OverlayCapsuleButton(label: "+ 5 min") { onExtend(300) }
                OverlayCapsuleButton(label: "+ 10 min") { onExtend(600) }
            }

            Text("Press Esc twice to skip")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private var timeString: String {
        let total = max(0, Int(state.remaining.rounded(.up)))
        let m = total / 60
        let s = total % 60
        return "\(m):\(String(format: "%02d", s))"
    }
}

// MARK: - Pill button with hover effect

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
        .onLongPressGesture(minimumDuration: 0, perform: {}, onPressingChanged: { isPressing in
            pressed = isPressing
        })
        .onDisappear {
            if hovering {
                NSCursor.pop()
                hovering = false
            }
        }
        .animation(.smooth(duration: 0.18), value: hovering)
        .animation(.smooth(duration: 0.10), value: pressed)
    }

    private func applyCursor(hovering: Bool) {
        if hovering {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }
}

// MARK: - Time at the top

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
            .task {
                while !Task.isCancelled {
                    now = Date()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
    }
}

// MARK: - Aurora background

struct AuroraBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/30, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                ZStack {
                    Color(red: 0.07, green: 0.05, blue: 0.09)

                    blob(Color(red: 0.55, green: 0.20, blue: 0.20),
                         baseX: 0.22, baseY: 0.30,
                         phase: t * 0.10, ampX: 0.10, ampY: 0.08,
                         scale: 1.4, opacity: 0.55, size: geo.size)

                    blob(Color(red: 0.50, green: 0.40, blue: 0.18),
                         baseX: 0.82, baseY: 0.38,
                         phase: t * 0.08 + 1.0, ampX: 0.10, ampY: 0.10,
                         scale: 1.3, opacity: 0.50, size: geo.size)

                    blob(Color(red: 0.60, green: 0.28, blue: 0.48),
                         baseX: 0.45, baseY: 0.75,
                         phase: t * 0.09 + 2.5, ampX: 0.14, ampY: 0.10,
                         scale: 1.5, opacity: 0.58, size: geo.size)

                    blob(Color(red: 0.30, green: 0.16, blue: 0.34),
                         baseX: 0.68, baseY: 0.70,
                         phase: t * 0.07 + 4.0, ampX: 0.10, ampY: 0.12,
                         scale: 1.2, opacity: 0.45, size: geo.size)
                }
            }
            .ignoresSafeArea()
        }
    }

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
