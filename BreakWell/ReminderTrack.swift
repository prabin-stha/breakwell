import Foundation

nonisolated enum InterruptionLevel: Sendable, Equatable {
    case overlay         // full-screen, modal — eye rest, pomodoro breaks
    case prominentCard   // centered floating card with actions — hydration
    case banner          // notification banner — generic reminders
    case menuBarPulse    // subtle icon animation only
    case soundOnly       // chime, no visual
}

/// The user-visible content of a single reminder firing.
/// Carries interruption level alongside text so handlers can dispatch without
/// looking back at the track.
nonisolated struct ReminderContent: Sendable, Equatable {
    let trackID: String
    let title: String
    let body: String?
    let interruption: InterruptionLevel
    let duration: Duration
}

/// One scheduled reminder track. Stateless value type — scheduling state
/// (next-fire times, etc.) lives in `ReminderCoordinator`.
///
/// Members are `nonisolated` because the project's default actor isolation is
/// `MainActor`, and `ReminderCoordinator` (an `actor`) needs to read track
/// config without hopping to the main actor.
protocol ReminderTrack: Sendable {
    nonisolated var id: String { get }
    nonisolated var displayName: String { get }
    nonisolated var interval: Duration { get }
    nonisolated var duration: Duration { get }
    nonisolated var interruption: InterruptionLevel { get }
    nonisolated var isGroupable: Bool { get }
    nonisolated var respectsPomodoro: Bool { get }
    nonisolated func makeContent() -> ReminderContent
}

extension Duration {
    /// Bridge to TimeInterval. Existing scheduling code is in seconds.
    nonisolated var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
