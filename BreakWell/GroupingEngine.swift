import Foundation

/// Decides which `ReminderTrack`s should fire together at the current moment.
/// Groupable tracks whose next-fire times fall within a configurable window
/// are merged into a single firing — turning what would be multiple separate
/// interruptions into one.
///
/// With one track running, this is effectively a no-op (returns either that
/// track or nothing). The real action begins once multiple groupable tracks
/// coexist (milestone 4).
nonisolated struct GroupingEngine: Sendable {
    nonisolated var window: Duration
    nonisolated var enabled: Bool

    nonisolated init(window: Duration = .seconds(180), enabled: Bool = true) {
        self.window = window
        self.enabled = enabled
    }

    /// Returns the tracks to fire together right now. Empty array = nothing due.
    /// The order matters: first element is the "primary" — its `interruption`
    /// level determines the firing mode (e.g. overlay vs banner).
    nonisolated func tracksToFire(
        now: Date,
        tracks: [any ReminderTrack],
        nextFireDates: [String: Date]
    ) -> [any ReminderTrack] {
        let due = tracks
            .filter { (nextFireDates[$0.id] ?? .distantFuture) <= now }
            .sorted { (nextFireDates[$0.id] ?? .distantFuture) < (nextFireDates[$1.id] ?? .distantFuture) }

        guard let primary = due.first else { return [] }

        // Non-groupable tracks always fire alone. Same when grouping is off.
        if !primary.isGroupable || !enabled {
            return [primary]
        }

        // Pull in any other groupable tracks that are also currently due.
        let alsoDue = due.dropFirst().filter { $0.isGroupable }
        return [primary] + alsoDue

        // TODO (milestone 4): if a groupable track will be due within `window`
        // but isn't yet, defer the primary by up to `window/2` to wait for it.
        // This is the "combine nearby firings" behavior the spec wants.
    }
}
