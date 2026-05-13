import Foundation

/// Composed output of all signals: are we suppressed, and if so, why.
struct SuppressionState: Sendable, Equatable {
    let isActive: Bool
    let reason: String?

    static let inactive = SuppressionState(isActive: false, reason: nil)
}

/// OR-composes an array of `SuppressionSignal` into a single `SuppressionState`.
/// Subscribes to each signal's `stateDidChange`, debounces, and republishes.
@MainActor
final class SuppressionEngine {
    private(set) var state: SuppressionState = .inactive

    private let signals: [SuppressionSignal]
    private var observationTasks: [Task<Void, Never>] = []
    private var continuations: [UUID: AsyncStream<SuppressionState>.Continuation] = [:]

    /// Coalesce bursts of signal changes — battery matters for an always-running app.
    private var debounceTask: Task<Void, Never>?
    private let debounceMilliseconds: Int = 200

    init(signals: [SuppressionSignal]) {
        self.signals = signals
    }

    func start() {
        guard observationTasks.isEmpty else { return }
        recompute()
        for signal in signals {
            let stream = signal.stateDidChange
            let task = Task { [weak self] in
                for await _ in stream {
                    self?.scheduleRecompute()
                }
            }
            observationTasks.append(task)
        }
    }

    /// AsyncStream of state changes. Yields current state on subscribe.
    func stream() -> AsyncStream<SuppressionState> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.continuations.removeValue(forKey: id)
                }
            }
        }
    }

    private func scheduleRecompute() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounceMilliseconds] in
            try? await Task.sleep(for: .milliseconds(debounceMilliseconds))
            guard !Task.isCancelled else { return }
            self?.recompute()
        }
    }

    private func recompute() {
        // Pick the first active signal for the reason. Order of `signals` array
        // therefore defines priority — manual pause before idle, etc.
        let firstActive = signals.first(where: { $0.isActive })
        let newState = SuppressionState(
            isActive: firstActive != nil,
            reason: firstActive?.reason
        )
        guard newState != state else { return }
        state = newState
        for cont in continuations.values { cont.yield(newState) }
    }
}
