import AppKit

/// Plays a soft chime on overlay-level firing start/end. Uses built-in macOS
/// system sounds (no bundled audio file needed). Gated by Settings.soundEnabled.
@MainActor
final class BreakSoundPlayer {
    private let coordinator: ReminderCoordinator
    private let settings: Settings
    private var observationTask: Task<Void, Never>?
    private var wasFiring = false

    init(coordinator: ReminderCoordinator, settings: Settings) {
        self.coordinator = coordinator
        self.settings = settings
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
        // Only chime for overlay-level firings; banner-level reminders bring their own sound.
        let isFiringOverlay: Bool
        if case .firing(_, let content) = phase, content.interruption == .overlay {
            isFiringOverlay = true
        } else {
            isFiringOverlay = false
        }
        defer { wasFiring = isFiringOverlay }
        guard settings.soundEnabled else { return }
        if isFiringOverlay && !wasFiring {
            NSSound(named: "Glass")?.play()
        } else if !isFiringOverlay && wasFiring {
            NSSound(named: "Hero")?.play()
        }
    }
}
