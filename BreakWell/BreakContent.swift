import SwiftUI

/// Content + presentation metadata for a single break type. Future break
/// presets (stretch, posture, mindfulness) become additional `BreakContent`
/// values; the `BreakTrack` type stays the same.
struct BreakContent: Sendable, Equatable {
    let title: String
    let instruction: String
    let iconSymbol: String
    let soundName: String?
    let accentColor: Color
    /// Optional rotation of varied prompts; if empty, the overlay falls back to
    /// `title` + `instruction`.
    let alternates: [BreakMessage]
}

extension BreakContent {
    /// Default eye-rest content. Pulls its varied prompt rotation from the
    /// pre-existing `BreakMessages.pool` so phase 1+'s "different message each
    /// break" behavior is preserved.
    static let eyeRest = BreakContent(
        title: "Rest your eyes — look 20 feet away",
        instruction: "Look at something at least 20 feet away for 20 seconds.",
        iconSymbol: "eye",
        soundName: "Glass",
        accentColor: Color(red: 0.65, green: 0.80, blue: 0.90),
        alternates: BreakMessages.pool
    )

    /// Picks a random prompt for this break. Falls back to `title`/`instruction`
    /// when no alternates are configured.
    func randomMessage() -> BreakMessage {
        alternates.randomElement() ?? BreakMessage(title: title, description: instruction)
    }
}
