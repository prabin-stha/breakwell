import Foundation

// MARK: - AppTiming
//
// Purpose: One-line knob for compressing the app's minute-based durations
// when iterating on timing behavior. Switching it makes "30 minutes" in
// Settings act as 30 seconds at runtime — the rest of the codebase doesn't
// know whether it's in test or production mode.
//
// Architecture role: Core/Scheduling — the lowest layer in the app. No
// dependencies on anything else (not even Foundation types beyond
// TimeInterval). Imported anywhere that turns "minutes from a settings
// stepper" into a real duration.
//
// About the Core/Scheduling folder:
// This folder contains the logic that decides WHEN reminders fire — schedules,
// priority resolution, time conversions, and the coordinator that owns it
// all. Files here should be pure logic: no AppKit, no SwiftUI, nothing that
// pulls a window onto the screen. UI for those reminders lives in
// Features/Break and Features/Hydration. If you ever find yourself wanting
// to import AppKit in this folder, that's a sign the logic belongs elsewhere.
//
// Key types defined:
//   - AppTiming: the namespace holding `secondsPerMinute`
//   - Int.minutesAsSeconds: the extension every caller actually uses
//
// Used by:
//   - BreakWellApp (when constructing tracks)
//   - Settings (workDuration computed property)
//
// Swift concepts a learner will see here:
//   - enum used as a namespace: an `enum` with no cases is a common Swift
//     idiom for grouping static members without allowing instantiation.
//     You can't write `let t = AppTiming()` — there's nothing to construct.
//   - extension on a built-in type (Int): Swift lets you add methods and
//     computed properties to any type, even ones you didn't write. Useful
//     for making call sites read like prose: `30.minutesAsSeconds`.

/// One-place constant for the seconds-per-minute conversion used by every
/// minute-valued setting in the app. Leave at `60` for production. Change to
/// `1` to make "30 min" in Settings collapse to 30 real seconds — invaluable
/// for testing without waiting 20 minutes for a break to fire.
///
/// Anything that converts a user-entered "minutes" value to a real
/// `TimeInterval` should route through this constant via
/// `Int.minutesAsSeconds`.
enum AppTiming {
    // `static let` on a caseless enum behaves like a constant in a namespace.
    // `nonisolated` so non-main-actor callers (the `ReminderCoordinator`
    // actor reads this via `minutesAsSeconds`) can access it directly.
    nonisolated static let secondsPerMinute: TimeInterval = 1
}

/// Sugar on `Int` so call sites can read `settings.workMinutes.minutesAsSeconds`
/// instead of `TimeInterval(settings.workMinutes) * 60`.
///
/// The single extension point also makes the test-mode switch above effective
/// everywhere — there's no other multiplication scattered through the code.
extension Int {
    /// Treat `self` as a count of minutes and convert to seconds, scaled by
    /// `AppTiming.secondsPerMinute`.
    ///
    /// `nonisolated` so the actor-isolated `ReminderCoordinator` can call
    /// this synchronously. The math doesn't touch any shared state, so
    /// opting out of the project's default MainActor isolation is safe.
    nonisolated var minutesAsSeconds: TimeInterval {
        TimeInterval(self) * AppTiming.secondsPerMinute
    }
}
