import Foundation

/// Observes the coordinator and shows/hides the break overlay as phase changes.
/// Triggers on `.firing` with `.overlay` interruption level only.
@MainActor
final class OverlayPresenter {
    private let coordinator: ReminderCoordinator
    private let controller: BreakOverlayController
    private var observationTask: Task<Void, Never>?
    private var isShowing = false

    init(coordinator: ReminderCoordinator) {
        self.coordinator = coordinator
        self.controller = BreakOverlayController(
            onSkip: {
                Task { await coordinator.skipBreak() }
            },
            onExtend: {
                Task { await coordinator.extendCurrentBreak(by: 300) } // +5 min
            }
        )
    }

    func start() {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self] in
            guard let coordinator = self?.coordinator else { return }
            let stream = await coordinator.phaseStream()
            for await phase in stream {
                self?.handle(phase)
            }
        }
    }

    private func handle(_ phase: CoordinatorPhase) {
        switch phase {
        case .firing(let remaining, let content) where content.interruption == .overlay:
            if isShowing {
                controller.update(remaining: remaining)
            } else {
                controller.show(remaining: remaining, message: BreakMessages.random())
                isShowing = true
            }
        default:
            if isShowing {
                controller.hide()
                isShowing = false
            }
        }
    }
}
