import Foundation

/// Observes the coordinator and shows/hides the break overlay as phase changes.
/// Triggers on `.firing` with `.overlay` interruption level only.
@MainActor
final class OverlayPresenter {
    private let coordinator: ReminderCoordinator
    private let breakContent: BreakContent
    private let controller: BreakOverlayController
    private var observationTask: Task<Void, Never>?
    private var isShowing = false

    init(coordinator: ReminderCoordinator, breakContent: BreakContent = .eyeRest) {
        self.coordinator = coordinator
        self.breakContent = breakContent
        self.controller = BreakOverlayController(
            onSkip: {
                Task { await coordinator.skipBreak() }
            },
            onExtend: { seconds in
                Task { await coordinator.extendCurrentBreak(by: seconds) }
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
                controller.show(
                    remaining: remaining,
                    content: breakContent,
                    message: breakContent.randomMessage()
                )
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
