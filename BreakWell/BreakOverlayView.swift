import SwiftUI
import AppKit

struct BreakOverlayView: View {
    let state: BreakOverlayState
    let onSkip: () -> Void

    @State private var visible = false

    var body: some View {
        ZStack {
            // NSVisualEffectView with `.behindWindow` blends with whatever's
            // behind our borderless overlay window — giving the macOS-native
            // frosted glass look over the user's desktop.
            VisualEffectBackground(material: .fullScreenUI, blendingMode: .behindWindow)
                .ignoresSafeArea()

            // Subtle darkening tint over the blur to make the message readable
            // and signal "this is a break" without going fully opaque.
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Text("Rest your eyes — look 20 feet away")
                    .font(.system(size: 32, weight: .light, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                Text(timeString)
                    .font(.system(size: 120, weight: .thin, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .shadow(color: .black.opacity(0.3), radius: 14, y: 3)
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: onSkip) {
                        Text("Skip break")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(.white.opacity(0.08))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(.white.opacity(0.12), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 28)
                    .padding(.bottom, 24)
                }
            }
        }
        .opacity(visible ? 1 : 0)
        .animation(.default, value: state.remaining)
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) {
                visible = true
            }
        }
    }

    private var timeString: String {
        let total = max(0, Int(state.remaining.rounded(.up)))
        if total >= 60 {
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        return "\(total)"
    }
}

/// Wraps `NSVisualEffectView` for SwiftUI use. SwiftUI's `.background(.ultraThinMaterial)`
/// only blurs in-window content; we need `.behindWindow` blending to blur the
/// user's actual desktop behind our overlay window.
private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
