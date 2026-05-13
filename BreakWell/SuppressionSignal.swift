import Foundation

/// A source of "should we pause break reminders right now?" truth.
/// Each signal owns its detection logic and notifies the engine via `stateDidChange`
/// whenever its `isActive` flips. The engine OR-composes all signals.
@MainActor
protocol SuppressionSignal: AnyObject {
    var isActive: Bool { get }
    var reason: String { get }
    /// Each access returns a fresh stream that yields whenever `isActive` toggles.
    var stateDidChange: AsyncStream<Void> { get }
}
