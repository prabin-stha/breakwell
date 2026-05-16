import Foundation
import CoreGraphics

// MARK: - IdleSignal
//
// Purpose: Detects "user is away from their computer" by polling the system's
// idle-time counter. Flips active after N seconds of no input.
//
// Architecture role: A SuppressionSignal conformer in Core/Suppression. Sits
// next to the other signals.
//
// Key types defined:
//   - IdleSignal: @Observable @MainActor class
//
// Used by:
//   - BreakWellApp (constructs and starts it)
//   - SuppressionEngine (subscribes to stateDidChange)
//
// Depends on:
//   - CoreGraphics for CGEventSource (Apple's low-level event/idle API)
//
// Swift concepts a learner will see here:
//   - @Observable: SwiftUI's modern observation system. Reading a property
//     of an @Observable type inside a view body subscribes that view to
//     the property; mutations re-render the view automatically.
//   - @ObservationIgnored: opt a stored property out of @Observable tracking.
//     Used for the continuation dict, which isn't UI-visible.

/// Polls system idle time via `CGEventSource` and flips `isActive` when the
/// user has been idle for `threshold` seconds.
///
/// We poll rather than listen for events because the OS doesn't push a
/// "user just stopped touching things" notification — you have to ask.
/// 10-second polling is enough granularity for a 2-minute idle threshold
/// and costs essentially nothing.
///
/// Apple docs: see `CGEventSource.secondsSinceLastEventType(_:eventType:)`.
@MainActor
@Observable
final class IdleSignal: SuppressionSignal {
    private(set) var isActive: Bool = false
    var reason: String { "Away from computer" }

    private let threshold: TimeInterval
    private let pollInterval: TimeInterval
    private var task: Task<Void, Never>?

    // The continuation dict isn't part of any view's render; opt it out of
    // observation so we don't churn invalidations every time someone subscribes.
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
        // Long-running poll task. `[weak self]` so the task can't outlive
        // the signal — important if we ever support hot-reloading signals.
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                let interval = self?.pollInterval ?? 10
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func poll() {
        // `~UInt32(0)` is the documented sentinel for "any input event"
        // (kCGAnyInputEventType from Apple's C headers). The CGEventType
        // Swift wrapper doesn't expose a named constant for it, so we
        // construct it from the raw value.
        guard let anyEvent = CGEventType(rawValue: ~UInt32(0)) else { return }
        // .combinedSessionState includes both window-server events and HID
        // events — covers mouse, keyboard, trackpad, and any other input.
        let idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
        let nowIdle = idleSeconds >= threshold
        // Only fire stateDidChange on an actual transition; the engine's
        // debounce would coalesce duplicates anyway, but every yield costs
        // something and silent polls shouldn't pay that.
        guard nowIdle != isActive else { return }
        isActive = nowIdle
        for cont in continuations.values { cont.yield() }
    }
}
