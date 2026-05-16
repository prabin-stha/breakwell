import Foundation
import Observation

// MARK: - BreakStats
//
// Purpose: Persistent counter for "how many breaks did I complete today?".
// Increments only on natural break completion (not skip, not preempt) so
// the number means something — skipping breaks doesn't inflate the count.
//
// Architecture role: Feature-level state for the break feature. Subscribed
// by the menu-bar popover for the "X breaks today" line. Driven by the
// coordinator's completionStream, wired by BreakWellApp at startup.
//
// Key types defined:
//   - BreakStats: @Observable @MainActor class
//   - BreakStats.Blob: private Codable struct for UserDefaults storage
//
// Used by:
//   - BreakWellApp (constructs; wires the completionStream subscription)
//   - MenuBarView (reads completedToday for the popover subtitle)
//
// Swift concepts a learner will see here:
//   - @Observable + private(set): properties stay tracked but can't be
//     assigned from outside. The increment goes through `recordCompletion()`.
//   - Codable blob in UserDefaults: one JSON value, one key, atomic from
//     readers' POV.
//   - static func computeAnchor: namespaced helper that doesn't need an
//     instance to run; the daily-reset math is part of the type's contract.

/// Persistent break-completion counter. Resets at `dailyResetHour` (default
/// 4am — well after typical sleep, so the count doesn't roll over at
/// midnight while someone's still working). Only naturally-completed breaks
/// increment — skip and preempt don't, so the displayed count is a real
/// signal, not just "how many times the overlay fired".
///
/// Example usage:
/// ```swift
/// let stats = BreakStats()
/// // ... when a break completes naturally:
/// stats.recordCompletion()
/// // ... read in the popover:
/// Text("\(stats.completedToday) breaks today")
/// ```
@MainActor
@Observable
final class BreakStats {
    private(set) var completedToday: Int = 0
    private(set) var dayAnchor: Date

    /// Hour of day (0–23) at which "today" resets. 4am by default — well
    /// after typical sleep so a late-night work session doesn't roll the
    /// count over at midnight.
    var dailyResetHour: Int = 4 {
        didSet { rollOverIfNeeded() }
    }

    private let defaults: UserDefaults
    private enum Keys {
        static let blob = "breakStats"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Initialize dayAnchor first so other methods can safely read it.
        self.dayAnchor = Self.computeAnchor(now: Date(), resetHour: 4)
        load()
        rollOverIfNeeded()
    }

    /// Increment the counter. Persists immediately so the new value
    /// survives app restarts and the menu-bar popover sees it on open.
    func recordCompletion() {
        rollOverIfNeeded()
        completedToday += 1
        save()
    }

    // MARK: - Day rollover

    /// If the current anchor moment is later than the stored one, the day
    /// has rolled over. Reset and persist.
    private func rollOverIfNeeded() {
        let current = Self.computeAnchor(now: Date(), resetHour: dailyResetHour)
        if current > dayAnchor {
            dayAnchor = current
            completedToday = 0
            save()
        }
    }

    /// Computes the most recent reset moment at or before `now`. If the
    /// reset hour is 4 and `now` is Tuesday 3am, the anchor is Monday 4am.
    /// If `now` is Tuesday 5am, it's Tuesday 4am. The Calendar API does the
    /// "set this hour, leave the day alone" bit; we then step back a day if
    /// we'd otherwise place the anchor in the future.
    private static func computeAnchor(now: Date, resetHour: Int) -> Date {
        let cal = Calendar.current
        let todayReset = cal.date(bySettingHour: resetHour, minute: 0, second: 0, of: now) ?? now
        if now < todayReset {
            return cal.date(byAdding: .day, value: -1, to: todayReset) ?? todayReset
        }
        return todayReset
    }

    // MARK: - Persistence (single JSON blob in UserDefaults)

    private struct Blob: Codable {
        let completedToday: Int
        let dayAnchor: Date
    }

    private func save() {
        let blob = Blob(completedToday: completedToday, dayAnchor: dayAnchor)
        if let data = try? JSONEncoder().encode(blob) {
            defaults.set(data, forKey: Keys.blob)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: Keys.blob),
              let blob = try? JSONDecoder().decode(Blob.self, from: data) else { return }
        completedToday = blob.completedToday
        dayAnchor = blob.dayAnchor
    }
}
