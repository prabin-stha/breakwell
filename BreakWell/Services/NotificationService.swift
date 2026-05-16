import Foundation
import UserNotifications
import SwiftUI
import os

// MARK: - NotificationService + PreBreakNotifier
//
// Purpose: Two related but separate pieces in one file:
//   1. `NotificationService` — owns the one-time UNUserNotificationCenter
//      authorization request. Kept slim; we don't actually send any
//      Notification Center notifications (everything routes through the
//      floating banner / overlay / prominent card surfaces).
//   2. `PreBreakNotifier` — drives the 30-second pre-break floating banner
//      (the heads-up with snooze actions). Reads the coordinator's phase
//      stream and shows/hides the banner as work intervals approach.
//
// They share a file because they're both "notify the user about an
// upcoming event" surfaces in the loose sense.
//
// Architecture role: Sits between the coordinator (source of truth for
// "what should fire when") and the user-visible notification surfaces.
//
// Key types defined:
//   - NotificationService: @MainActor authorization wrapper
//   - PreBreakNotifier: @MainActor stream consumer driving the heads-up
//
// Used by:
//   - BreakWellApp (constructs both; calls start() on the notifier)
//
// Swift / macOS concepts a learner will see here:
//   - UNUserNotificationCenter: the user-facing notification API. The
//     authorization flow is async + permission-prompt-driven.
//   - AsyncStream consumption via `for await ... in stream`: structured
//     concurrency idiom for reacting to a feed of values.
//   - Capture lists like `[coordinator]` (no `self`): we capture the actor
//     reference directly so the closure doesn't extend self's lifetime.

/// Owns the one-time notification authorization request. We don't currently
/// post any UNNotificationRequests, but we keep the auth-once flow around
/// so future surfaces (e.g. critical reminders while the user is in
/// fullscreen apps) can be wired in without an awkward re-prompt.
@MainActor
final class NotificationService {
    private let logger = Logger(subsystem: "com.prabin.BreakWell", category: "notifications")
    private let center = UNUserNotificationCenter.current()

    /// Ask for permission only if we haven't asked before. Re-asking when
    /// the user already said no would just be silently denied — and there's
    /// no API to detect the difference between "first time" and "denied",
    /// which is why we check `.notDetermined` specifically.
    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else {
            logger.info("auth status: \(String(describing: settings.authorizationStatus.rawValue))")
            return
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            logger.info("auth requested, granted=\(granted)")
        } catch {
            logger.error("auth request failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - PreBreakNotifier

/// Shows the floating pre-break banner with a live countdown and snooze
/// actions during the last `headsUpThreshold` seconds of each work interval.
///
/// Why a dedicated class instead of folding into the presenter:
/// the pre-break banner is conceptually a *track-adjacent* surface — it's
/// not a track itself (no priority, no grouping), but it follows the eye-rest
/// track's countdown. Keeping it separate avoids polluting the track types
/// with one-off "show heads up" plumbing.
@MainActor
final class PreBreakNotifier {
    private let coordinator: ReminderCoordinator
    private let settings: Settings
    private let engine: SuppressionEngine
    private let banner: FloatingBannerController
    private var observationTask: Task<Void, Never>?

    /// Currently-shown banner state. Holding a reference lets us mutate
    /// `title` to update the live countdown without rebuilding the view.
    private var bannerState: FloatingBannerState?
    /// One-shot guard so we only fire once per cycle, not on every tick
    /// inside the threshold window.
    private var firedThisCycle = false

    /// Show the heads-up when this many seconds remain in the work interval.
    private let headsUpThreshold: TimeInterval = 30

    init(coordinator: ReminderCoordinator, settings: Settings, engine: SuppressionEngine, banner: FloatingBannerController) {
        self.coordinator = coordinator
        self.settings = settings
        self.engine = engine
        self.banner = banner
    }

    /// Subscribe to the coordinator's phase stream. Idempotent.
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
        case .working(let remaining):
            if remaining > headsUpThreshold {
                // Above threshold: ensure no banner is showing and reset
                // the per-cycle guard. The next time we drop into the
                // window, we'll fire fresh.
                dismissBanner()
                firedThisCycle = false
            } else if remaining > 0 {
                if let state = bannerState {
                    // Already showing — just update the countdown. We
                    // deliberately don't dismiss when suppression toggles
                    // mid-window: window switches to Slack/Zoom etc. would
                    // otherwise kill the banner and it wouldn't come back.
                    state.title = formatMMSS(remaining)
                } else if !firedThisCycle && settings.preBreakNotification && !engine.state.isActive {
                    firedThisCycle = true
                    showBanner(initialRemaining: remaining)
                }
            }
        case .firing, .deferred:
            // Either the break started or got deferred — no more heads-up
            // needed. Resetting `firedThisCycle` here lets the next work
            // interval show it again.
            dismissBanner()
            firedThisCycle = false
        }
    }

    private func showBanner(initialRemaining: TimeInterval) {
        let state = FloatingBannerState(
            title: formatMMSS(initialRemaining),
            body: "Your break starts shortly.",
            // Pinkish clock — distinct from the cyan hydration palette.
            icon: .clock(color: Color(red: 1.0, green: 0.55, blue: 0.65)),
            prominence: .prominent,
            actions: makeActions()
        )
        bannerState = state
        // 0 = no auto-dismiss; lifecycle is managed from the phase stream
        // above. We dismiss when remaining hits 0 (transition to .firing).
        banner.show(state, autoDismissAfter: 0)
    }

    private func dismissBanner() {
        guard bannerState != nil else { return }
        bannerState = nil
        banner.dismiss()
    }

    /// Build the two action buttons. Each fires a fire-and-forget Task
    /// into the actor — UI buttons can't await, so we wrap.
    ///
    /// Single snooze (+5m) is intentional. Earlier versions offered +1m,
    /// +5m, +15m — three options for a 30-second decision window felt
    /// like analysis paralysis. "Let me finish my sentence" is the only
    /// snooze story that matters; five minutes covers it.
    private func makeActions() -> [FloatingBannerState.Action] {
        [
            .init(label: "Start break now", isPrimary: true, handler: { [coordinator] in
                Task { await coordinator.takeBreakNow() }
            }),
            // TrackID hard-coded to "break.short" because this notifier is
            // short-break-specific (the only track that gets a heads-up).
            // When the long-break track ships, it won't surface a heads-up
            // — long breaks are intentional, not interruptive.
            .init(label: "Snooze 5m", isPrimary: false, handler: { [coordinator] in
                Task { await coordinator.postponeFire(trackID: "break.short", by: 300) }
            })
        ]
    }

    /// "MM:SS" zero-padded. Pre-break window is at most 30 s in practice,
    /// but the formatter still handles the full minute range cleanly if
    /// the threshold is bumped up later.
    private func formatMMSS(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
