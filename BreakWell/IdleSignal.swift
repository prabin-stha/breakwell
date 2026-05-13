import Foundation
import CoreGraphics

/// Replaces phase 1's `IdleDetector`. Polls system idle time via `CGEventSource`
/// and flips `isActive` when the user has been idle for `threshold` seconds.
@MainActor
@Observable
final class IdleSignal: SuppressionSignal {
    private(set) var isActive: Bool = false
    var reason: String { "Away from computer" }

    private let threshold: TimeInterval
    private let pollInterval: TimeInterval
    private var task: Task<Void, Never>?
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

    init(thresholdSeconds: TimeInterval = 120, pollInterval: TimeInterval = 10) {
        self.threshold = thresholdSeconds
        self.pollInterval = pollInterval
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                let interval = self?.pollInterval ?? 10
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func poll() {
        // ~UInt32(0) is the documented "any input event" sentinel (kCGAnyInputEventType).
        guard let anyEvent = CGEventType(rawValue: ~UInt32(0)) else { return }
        let idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
        let nowIdle = idleSeconds >= threshold
        guard nowIdle != isActive else { return }
        isActive = nowIdle
        for cont in continuations.values { cont.yield() }
    }
}
