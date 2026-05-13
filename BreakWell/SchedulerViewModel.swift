import Foundation
import Observation

@MainActor
@Observable
final class SchedulerViewModel {
    private(set) var phase: CoordinatorPhase = .working(remaining: 0)
    private(set) var suppression: SuppressionState = .inactive

    let manualPauseSignal: ManualPauseSignal

    private let coordinator: ReminderCoordinator
    private let engine: SuppressionEngine
    @ObservationIgnored private var phaseTask: Task<Void, Never>?
    @ObservationIgnored private var suppressionTask: Task<Void, Never>?

    init(coordinator: ReminderCoordinator, engine: SuppressionEngine, manualPauseSignal: ManualPauseSignal) {
        self.coordinator = coordinator
        self.engine = engine
        self.manualPauseSignal = manualPauseSignal
    }

    func startObserving() {
        guard phaseTask == nil else { return }
        phaseTask = Task { [weak self] in
            guard let coordinator = self?.coordinator else { return }
            let stream = await coordinator.phaseStream()
            for await newPhase in stream {
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

    func takeBreakNow() {
        Task { [coordinator] in await coordinator.takeBreakNow() }
    }

    func pauseForHour() {
        manualPauseSignal.pause(for: 60 * 60)
    }

    func resume() {
        manualPauseSignal.clear()
    }
}
