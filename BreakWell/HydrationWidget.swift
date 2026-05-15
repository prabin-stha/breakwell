import SwiftUI

/// Compact hydration display shown in the menu bar popover.
/// Recency bar drains as time since last drink grows; numeric count + textual
/// "last drink" stay live via `HydrationState`'s self-refresh.
struct HydrationWidget: View {
    let state: HydrationState
    var showGoalMarker: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Text("**\(state.todayCount)** today")
                    .font(.caption)
                Spacer(minLength: 8)
                Text(state.lastDrinkText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.secondary.opacity(0.18))

                    Capsule()
                        .fill(barColor)
                        .frame(width: max(0, geo.size.width * state.recencyScore))
                        .animation(.smooth(duration: 0.4), value: state.recencyScore)

                    if showGoalMarker {
                        Rectangle()
                            .fill(Color.primary.opacity(0.75))
                            .frame(width: 2, height: 12)
                            .offset(x: geo.size.width * 0.66 - 1)
                    }
                }
            }
            .frame(height: 6)
            .animation(.smooth(duration: 0.4), value: state.recencyScore)
        }
    }

    private var barColor: Color {
        let s = state.recencyScore
        if s > 0.6 { return Color(red: 0.40, green: 0.78, blue: 0.45) }
        if s > 0.3 { return Color(red: 0.95, green: 0.72, blue: 0.30) }
        return Color(red: 0.90, green: 0.45, blue: 0.45)
    }
}
