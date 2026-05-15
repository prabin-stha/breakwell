import Foundation

/// Generic break track. The 20-20-20 eye rest is its default instance
/// (`content: .eyeRest`). Future break types (stretch, posture, mindfulness)
/// are additional `BreakTrack` values with different `BreakContent`.
struct BreakTrack: ReminderTrack {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let interval: Duration
    nonisolated let duration: Duration
    nonisolated let content: BreakContent

    nonisolated var interruption: InterruptionLevel { .overlay }
    nonisolated var isGroupable: Bool { true }
    nonisolated var respectsPomodoro: Bool { true }

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
