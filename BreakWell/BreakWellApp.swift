//
//  BreakWellApp.swift
//  BreakWell
//
//  Created by Prabin Shrestha on 5/12/26.
//

import SwiftUI

@main
struct BreakWellApp: App {
    private let coordinator: ReminderCoordinator
    private let viewModel: SchedulerViewModel
    private let overlayPresenter: OverlayPresenter
    private let settings: Settings
    private let idleSignal: IdleSignal
    private let manualPauseSignal: ManualPauseSignal
    private let meetingSignal: MeetingSignal
    private let mediaPlaybackSignal: MediaPlaybackSignal
    private let screenSharingSignal: ScreenSharingSignal
    private let calendarSignal: CalendarSignal
    private let suppressionEngine: SuppressionEngine
    private let notificationService: NotificationService
    private let preBreakNotifier: PreBreakNotifier
    private let loginItemService: LoginItemService
    private let breakSoundPlayer: BreakSoundPlayer
    private let floatingBanner: FloatingBannerController

    init() {
        Self.terminateOtherInstances()

        let settings = Settings()
        self.settings = settings

        let eyeRest = EyeRestTrack(
            interval: .seconds(settings.workDuration),
            duration: .seconds(settings.breakDuration)
        )
        var initialTracks: [any ReminderTrack] = [eyeRest]
        if settings.waterEnabled {
            initialTracks.append(WaterTrack(interval: .seconds(settings.waterIntervalMinutes * 60)))
        }

        let notificationService = NotificationService()
        let floatingBanner = FloatingBannerController()
        self.floatingBanner = floatingBanner

        let bannerHandler: @Sendable (ReminderContent) -> Void = { content in
            Task { @MainActor in
                let state = FloatingBannerState(
                    title: content.title,
                    body: content.body,
                    icon: .symbol(
                        name: iconSymbol(for: content.trackID),
                        color: iconColor(for: content.trackID)
                    )
                )
                floatingBanner.show(state)
            }
        }

        let coordinator = ReminderCoordinator(tracks: initialTracks, bannerHandler: bannerHandler)
        self.coordinator = coordinator

        // Suppression signals — same as phase 2.
        let manualPauseSignal = ManualPauseSignal()
        self.manualPauseSignal = manualPauseSignal
        let meetingSignal = MeetingSignal(mode: settings.meetingDetectionMode)
        self.meetingSignal = meetingSignal
        let mediaPlaybackSignal = MediaPlaybackSignal(enabled: settings.mediaPlaybackDetection)
        self.mediaPlaybackSignal = mediaPlaybackSignal
        let screenSharingSignal = ScreenSharingSignal(enabled: settings.screenSharingDetection)
        self.screenSharingSignal = screenSharingSignal
        let calendarSignal = CalendarSignal(
            enabled: settings.calendarDetection,
            bufferMinutes: settings.calendarBufferMinutes
        )
        self.calendarSignal = calendarSignal
        let idleSignal = IdleSignal()
        self.idleSignal = idleSignal

        let suppressionEngine = SuppressionEngine(signals: [
            manualPauseSignal,
            screenSharingSignal,
            calendarSignal,
            meetingSignal,
            mediaPlaybackSignal,
            idleSignal
        ])
        self.suppressionEngine = suppressionEngine

        let viewModel = SchedulerViewModel(
            coordinator: coordinator,
            engine: suppressionEngine,
            manualPauseSignal: manualPauseSignal
        )
        self.viewModel = viewModel

        let overlayPresenter = OverlayPresenter(coordinator: coordinator)
        self.overlayPresenter = overlayPresenter

        self.notificationService = notificationService

        let preBreakNotifier = PreBreakNotifier(
            coordinator: coordinator,
            settings: settings,
            engine: suppressionEngine,
            banner: floatingBanner
        )
        self.preBreakNotifier = preBreakNotifier

        let loginItemService = LoginItemService()
        self.loginItemService = loginItemService

        let breakSoundPlayer = BreakSoundPlayer(coordinator: coordinator, settings: settings)
        self.breakSoundPlayer = breakSoundPlayer

        settings.onDurationsChanged = { work, breakDur in
            let updated = EyeRestTrack(
                interval: .seconds(work),
                duration: .seconds(breakDur)
            )
            Task { await coordinator.updateTrack(updated) }
        }
        settings.onLaunchAtLoginChanged = { enabled in
            loginItemService.set(enabled: enabled)
        }
        settings.onMeetingDetectionModeChanged = { mode in
            meetingSignal.mode = mode
        }
        settings.onMediaPlaybackDetectionChanged = { enabled in
            mediaPlaybackSignal.enabled = enabled
        }
        settings.onScreenSharingDetectionChanged = { enabled in
            screenSharingSignal.enabled = enabled
        }
        settings.onCalendarDetectionChanged = { enabled in
            calendarSignal.enabled = enabled
            if enabled {
                Task { await calendarSignal.requestAccessIfNeeded() }
            }
        }
        settings.onCalendarBufferChanged = { minutes in
            calendarSignal.bufferMinutes = minutes
        }
        settings.onWaterEnabledChanged = { enabled in
            if enabled {
                let track = WaterTrack(interval: .seconds(settings.waterIntervalMinutes * 60))
                Task { await coordinator.updateTrack(track) }
            } else {
                Task { await coordinator.removeTrack(id: "water") }
            }
        }
        settings.onWaterIntervalChanged = { minutes in
            guard settings.waterEnabled else { return }
            let track = WaterTrack(interval: .seconds(minutes * 60))
            Task { await coordinator.updateTrack(track) }
        }
        let systemEnabled = loginItemService.isEnabled
        if settings.launchAtLogin != systemEnabled {
            settings.launchAtLogin = systemEnabled
        }

        idleSignal.start()
        meetingSignal.start()
        mediaPlaybackSignal.start()
        screenSharingSignal.start()
        calendarSignal.start()
        suppressionEngine.start()

        if settings.calendarDetection {
            Task { await calendarSignal.requestAccessIfNeeded() }
        }
        viewModel.startObserving()
        overlayPresenter.start()
        preBreakNotifier.start()
        breakSoundPlayer.start()

        // Bridge engine → coordinator.
        Task { @MainActor in
            let stream = suppressionEngine.stream()
            for await state in stream {
                await coordinator.setSuppressed(state.isActive)
            }
        }

        Task { await notificationService.requestAuthorizationIfNeeded() }
        Task { await coordinator.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            Image(systemName: labelSymbol)
        }
        .menuBarExtraStyle(.window)

        SwiftUI.Settings {
            SettingsView(
                settings: settings,
                viewModel: viewModel,
                signals: SignalRefs(
                    manualPause: manualPauseSignal,
                    meeting: meetingSignal,
                    media: mediaPlaybackSignal,
                    screenSharing: screenSharingSignal,
                    calendar: calendarSignal,
                    idle: idleSignal
                )
            )
        }
    }

    /// Terminate any other running instances of this app.
    private static func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let mePID = getpid()
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != mePID }
        for app in others {
            app.terminate()
        }
    }

    private var labelSymbol: String {
        if case .deferred = viewModel.phase {
            return "eye.slash"
        }
        if viewModel.suppression.isActive {
            return "eye.slash"
        }
        switch viewModel.phase {
        case .working: return "eye"
        case .firing: return "eye.fill"
        case .deferred: return "eye.slash"
        }
    }
}

@MainActor
private func iconSymbol(for trackID: String) -> String {
    switch trackID {
    case "water": return "drop.fill"
    case "eye-rest": return "eye.fill"
    default: return "bell.fill"
    }
}

@MainActor
private func iconColor(for trackID: String) -> Color {
    switch trackID {
    case "water": return Color.cyan
    case "eye-rest": return Color.indigo
    default: return Color.accentColor
    }
}
