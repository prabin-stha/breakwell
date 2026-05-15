import Foundation
import UserNotifications
import SwiftUI
import os

@MainActor
final class NotificationService {
    private let logger = Logger(subsystem: "com.prabin.BreakWell", category: "notifications")
    private let center = UNUserNotificationCenter.current()
    private let delegate = ForegroundNotificationDelegate()

    init() {
        // Foreground delegate so banners show even when our app is "active"
        // (menu bar apps are always considered active by the notification system).
        center.delegate = delegate
    }

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

    /// Send a generic banner notification for a banner-level track firing.
    func sendBanner(content: ReminderContent) {
        let notif = UNMutableNotificationContent()
        notif.title = content.title
        if let body = content.body { notif.body = body }
        notif.interruptionLevel = .active
        let request = UNNotificationRequest(identifier: content.trackID, content: notif, trigger: nil)
        center.add(request) { [logger] error in
            if let error {
                logger.error("banner send failed: \(error.localizedDescription)")
            }
        }
    }

    func sendPreBreakHeadsUp() {
        let content = UNMutableNotificationContent()
        content.title = "Break in 30 seconds"
        content.body = "A short eye-rest break is coming up — finish your thought."
        content.interruptionLevel = .active
        // No sound on the heads-up; we keep audible chime for the actual break start/end.
        let request = UNNotificationRequest(identifier: "preBreak", content: content, trigger: nil)
        center.add(request) { [logger] error in
            if let error {
                logger.error("notif send failed: \(error.localizedDescription)")
            }
        }
    }
}

/// Foreground delegate — required so notifications appear as banners while our app
/// is running, instead of silently going to Notification Center.
private final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Shows the floating pre-break banner with a live countdown and snooze actions
/// during the last `headsUpThreshold` seconds of each work interval.
@MainActor
final class PreBreakNotifier {
    private let coordinator: ReminderCoordinator
    private let settings: Settings
    private let engine: SuppressionEngine
    private let banner: FloatingBannerController
    private var observationTask: Task<Void, Never>?

    private var bannerState: FloatingBannerState?
    private var firedThisCycle = false

    private let headsUpThreshold: TimeInterval = 30

    init(coordinator: ReminderCoordinator, settings: Settings, engine: SuppressionEngine, banner: FloatingBannerController) {
        self.coordinator = coordinator
        self.settings = settings
        self.engine = engine
        self.banner = banner
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
        case .working(let remaining):
            if remaining > headsUpThreshold {
                dismissBanner()
                firedThisCycle = false
            } else if remaining > 0 {
                if let state = bannerState {
                    // Already showing — just update the countdown. Don't dismiss
                    // when suppression toggles mid-window: window switches to
                    // Slack/Zoom etc. would otherwise kill the banner and it
                    // wouldn't come back.
                    state.title = formatMMSS(remaining)
                } else if !firedThisCycle && settings.preBreakNotification && !engine.state.isActive {
                    firedThisCycle = true
                    showBanner(initialRemaining: remaining)
                }
            }
        case .firing, .deferred:
            dismissBanner()
            firedThisCycle = false
        }
    }

    private func showBanner(initialRemaining: TimeInterval) {
        let state = FloatingBannerState(
            title: formatMMSS(initialRemaining),
            body: "Your break starts shortly.",
            icon: .clock(color: Color(red: 1.0, green: 0.55, blue: 0.65)),
            prominence: .prominent,
            actions: makeActions()
        )
        bannerState = state
        // 0 = no auto-dismiss; lifecycle is managed from the phase stream.
        banner.show(state, autoDismissAfter: 0)
    }

    private func dismissBanner() {
        guard bannerState != nil else { return }
        bannerState = nil
        banner.dismiss()
    }

    private func makeActions() -> [FloatingBannerState.Action] {
        [
            .init(label: "Start break now", isPrimary: true, handler: { [coordinator] in
                Task { await coordinator.takeBreakNow() }
            }),
            .init(label: "+1m", isPrimary: false, handler: { [coordinator] in
                Task { await coordinator.postponeFire(trackID: "break.eyeRest", by: 60) }
            }),
            .init(label: "+5m", isPrimary: false, handler: { [coordinator] in
                Task { await coordinator.postponeFire(trackID: "break.eyeRest", by: 300) }
            }),
            .init(label: "+15m", isPrimary: false, handler: { [coordinator] in
                Task { await coordinator.postponeFire(trackID: "break.eyeRest", by: 900) }
            })
        ]
    }

    private func formatMMSS(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
