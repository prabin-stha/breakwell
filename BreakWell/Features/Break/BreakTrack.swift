import Foundation

// MARK: - BreakTrack
//
// Purpose: Generic break track conformer. Instantiated with a `BreakContent`
// to become a specific kind of break (short, long, mindfulness, posture).
// The shipped short break is just this type plus `content: .shortBreak`.
//
// Architecture role: Bridge between `Core/Scheduling`'s `ReminderTrack`
// protocol and the `Features/Break` content model. Holds no runtime state —
// scheduling state lives in `ReminderCoordinator`.
//
// Key types defined:
//   - BreakTrack: the value-type conformer
//
// Used by:
//   - BreakWellApp (constructs the eye-rest instance and any future presets)
//   - ReminderCoordinator (stores in its tracks array)
//
// Swift concepts a learner will see here:
//   - protocol conformance via stored properties: `let id: String` etc.
//     satisfy the protocol's `var id: String { get }` requirements without
//     any extra ceremony.
//   - `nonisolated` on stored properties: opts each property out of the
//     project's default MainActor isolation. The protocol requires
//     nonisolated; conformers must match.

/// Generic break track. The shipped short break is its default instance
/// (`content: .shortBreak`). Future break types — long break, mindfulness,
/// posture — are additional `BreakTrack` values with different
/// `BreakContent`.
///
/// Example usage:
/// ```swift
/// let shortBreak = BreakTrack(
///     id: "break.short",
///     displayName: "Short Break",
///     interval: .seconds(settings.workDuration),
///     duration: .seconds(settings.breakDuration),
///     content: .shortBreak
/// )
/// ```
struct BreakTrack: ReminderTrack {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let interval: Duration
    nonisolated let duration: Duration
    nonisolated let content: BreakContent

    // Every break is overlay-level (it takes over the screen) and groupable
    // (could combine with a water reminder in the future). Hard-coded
    // because every break shares this — moving them into BreakContent
    // would make new break types optional in ways they shouldn't be.
    nonisolated var interruption: InterruptionLevel { .overlay }
    nonisolated var isGroupable: Bool { true }

    nonisolated func makeContent() -> ReminderContent {
        ReminderContent(
            trackID: id,
            title: content.title,
            body: content.instruction,
            interruption: interruption,
            duration: duration,
            soundName: content.soundName
        )
    }
}
