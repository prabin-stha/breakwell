import Foundation

nonisolated enum InterruptionLevel: Sendable, Equatable {
    case overlay         // full-screen, modal — eye rest, pomodoro breaks
    case prominentCard   // centered floating card with actions — hydration
    case banner          // notification banner — generic reminders
    case menuBarPulse    // subtle icon animation only
    case soundOnly       // chime, no visual

    /// Higher value = more important. Used by the coordinator's `tryShow` to
    /// resolve conflicts when two reminders try to surface at once.
    var priority: Int {
        switch self {
        case .overlay: 100
        case .prominentCard: 50
        case .banner: 20
        case .menuBarPulse: 10
        case .soundOnly: 10
        }
    }
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
    /// Optional system-sound name to play on firing start (e.g. "Glass").
    /// Used by `BreakSoundPlayer` for overlay-level firings.
    let soundName: String?

    init(
        trackID: String,
        title: String,
        body: String?,
        interruption: InterruptionLevel,
        duration: Duration,
        soundName: String? = nil
    ) {
        self.trackID = trackID
        self.title = title
        self.body = body
        self.interruption = interruption
        self.duration = duration
        self.soundName = soundName
    }
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
