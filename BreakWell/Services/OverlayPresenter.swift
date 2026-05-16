import Foundation

// MARK: - OverlayPresenter
//
// Purpose: Bridge between the coordinator's phase stream and the AppKit
// `BreakOverlayController`. Decides when to show/hide the fullscreen
// break overlay based on phase transitions.
//
// Architecture role: A stream consumer + window-controller-owner pair.
// Owns the controller's lifetime, hands it the right content on `.firing`,
// hides it on anything else.
//
// Key types defined:
//   - OverlayPresenter: @MainActor class
//
// Used by:
//   - BreakWellApp (constructs and calls start())
//
// Why this isn't folded into the coordinator: the coordinator is an actor
// — it doesn't know about windows. Presentation is a main-actor concern.
// This class is the seam between the two worlds.
//
// Swift concepts a learner will see here:
//   - Pattern matching with `where`: `case .firing(let remaining, let content)
//     where content.interruption == .overlay` only matches firings that
//     route to the overlay surface (not banners or prominent cards).
//   - Capture lists in init: the `onSkip` / `onSnooze` closures handed to
//     the controller capture `coordinator` by value, sidestepping `self`
//     entirely. They live for the controller's lifetime, which equals
//     ours, so capture by value is safe and avoids a cycle.
//   - `Task { await ... }` from a synchronous closure: the controller's
//     button handlers can't be async, so we wrap in a fire-and-forget Task.

/// Observes the coordinator and shows/hides the break overlay as phase
/// changes. Triggers on `.firing` with `.overlay` interruption level only
/// — other interruption levels are handled by different presenters
/// (banner, prominent card).
@MainActor
final class OverlayPresenter {
    private let coordinator: ReminderCoordinator
    private let breakContent: BreakContent
    private let controller: BreakOverlayController
    private var observationTask: Task<Void, Never>?
    /// Tracks whether the overlay window is currently visible so we can
    /// `update(remaining:)` vs `show(...)` correctly across ticks.
    private var isShowing = false

    init(coordinator: ReminderCoordinator, breakContent: BreakContent = .shortBreak) {
        self.coordinator = coordinator
        self.breakContent = breakContent
        // Construct the controller with capture-list closures that go
        // straight to the coordinator. Skipping `self` capture avoids any
        // retain-cycle concern (presenter → controller → closure → ?).
        self.controller = BreakOverlayController(
            onSkip: {
                Task { await coordinator.skipBreak() }
            },
            onSnooze: { seconds in
                Task { await coordinator.snoozeCurrentBreak(by: seconds) }
            }
        )
    }

    /// Begin observing the coordinator's phase stream. Idempotent.
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
        // The `where` clause filters out firings routed to other surfaces
        // (banner, prominentCard). Without it, we'd try to show the overlay
        // for a hydration firing — wrong surface.
        case .firing(let remaining, let content) where content.interruption == .overlay:
            if isShowing {
                // Already up — just update the countdown. Recreating the
                // window every tick would be wasteful and would re-trigger
                // entrance animations.
                controller.update(remaining: remaining)
            } else {
                // Pick a fresh random message per break so users don't
                // see the same copy every time.
                controller.show(
                    remaining: remaining,
                    message: breakContent.randomMessage()
                )
                isShowing = true
            }
        default:
            // Anything other than an overlay-bound firing → make sure
            // we're hidden. Covers .working, .deferred, and firings that
            // belong to other surfaces.
            if isShowing {
                controller.hide()
                isShowing = false
            }
        }
    }
}
