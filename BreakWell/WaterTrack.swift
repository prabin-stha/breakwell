import Foundation

/// Hourly hydration reminder. Fires as a notification banner, not a fullscreen
/// overlay — full-screen takeover for hydration would train the user to dismiss
/// overlays reflexively, weakening the eye-rest overlay's effectiveness.
struct WaterTrack: ReminderTrack {
    nonisolated var id: String { "water" }
    nonisolated var displayName: String { "Hydration" }
    nonisolated let interval: Duration
    nonisolated var duration: Duration { .seconds(30) }  // notification auto-dismiss window
    nonisolated var interruption: InterruptionLevel { .banner }
    nonisolated var isGroupable: Bool { true }
    nonisolated var respectsPomodoro: Bool { true }

    nonisolated func makeContent() -> ReminderContent {
        ReminderContent(
            trackID: id,
            title: "Time for a sip of water",
            body: "Stay hydrated — a small drink helps your focus.",
            interruption: interruption,
            duration: duration
        )
    }
}
