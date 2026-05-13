import Foundation

/// The 20-20-20 eye-rest track that BreakWell ships with by default.
/// Encapsulates the behavior of phase 1's `BreakScheduler` as a single track.
struct EyeRestTrack: ReminderTrack {
    nonisolated var id: String { "eye-rest" }
    nonisolated var displayName: String { "Eye rest" }
    nonisolated let interval: Duration
    nonisolated let duration: Duration
    nonisolated var interruption: InterruptionLevel { .overlay }
    nonisolated var isGroupable: Bool { true }
    nonisolated var respectsPomodoro: Bool { true }

    nonisolated func makeContent() -> ReminderContent {
        ReminderContent(
            trackID: id,
            title: "Rest your eyes — look 20 feet away",
            body: nil,
            interruption: interruption,
            duration: duration
        )
    }
}
