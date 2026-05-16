import Foundation
import Observation

// MARK: - SchedulerViewModel
//
// Purpose: The bridge between SwiftUI's main-actor observation world and
// the actor-isolated `ReminderCoordinator` + `SuppressionEngine`. Mirrors
// their published streams into `@Observable` properties that views can
// read directly.
//
// Architecture role: View model in the MVVM sense. Owns no business logic
// — it consumes AsyncStreams from below and exposes property reads + a
// few command methods (`takeBreakNow`, `pauseForHour`, `resume`) to the
// view above.
//
// Why a view model is needed here:
// `ReminderCoordinator` is an `actor`, so its properties can't be read
// synchronously from a SwiftUI body. `SuppressionEngine` is @MainActor
// but emits state changes via an AsyncStream rather than @Observable
// directly. Either way, views need a main-actor `@Observable` shim that
// updates as the underlying streams emit — that's this class.
//
// Key types defined:
//   - SchedulerViewModel: @MainActor @Observable class
//
// Used by:
//   - BreakWellApp (constructs and calls startObserving())
//   - MenuBarView (reads phase/suppression, calls commands)
//
// Swift concepts a learner will see here:
//   - `@Observable` + `private(set)`: observed properties still re-render
//     the view when changed; private(set) just prevents writes from outside.
//   - `@ObservationIgnored`: opt a property out of observation. Tasks are
//     plumbing — views have no reason to react to their existence — so we
//     skip the observation overhead.
//   - `for await … in stream`: structured concurrency's stream consumption.
//     The loop suspends until the next value, then assigns to the property,
//     which automatically triggers SwiftUI re-renders.
//   - `Task { [weak self] in … }` capturing both `self` (weak) and the
//     coordinator (strong via local binding): lets the task survive briefly
//     even if `self` is released, but cleanly bails when `self` is gone.
//   - `Task { [coordinator] in await coordinator.takeBreakNow() }`:
//     fire-and-forget command into the actor. Capturing the coordinator by
//     value (it's a reference) sidesteps `self` capture entirely.

/// View model exposed to `MenuBarView`. Mirrors the coordinator's phase and
/// the suppression engine's state into observable properties.
///
/// Call `startObserving()` once at app start to begin the stream loops.
/// The loops live for the lifetime of the view model.
@MainActor
@Observable
final class SchedulerViewModel {
    /// Current scheduler phase. Drives the status row's symbol + text.
    private(set) var phase: CoordinatorPhase = .working(remaining: 0)
    /// Current suppression state (paused / firing-suppressed / inactive).
    private(set) var suppression: SuppressionState = .inactive

    /// Exposed so the view can read `isActive` directly to toggle the
    /// Pause/Resume button without an extra mirrored property.
    let manualPauseSignal: ManualPauseSignal

    private let coordinator: ReminderCoordinator
    private let engine: SuppressionEngine
    // These tasks aren't UI-relevant; opt them out of observation so SwiftUI
    // doesn't waste time tracking changes that no view reads.
    @ObservationIgnored private var phaseTask: Task<Void, Never>?
    @ObservationIgnored private var suppressionTask: Task<Void, Never>?

    init(coordinator: ReminderCoordinator, engine: SuppressionEngine, manualPauseSignal: ManualPauseSignal) {
        self.coordinator = coordinator
        self.engine = engine
        self.manualPauseSignal = manualPauseSignal
    }

    /// Start the two stream-consumption tasks. Idempotent — calling twice
    /// is a no-op thanks to the `phaseTask == nil` guard.
    func startObserving() {
        guard phaseTask == nil else { return }
        // Phase stream lives behind the actor, so getting it is itself an
        // await. Once we have the AsyncStream, iteration is non-isolated.
        phaseTask = Task { [weak self] in
            guard let coordinator = self?.coordinator else { return }
            let stream = await coordinator.phaseStream()
            for await newPhase in stream {
                // Assignment on @MainActor self — Swift's actor checking
                // ensures we're back on the main actor for this write.
                self?.phase = newPhase
            }
        }
        suppressionTask = Task { [weak self] in
            guard let engine = self?.engine else { return }
            let stream = engine.stream()
            for await newState in stream {
                self?.suppression = newState
            }
        }
    }

    // MARK: - Commands

    /// "Take break now" — fire-and-forget command into the actor. We don't
    /// await because the view's button handler is synchronous and the
    /// coordinator handles the rest internally.
    func takeBreakNow() {
        Task { [coordinator] in await coordinator.takeBreakNow() }
    }

    /// Pause for one hour. ManualPauseSignal is @MainActor, so this is a
    /// plain synchronous call — no Task needed.
    func pauseForHour() {
        manualPauseSignal.pause(for: 60 * 60)
    }

    func resume() {
        manualPauseSignal.clear()
    }
}
