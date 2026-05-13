import Foundation

/// User-initiated pause with an optional auto-clear time. Replaces phase 1's
/// `.paused(until:)` BreakScheduler phase — manual pause is now a suppression
/// signal, not a scheduler state.
@MainActor
@Observable
final class ManualPauseSignal: SuppressionSignal {
    private(set) var isActive: Bool = false
    private(set) var until: Date?

    var reason: String {
        guard let until else { return "Paused" }
        return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
    }

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

    func pause(for duration: TimeInterval) {
        pause(until: Date().addingTimeInterval(duration))
    }

    func pause(until date: Date) {
        let wasActive = isActive
        self.until = date
        isActive = true
        clearTask?.cancel()
        let delay = date.timeIntervalSinceNow
        if delay <= 0 {
            clear()
            return
        }
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.clear()
        }
        if !wasActive {
            notify()
        }
    }

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
