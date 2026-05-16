import AppKit

// MARK: - BreakSoundPlayer
//
// Purpose: Plays a soft chime on overlay-level firing start and end. Uses
// built-in macOS system sounds (Glass, Hero, …) so we don't have to bundle
// audio files.
//
// Architecture role: A long-lived service that observes the coordinator's
// phase stream and reacts to specific transitions. Doesn't render UI;
// doesn't manage windows.
//
// Key types defined:
//   - BreakSoundPlayer: @MainActor class
//
// Used by:
//   - BreakWellApp (constructs and starts)
//
// Depends on:
//   - AppKit's NSSound for the built-in system sounds. Apple ships a
//     handful of named sounds at /System/Library/Sounds — those are what
//     `NSSound(named: ...)` looks up.
//
// Swift concepts a learner will see here:
//   - defer block: runs the supplied code when the enclosing scope exits.
//     Used here to ensure `wasFiring` is updated even if we take an early
//     return out of `handle(_:)` via the soundEnabled guard.

/// Plays a soft chime on overlay-level firing start/end. Uses built-in
/// macOS system sounds (no bundled audio file needed). Gated by
/// `Settings.soundEnabled`.
///
/// The "edge" detection (only chime on TRANSITION, not on every tick) is
/// what `wasFiring` is for. Without it, the player would re-trigger the
/// start sound every second of the firing.
@MainActor
final class BreakSoundPlayer {
    private let coordinator: ReminderCoordinator
    private let settings: Settings
    private var observationTask: Task<Void, Never>?
    /// "Were we in an overlay firing at the previous phase?" — used to
    /// detect edges between firing and not-firing.
    private var wasFiring = false

    init(coordinator: ReminderCoordinator, settings: Settings) {
        self.coordinator = coordinator
        self.settings = settings
    }

    func start() {
        guard observationTask == nil else { return }
        // Subscribe to the coordinator's phase stream forever.
        observationTask = Task { [weak self] in
            guard let coordinator = self?.coordinator else { return }
            let stream = await coordinator.phaseStream()
            for await phase in stream {
                self?.handle(phase)
            }
        }
    }

    private func handle(_ phase: CoordinatorPhase) {
        // Only chime for overlay-level firings; banner-level reminders
        // bring their own sound via the controller.
        let firingContent: ReminderContent?
        if case .firing(_, let content) = phase, content.interruption == .overlay {
            firingContent = content
        } else {
            firingContent = nil
        }
        let isFiringOverlay = firingContent != nil
        // `defer` runs when the function exits — including via the
        // soundEnabled early-return below. That guarantees wasFiring stays
        // in sync no matter which branch we take.
        defer { wasFiring = isFiringOverlay }
        guard settings.soundEnabled else { return }
        if let firingContent, !wasFiring {
            // Edge: not firing → firing. Play the track's start sound,
            // falling back to a sensible default if none was specified.
            let name = firingContent.soundName ?? "Glass"
            NSSound(named: name)?.play()
        } else if !isFiringOverlay && wasFiring {
            // Edge: firing → not firing. End sound is fixed for now; could
            // also be moved into BreakContent later.
            NSSound(named: "Hero")?.play()
        }
    }
}
