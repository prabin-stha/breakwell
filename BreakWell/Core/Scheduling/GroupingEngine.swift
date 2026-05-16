import Foundation

// MARK: - GroupingEngine
//
// Purpose: Decides which due tracks should fire together when more than one
// could fire at the same moment. Today it just returns the due tracks
// straight through; the future plan is to defer a primary track by a small
// window so a nearby second track can join it as one combined surface.
//
// Architecture role: Pure value-type helper consumed by the coordinator. No
// state — the coordinator passes in the current snapshot, the engine
// returns a decision.
//
// Key types defined:
//   - GroupingEngine: the struct itself
//
// Used by:
//   - ReminderCoordinator.tick (asks "what should fire now?")
//
// Swift concepts a learner will see here:
//   - `nonisolated struct`: explicitly opted out of the project's default
//     MainActor isolation so the actor-isolated coordinator can call it
//     synchronously.
//   - `[any ReminderTrack]`: an array of "existential" values — anything
//     that conforms to ReminderTrack, possibly of different concrete types.
//   - `dropFirst()`: returns a lazy slice excluding the first element.

/// Stateless helper that decides which groupable tracks should fire together.
///
/// The intent is to turn "eye-rest fires at 12:00 and water at 12:01" into a
/// single combined firing, so the user sees one interruption instead of two
/// in quick succession. With only one track due at a time, this is a no-op
/// passthrough; the merging logic stays simple until multiple groupable
/// tracks routinely overlap.
///
/// - Note: The returned array's first element is the "primary" — its
///   interruption level decides the firing's UI mode.
nonisolated struct GroupingEngine: Sendable {
    nonisolated var window: Duration
    nonisolated var enabled: Bool

    nonisolated init(window: Duration = .seconds(180), enabled: Bool = true) {
        self.window = window
        self.enabled = enabled
    }

    /// Returns the tracks that should fire right now as one combined surface.
    /// An empty array means nothing is due.
    ///
    /// Algorithm today:
    ///  1. Filter the tracks whose `nextFireDate` is in the past.
    ///  2. Sort earliest-due first (the "primary").
    ///  3. If the primary isn't groupable (or grouping is off), return it alone.
    ///  4. Otherwise also collect any other due groupable tracks.
    ///
    /// The TODO at the bottom is the planned "look ahead" behavior — if a
    /// groupable track will be due within `window` but isn't yet, hold the
    /// primary for up to `window/2` so the two can fire together.
    nonisolated func tracksToFire(
        now: Date,
        tracks: [any ReminderTrack],
        nextFireDates: [String: Date]
    ) -> [any ReminderTrack] {
        let due = tracks
            // `nil-coalesce to distantFuture` means "if no fire date is set,
            // never consider this track due" — a defensive default.
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

        // TODO: if a groupable track will be due within `window` but isn't
        // yet, defer the primary by up to `window/2` to wait for it. That's
        // the "combine nearby firings" behavior the architecture spec wants.
    }
}
