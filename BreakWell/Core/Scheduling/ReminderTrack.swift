import Foundation

// MARK: - ReminderTrack
//
// Purpose: Defines the abstract notion of a "reminder track" — a scheduled
// thing that wants to appear on screen periodically — plus the shared value
// types every track returns (`InterruptionLevel`, `ReminderContent`).
//
// Architecture role: Core/Scheduling protocol layer. No concrete track lives
// here — concrete tracks like `BreakTrack` live in Features/.
// The coordinator only ever knows tracks through this protocol.
//
// Key types defined:
//   - InterruptionLevel: how loud a track is allowed to be on screen
//   - ReminderContent: the rendered payload of a single firing
//   - ReminderTrack: the protocol concrete tracks conform to
//   - Duration.seconds: convenience for treating Swift's Duration as a TimeInterval
//
// Used by:
//   - ReminderCoordinator and GroupingEngine (consume the protocol)
//   - BreakTrack (conforms)
//   - Every UI controller (renders ReminderContent)
//
// Swift concepts a learner will see here:
//   - `nonisolated` on protocol members: opts the requirement out of the
//     project's default MainActor isolation, so the actor-isolated coordinator
//     can read these properties without an `await`.
//   - protocol with associated requirements but no associated types: just an
//     interface — implementers must provide all listed members.
//   - `extension Duration`: Swift's standard `Duration` type is generic over
//     its precision; we slice off a Double `seconds` view for convenience.

/// How loud a reminder is allowed to be when it surfaces. The coordinator
/// uses `priority` to resolve conflicts: if a higher-priority track wants to
/// fire while a lower-priority one is showing, the new one preempts the old.
///
/// - Note: Currently a single case. The enum is kept around (rather than
///   collapsed to nothing) because a future long-break track will introduce
///   distinct interruption semantics; earlier versions also exposed
///   `.prominentCard`, `.banner`, `.menuBarPulse`, and `.soundOnly`, all of
///   which were cut as their corresponding features were removed.
nonisolated enum InterruptionLevel: Sendable, Equatable {
    case overlay         // full-screen, modal — short break, future long break

    /// Higher value = more important. Used by `ReminderCoordinator.tryShow`
    /// to decide whether a new firing preempts the current one or gets
    /// deferred.
    var priority: Int {
        switch self {
        case .overlay: 100
        }
    }
}

/// The user-visible payload of a single reminder firing. Tracks build one of
/// these via `makeContent()` when it's their turn to present. Carries enough
/// metadata for UI handlers to render the surface without reaching back into
/// the track itself.
///
/// `Sendable` + value-type: safe to pass freely from the actor-isolated
/// coordinator to the MainActor UI layer without copying penalties beyond
/// strings.
nonisolated struct ReminderContent: Sendable, Equatable {
    let trackID: String
    let title: String
    let body: String?
    let interruption: InterruptionLevel
    let duration: Duration
    /// Optional system-sound name (e.g. "Glass") to play on firing start.
    /// `BreakSoundPlayer` reads this for overlay-level firings; nil = silent.
    let soundName: String?

    // We define an explicit init only to give `soundName` a default value
    // of nil. The auto-synthesized memberwise initializer would require
    // every existing call site to pass soundName explicitly, which would
    // churn a lot of files for one new optional field.
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

/// Common interface for every kind of reminder track. Tracks are stateless
/// value types — they describe configuration (interval, duration, content),
/// not running state. The coordinator owns scheduling state separately
/// (`nextFireDates`, `currentlyShowing`).
///
/// Example conformer:
/// ```swift
/// struct BreakTrack: ReminderTrack {
///     let id = "break.short"
///     let displayName = "Short Break"
///     let interval = Duration.seconds(25 * 60)
///     let duration = Duration.seconds(5 * 60)
///     let interruption: InterruptionLevel = .overlay
///     ...
/// }
/// ```
///
/// - Note: All requirements are `nonisolated` because the project default is
///   `@MainActor`-everything. Without that opt-out, an `actor` like
///   `ReminderCoordinator` couldn't synchronously read a track's interval —
///   it would have to hop to the main actor for every property access.
protocol ReminderTrack: Sendable {
    nonisolated var id: String { get }
    nonisolated var displayName: String { get }
    nonisolated var interval: Duration { get }
    nonisolated var duration: Duration { get }
    nonisolated var interruption: InterruptionLevel { get }
    /// True if this track can be merged with other groupable tracks that
    /// happen to be due nearby. See `GroupingEngine`.
    nonisolated var isGroupable: Bool { get }
    /// Build the `ReminderContent` the coordinator should hand to the UI
    /// layer when this track fires.
    nonisolated func makeContent() -> ReminderContent
}

extension Duration {
    /// Treat the `Duration` as a real-number count of seconds. Loses precision
    /// past nanoseconds, but `TimeInterval` (a typealias for Double) is what
    /// all of our timer / scheduling code uses, so the conversion lives here
    /// to keep call sites readable.
    ///
    /// Swift's `Duration.components` returns `(seconds: Int64, attoseconds: Int64)`.
    /// We add them together at Double precision; 10^18 is the
    /// attoseconds-per-second conversion factor.
    nonisolated var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
