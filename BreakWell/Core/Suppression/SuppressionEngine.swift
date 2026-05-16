import Foundation

// MARK: - SuppressionEngine
//
// Purpose: Reads a fixed list of SuppressionSignal instances and publishes
// a single boolean ("is anything suppressing right now?") + the first
// active signal's reason string.
//
// Architecture role: The "OR" between independent signals and the
// coordinator. Subscribes to each signal's `stateDidChange`, debounces
// bursts, and emits a SuppressionState whenever the composite changes.
//
// Key types defined:
//   - SuppressionState: the composite output (isActive + optional reason)
//   - SuppressionEngine: the actual class
//
// Used by:
//   - BreakWellApp (constructs it, hands its stream to the coordinator)
//   - ReminderCoordinator (consumes stream(), updates its suppressed flag)
//   - SchedulerViewModel (observes state to render "Paused — ..." in the popover)
//
// Swift concepts a learner will see here:
//   - Debouncing via cancellable Task: each new signal change cancels the
//     pending recompute and schedules a fresh one. After 200ms of quiet, we
//     actually fire. This coalesces rapid bursts (common with the
//     workspace-app-activation flood you get when cmd-tabbing).

/// Composed output of all signals: are we suppressed, and if so, why.
///
/// `Sendable` value type so it can cross actor boundaries freely
/// (engine is MainActor; coordinator is its own actor).
struct SuppressionState: Sendable, Equatable {
    let isActive: Bool
    let reason: String?

    /// Convenient default — useful as a starting value before any signal
    /// has reported in.
    static let inactive = SuppressionState(isActive: false, reason: nil)
}

/// OR-composes an array of `SuppressionSignal` into a single
/// `SuppressionState`. Subscribes to each signal's `stateDidChange`,
/// debounces, and republishes through its own AsyncStream.
///
/// Example usage:
/// ```swift
/// let engine = SuppressionEngine(signals: [manualPause, idle, meeting])
/// engine.start()
/// for await state in engine.stream() {
///     await coordinator.setSuppressed(state.isActive)
/// }
/// ```
///
/// - Note: `@MainActor` because every signal is also MainActor — keeping
///   the engine on the same actor avoids cross-actor hops for every read.
@MainActor
final class SuppressionEngine {
    private(set) var state: SuppressionState = .inactive

    private let signals: [SuppressionSignal]
    /// One per-signal observation task, kept so we can cancel them if we
    /// ever add a `stop()` (and so they aren't garbage-collected mid-loop).
    private var observationTasks: [Task<Void, Never>] = []
    /// Subscribers to our composite stream, keyed by UUID so onTermination
    /// can prune them individually.
    private var continuations: [UUID: AsyncStream<SuppressionState>.Continuation] = [:]

    /// Coalesce bursts of signal changes — battery matters for an
    /// always-running app. Without this, a single cmd-tab between apps
    /// can flood `recompute()` calls when multiple signals respond.
    private var debounceTask: Task<Void, Never>?
    private let debounceMilliseconds: Int = 200

    init(signals: [SuppressionSignal]) {
        self.signals = signals
    }

    /// Subscribe to every signal and start emitting composite state.
    /// Idempotent: calling twice is a no-op.
    func start() {
        guard observationTasks.isEmpty else { return }
        // Emit an initial composite immediately so subscribers don't sit
        // at `.inactive` until a signal happens to flip.
        recompute()
        for signal in signals {
            let stream = signal.stateDidChange
            // One Task per signal; each one drains the signal's stream
            // forever (or until the engine deallocates). `[weak self]` so
            // the task doesn't keep the engine alive past its natural life.
            let task = Task { [weak self] in
                for await _ in stream {
                    self?.scheduleRecompute()
                }
            }
            observationTasks.append(task)
        }
    }

    /// AsyncStream of state changes. Yields the current state on subscribe
    /// so consumers don't have to query `state` separately.
    func stream() -> AsyncStream<SuppressionState> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(state)
            // Clean up when the consumer goes away — the dict would otherwise
            // grow forever as views are created/destroyed.
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.continuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// Debounced re-evaluation. Each call cancels the previous pending one,
    /// so a burst of signal changes collapses into a single `recompute()`
    /// after the burst dies down.
    private func scheduleRecompute() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounceMilliseconds] in
            try? await Task.sleep(for: .milliseconds(debounceMilliseconds))
            // Cancellation is the normal exit path — bail before recomputing.
            guard !Task.isCancelled else { return }
            self?.recompute()
        }
    }

    private func recompute() {
        // Pick the first active signal for the reason. Order of the `signals`
        // array therefore defines priority — manual pause first, idle last.
        let firstActive = signals.first(where: { $0.isActive })
        let newState = SuppressionState(
            isActive: firstActive != nil,
            reason: firstActive?.reason
        )
        // Skip the broadcast if nothing changed — avoids pointless re-renders
        // and downstream coordinator hops.
        guard newState != state else { return }
        state = newState
        for cont in continuations.values { cont.yield(newState) }
    }
}
