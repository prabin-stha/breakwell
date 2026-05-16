import Foundation

// MARK: - ManualPauseSignal
//
// Purpose: User-initiated pause. The "Pause for 1 hour" menu-bar button
// flips this on; it auto-clears when the deadline passes (or the user
// hits Resume).
//
// Architecture role: A SuppressionSignal in Core/Suppression. Has the
// highest priority in the engine's ordered signal list — when both manual
// and idle are active, "Paused until 5:00 PM" wins as the reason string.
//
// Key types defined:
//   - ManualPauseSignal: @Observable @MainActor class
//
// Used by:
//   - BreakWellApp (constructs)
//   - SchedulerViewModel (calls pause(for:) / clear() from the popover)
//   - SuppressionEngine (subscribes to stateDidChange)
//
// Swift concepts a learner will see here:
//   - Date().formatted(date:time:) — Swift's Foundation date formatter API.
//     Locale-aware and faster than the older DateFormatter for one-offs.
//   - cancellable Task for auto-clear — same pattern used elsewhere; the
//     task waits the deadline, then clears the signal unless cancelled.

/// User-initiated pause with an optional auto-clear time. Replaces phase 1's
/// `.paused(until:)` BreakScheduler phase — manual pause is now a suppression
/// signal, not a scheduler state.
///
/// Example usage:
/// ```swift
/// // From the popover's "Pause for 1 hour" button:
/// manualPause.pause(for: 60 * 60)
///
/// // From the popover's "Resume" button:
/// manualPause.clear()
/// ```
@MainActor
@Observable
final class ManualPauseSignal: SuppressionSignal {
    private(set) var isActive: Bool = false
    /// The auto-clear deadline; nil if there isn't one. Exposed so the
    /// popover can show "Paused until 5:00 PM".
    private(set) var until: Date?

    var reason: String {
        guard let until else { return "Paused" }
        return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
    }

    // The auto-clear timer task — kept so we can cancel it if the user
    // explicitly resumes early.
    @ObservationIgnored private var clearTask: Task<Void, Never>?
    @ObservationIgnored private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    var stateDidChange: AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.continuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// Convenience: pause for a relative duration.
    func pause(for duration: TimeInterval) {
        pause(until: Date().addingTimeInterval(duration))
    }

    /// Pause until an absolute moment. Reuses the same auto-clear task slot —
    /// repauses cancel and re-schedule.
    func pause(until date: Date) {
        let wasActive = isActive
        self.until = date
        isActive = true
        clearTask?.cancel()
        let delay = date.timeIntervalSinceNow
        if delay <= 0 {
            // Defensive: pausing until a time in the past is a no-op pause.
            clear()
            return
        }
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.clear()
        }
        // Only notify subscribers on an actual off→on transition; a repause
        // doesn't change the signal's overall on/off state.
        if !wasActive {
            notify()
        }
    }

    /// Resume immediately. Cancels any pending auto-clear and notifies
    /// subscribers if we were actually paused.
    func clear() {
        let wasActive = isActive
        isActive = false
        until = nil
        clearTask?.cancel()
        clearTask = nil
        if wasActive {
            notify()
        }
    }

    private func notify() {
        for cont in continuations.values { cont.yield() }
    }
}
