import Foundation

// MARK: - SuppressionSignal
//
// Purpose: Defines the protocol every "should reminders be paused right now?"
// detector implements. The engine OR-composes a list of these and publishes
// the result.
//
// Architecture role: Core/Suppression entry point. The protocol is the only
// abstraction here — concrete detectors (idle, meeting, media, etc.) live
// next to this file and conform to it.
//
// About the Core/Suppression folder:
// Suppression signals answer one question: "is there a good reason NOT to
// interrupt the user right now?" Each signal is independent and detects its
// own situation (you're in a meeting / a recording app is open / you're
// idle / you manually paused). The SuppressionEngine ORs them together; if
// any signal is active, breaks get held or deferred.
//
// Signals should be small and self-contained. They observe one source of
// truth (an OS notification, a poll, a user action) and flip a boolean.
// They do NOT decide what to do with the suppression — that's the
// coordinator's job. They publish; the engine and coordinator subscribe.
//
// Key types defined:
//   - SuppressionSignal: the protocol every detector conforms to
//
// Used by:
//   - SuppressionEngine (composes a list of these)
//   - BreakWellApp (constructs the concrete signals)
//
// Swift concepts a learner will see here:
//   - @MainActor on a protocol: every conformer must be MainActor-isolated.
//     Lets us safely read `isActive` from SwiftUI views without `await`.
//   - AnyObject constraint: restricts conformers to classes. Needed because
//     the engine holds them by reference and wires up observation tasks per
//     instance — value semantics wouldn't work here.

/// A source of "should we pause break reminders right now?" truth.
///
/// Each signal owns its detection logic and notifies the engine via
/// `stateDidChange` whenever its `isActive` flips. The engine OR-composes
/// every signal — if any one is active, the engine reports the user as
/// suppressed, and the coordinator holds back any due breaks.
///
/// Conformers should:
///   - Flip `isActive` only when something real changes (not on every poll).
///   - Provide a short `reason` string the UI can show ("In Zoom",
///     "Recording in OBS", "Paused until 4:00 PM").
///   - Yield to `stateDidChange` exactly once per actual state change.
///
/// - Note: `@MainActor` on the protocol means all conformers must also be
///   `@MainActor`. We do that on purpose — every signal reaches into AppKit
///   or other main-thread APIs, and centralizing them on the main actor
///   removes a lot of `await` ceremony.
@MainActor
protocol SuppressionSignal: AnyObject {
    /// Latest reading of "is this signal firing right now?".
    var isActive: Bool { get }

    /// Human-readable reason the signal is active. Surfaced in the popover
    /// ("Paused until 5:30 PM") and in the Diagnostics tab.
    var reason: String { get }

    /// AsyncStream that yields a `Void` value each time `isActive` toggles.
    /// Each property access returns a fresh stream — implementers typically
    /// keep a list of continuations and broadcast to all of them.
    var stateDidChange: AsyncStream<Void> { get }
}
