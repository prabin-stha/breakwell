import Foundation

// MARK: - BreakMessages
//
// Purpose: Holds the rotating pool of practical prompts shown during a
// short-break overlay. Picked at random each firing so the overlay doesn't
// feel robotic.
//
// Architecture role: A flat data file in Features/Break. No state, no
// logic beyond `randomElement()`.
//
// Key types defined:
//   - BreakMessage: the title/description value type
//   - BreakMessages: a namespace holding the pool + a `random()` helper
//
// Used by:
//   - BreakContent.shortBreak (sources its `alternates` from `pool`)
//   - BreakOverlayController (receives one BreakMessage per firing)
//
// Swift concepts a learner will see here:
//   - enum-as-namespace: same pattern as AppTiming. An enum with no cases
//     can hold static members but can't be instantiated.
//   - .init(...) shorthand inside an array literal: when the compiler can
//     infer the array element type, `.init(...)` is equivalent to
//     `BreakMessage(...)`. Reads nicer in a long list.

/// One title + description pair. Used both as `BreakContent.alternates`
/// entries and as the "what we picked for this break" value passed from
/// the presenter to the overlay controller.
struct BreakMessage: Sendable, Equatable {
    let title: String
    let description: String
}

/// Practical short-break prompts. The title is a punchy imperative; the
/// description elaborates or gives a concrete how. Picked at random each
/// firing — the variety keeps repeat breaks from feeling robotic.
///
/// New prompts: add another `.init(...)` line below. Keep them short —
/// the title is rendered at ~60pt and has to read at a glance.
enum BreakMessages {
    static let pool: [BreakMessage] = [
        .init(title: "Stand up and stretch.",
              description: "Reach overhead. Twist gently side to side."),
        .init(title: "Get some water.",
              description: "Hydration sneaks up on you. Refill while you're at it."),
        .init(title: "Roll your shoulders back.",
              description: "Open your chest. Drop your shoulders away from your ears."),
        .init(title: "Walk somewhere — anywhere.",
              description: "Even a lap around the kitchen counts. Move some blood."),
        .init(title: "Look out the window.",
              description: "Pick something far. Let your eyes refocus on distance."),
        .init(title: "Take a few slow breaths.",
              description: "Four counts in, hold for two, six counts out. Repeat three times."),
        .init(title: "Unclench your jaw.",
              description: "Soften your forehead, your shoulders, your fists. You were probably clenching all three."),
        .init(title: "Step outside for a minute.",
              description: "Fresh air resets more than you'd think. Just to the doorway is enough."),
        .init(title: "Stretch your hands and wrists.",
              description: "Open, close, circle each way. Your typing fingers earned this."),
        .init(title: "Notice three things in the room.",
              description: "Anything you hadn't paid attention to today. Bring your focus back outside the screen."),
        .init(title: "Drop your shoulders.",
              description: "They've been creeping toward your ears since the last break."),
        .init(title: "Walk in place for thirty seconds.",
              description: "Or do some calf raises. Or shake your legs out. Whatever moves you.")
    ]

    /// Pick a random prompt from the pool. The `?? pool[0]` fallback is
    /// only defensive — `randomElement()` returns nil only on empty arrays.
    static func random() -> BreakMessage {
        pool.randomElement() ?? pool[0]
    }
}
