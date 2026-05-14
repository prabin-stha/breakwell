import Foundation

struct BreakMessage: Sendable, Equatable {
    let title: String
    let description: String
}

/// Calm, varied prompts to display during the eye-rest overlay. Picked at random
/// each time a break fires — the variety keeps the overlay from feeling robotic.
enum BreakMessages {
    static let pool: [BreakMessage] = [
        .init(title: "Find something distant and just breathe.",
              description: "Look at something at least 20 feet away for 20 seconds."),
        .init(title: "Soften your gaze, soften your shoulders.",
              description: "Let your focus drift toward the horizon. Unclench your jaw."),
        .init(title: "Step away from the pixels for a moment.",
              description: "Your eyes will thank you. Find something far to settle on."),
        .init(title: "A small reset for your eyes.",
              description: "Choose a far-away point and let your gaze rest there."),
        .init(title: "Twenty seconds, twenty feet.",
              description: "That's the whole exercise. Look outward and breathe deeply."),
        .init(title: "Pause, stretch, notice the room.",
              description: "Look out a window or across the room — anything but the screen."),
        .init(title: "Your eyes deserve this moment.",
              description: "Defocus from the screen. Find depth in the distance."),
        .init(title: "Breathe in slowly. Look outward.",
              description: "Twenty seconds of distant focus restores your vision."),
        .init(title: "Let the world come back into focus.",
              description: "Look as far as you can see. Slow your breath."),
        .init(title: "Just twenty seconds. You earned it.",
              description: "Find something across the room and let your eyes rest there."),
        .init(title: "Look up. Look out. Look beyond.",
              description: "Give your eyes a chance to stretch toward the horizon."),
        .init(title: "Your eyes are the most worked muscle of your day.",
              description: "Let them relax. Look at the farthest thing you can find."),
        .init(title: "A moment of stillness, just for you.",
              description: "Breathe slow. Look far. Return refreshed."),
        .init(title: "Trade the screen for the sky.",
              description: "If a window's nearby, look out of it. If not, the far wall will do."),
        .init(title: "Let your eyes wander somewhere far.",
              description: "Long-distance focus eases the strain of close work.")
    ]

    static func random() -> BreakMessage {
        pool.randomElement() ?? pool[0]
    }
}
