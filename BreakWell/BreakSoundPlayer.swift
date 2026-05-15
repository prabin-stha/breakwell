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
        let firingContent: ReminderContent?
        if case .firing(_, let content) = phase, content.interruption == .overlay {
            firingContent = content
        } else {
            firingContent = nil
        }
        let isFiringOverlay = firingContent != nil
        defer { wasFiring = isFiringOverlay }
        guard settings.soundEnabled else { return }
        if let firingContent, !wasFiring {
            // Track-specified start sound, falling back to system Glass.
            let name = firingContent.soundName ?? "Glass"
            NSSound(named: name)?.play()
        } else if !isFiringOverlay && wasFiring {
            NSSound(named: "Hero")?.play()
        }
    }
}
