//
//  BreakWellApp.swift
//  BreakWell
//
//  Created by Prabin Shrestha on 5/12/26.
//

import SwiftUI

// MARK: - BreakWellApp
//
// Purpose: Process entry point and dependency-injection root. Constructs every
// long-lived object the app needs (coordinator, signals, services, UI
// controllers) and wires them together.
//
// Architecture role: App composition layer. The only file in App/. Everything
// downstream is a leaf — Core knows nothing about UI, UI knows nothing about
// macOS-process management, and they only meet here.
//
// About the App/ folder:
// This folder contains the @main entry point and process-level concerns
// (Info.plist, single-instance enforcement, etc.). Files here are free to
// import any layer of the app — that's the point of composition root code.
// Anything that *doesn't* need to know about every layer should live deeper.
//
// Key types defined:
//   - BreakWellApp: the SwiftUI App struct that owns everything
//
// Used by:
//   - macOS itself, via the @main attribute below
//
// Depends on:
//   - SwiftUI for the App / Scene / MenuBarExtra protocols
//   - AppKit for NSRunningApplication (single-instance check)
//   - Every Core / Features / Services / UI module
//
// Swift concepts a learner will see here:
//   - @main: tells the Swift runtime "this is the entry point". The App
//     protocol's body produces the windows / scenes shown at launch.
//   - @Sendable closures: closures we capture into Tasks crossing actor
//     boundaries must promise they're safe to call from any isolation.
//   - Task { @MainActor in ... }: schedules concurrent work that runs on the
//     main actor (needed when touching AppKit/SwiftUI from a non-main context).
//   - for await ... in stream: drains an AsyncStream, suspending until the
//     next value arrives.

/// SwiftUI `App` for BreakWell. The `init` is unusually large because this is
/// the composition root — it builds the dependency graph that the rest of
/// the app reads from. There are no factories or DI containers; objects are
/// constructed in topological order and stored as `let` properties.
///
/// - Note: `init` runs on the main thread (Swift requires App.init to be
///   main-actor isolated). The actor-isolated `ReminderCoordinator` is
///   *constructed* here but not *touched* — its first async call happens
///   in the `Task { await coordinator.start() }` at the bottom of `init`.
@main
struct BreakWellApp: App {
    // Every long-lived dependency is stored as a `let` so it lives for the
    // app's lifetime and can't be swapped at runtime.
    private let coordinator: ReminderCoordinator
    private let viewModel: SchedulerViewModel
    private let overlayPresenter: OverlayPresenter
    private let settings: Settings
    private let idleSignal: IdleSignal
    private let manualPauseSignal: ManualPauseSignal
    private let meetingSignal: MeetingSignal
    private let mediaPlaybackSignal: MediaPlaybackSignal
    private let screenSharingSignal: ScreenSharingSignal
    private let suppressionEngine: SuppressionEngine
    private let notificationService: NotificationService
    private let preBreakNotifier: PreBreakNotifier
    private let loginItemService: LoginItemService
    private let breakSoundPlayer: BreakSoundPlayer
    private let floatingBanner: FloatingBannerController
    private let breakStats: BreakStats

    init() {
        // If a previous BreakWell instance is still running (e.g. login-launch
        // started one and Xcode is launching another), tell it to quit before
        // we proceed. Without this you'd end up with two menu-bar icons.
        Self.terminateOtherInstances()

        let settings = Settings()
        self.settings = settings

        // ---- Build the default short-break track from user settings. -------
        // `BreakTrack` is a generic break — its identity comes from `id` and
        // its content from a `BreakContent` preset. Adding a long break later
        // means defining `.longBreak` in BreakContent and instantiating
        // another BreakTrack with id `"break.long"` — no new types needed.
        let shortBreak = BreakTrack(
            id: "break.short",
            displayName: "Short Break",
            interval: .seconds(settings.workDuration),
            duration: .seconds(settings.breakDuration),
            content: .shortBreak
        )
        let initialTracks: [any ReminderTrack] = [shortBreak]

        // ---- UI controllers and supporting state. -------------------------
        let notificationService = NotificationService()
        let floatingBanner = FloatingBannerController()
        self.floatingBanner = floatingBanner

        // Daily break-completion counter. Hardcoded 4am reset for now —
        // the old hydration daily-reset setting drove this, but with
        // hydration cut there's no UI to expose the picker. 4am works.
        let breakStats = BreakStats()
        self.breakStats = breakStats

        // The coordinator currently has only overlay-level tracks (short
        // break). present/dismiss handlers are no-op placeholders — the
        // OverlayPresenter observes the phase stream directly. They stay
        // around so the coordinator's API doesn't have to special-case a
        // future surface (long break, prominent stats card) — when one
        // ships, wire it in here.
        let presentHandler: @Sendable (ReminderContent) -> Void = { _ in }
        let dismissHandler: @Sendable (InterruptionLevel) -> Void = { _ in }

        let coordinator = ReminderCoordinator(
            tracks: initialTracks,
            presentHandler: presentHandler,
            dismissHandler: dismissHandler
        )
        self.coordinator = coordinator

        // ---- Suppression signals. Each one publishes "is this active?"
        // independently; the SuppressionEngine ORs them together. The order
        // of the array determines priority for the reason string shown to
        // the user when multiple are active (manual pause beats everything,
        // idle is last-resort).
        let manualPauseSignal = ManualPauseSignal()
        self.manualPauseSignal = manualPauseSignal
        let meetingSignal = MeetingSignal(enabled: settings.meetingDetection)
        self.meetingSignal = meetingSignal
        let mediaPlaybackSignal = MediaPlaybackSignal(enabled: settings.mediaPlaybackDetection)
        self.mediaPlaybackSignal = mediaPlaybackSignal
        let screenSharingSignal = ScreenSharingSignal(enabled: settings.screenSharingDetection)
        self.screenSharingSignal = screenSharingSignal
        let idleSignal = IdleSignal()
        self.idleSignal = idleSignal

        let suppressionEngine = SuppressionEngine(signals: [
            manualPauseSignal,
            screenSharingSignal,
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

        // ---- Settings → service wiring. ------------------------------------
        // Settings is @Observable and emits change callbacks. We translate
        // those into the right downstream commands here. Each closure is
        // small enough that defining it inline is clearer than splitting it
        // into separate methods.
        settings.onDurationsChanged = { work, breakDur in
            let updated = BreakTrack(
                id: "break.short",
                displayName: "Short Break",
                interval: .seconds(work),
                duration: .seconds(breakDur),
                content: .shortBreak
            )
            // The coordinator is an actor — `await` to cross the isolation
            // boundary. We're already inside a Task so the await is legal.
            Task { await coordinator.updateTrack(updated) }
        }
        settings.onLaunchAtLoginChanged = { enabled in
            loginItemService.set(enabled: enabled)
        }
        settings.onMeetingDetectionChanged = { enabled in
            meetingSignal.enabled = enabled
        }
        settings.onMediaPlaybackDetectionChanged = { enabled in
            mediaPlaybackSignal.enabled = enabled
        }
        settings.onScreenSharingDetectionChanged = { enabled in
            screenSharingSignal.enabled = enabled
        }

        // Reconcile the saved "launch at login" toggle with the system's
        // actual state — the user could have toggled it via System Settings
        // since we last ran. Trust the OS as source of truth here.
        let systemEnabled = loginItemService.isEnabled
        if settings.launchAtLogin != systemEnabled {
            settings.launchAtLogin = systemEnabled
        }

        // ---- Start the long-running pieces. -------------------------------
        idleSignal.start()
        meetingSignal.start()
        mediaPlaybackSignal.start()
        screenSharingSignal.start()
        suppressionEngine.start()

        viewModel.startObserving()
        overlayPresenter.start()
        preBreakNotifier.start()
        breakSoundPlayer.start()

        // Bridge engine → coordinator: every time the suppression engine
        // publishes a new state, push it into the actor-isolated coordinator.
        // `for await` drains the AsyncStream forever (until the app exits).
        Task { @MainActor in
            let stream = suppressionEngine.stream()
            for await state in stream {
                await coordinator.setSuppressed(state.isActive)
            }
        }

        // Bridge coordinator → BreakStats: increment the daily counter
        // only when a break track completes naturally (skip / preempt do
        // not yield on completionStream).
        Task { @MainActor in
            let stream = await coordinator.completionStream()
            for await trackID in stream where trackID.hasPrefix("break.") {
                breakStats.recordCompletion()
            }
        }

        // Permission ask (one-time, idempotent) and coordinator boot.
        Task { await notificationService.requestAuthorizationIfNeeded() }
        Task { await coordinator.start() }
    }

    /// SwiftUI scene description. The macOS runtime calls `body` once at
    /// launch to learn what windows / menu-bar items to set up.
    var body: some Scene {
        // MenuBarExtra is SwiftUI's modern API for a menu-bar app: it puts
        // an icon in the status bar and shows the provided view when clicked.
        // The `.window` style means clicks open a popover-like window rather
        // than a traditional NSMenu.
        MenuBarExtra {
            MenuBarView(viewModel: viewModel, breakStats: breakStats)
        } label: {
            Image(systemName: labelSymbol)
        }
        .menuBarExtraStyle(.window)

        // `SwiftUI.Settings` is qualified to disambiguate from our `Settings`
        // model type. This is SwiftUI's built-in scene for the macOS
        // Settings… window (driven by ⌘, from the menu bar).
        SwiftUI.Settings {
            SettingsView(settings: settings)
        }
    }

    /// Look for other running instances of this app (same bundle ID) and
    /// politely ask them to terminate. Solves the "two menu bar icons"
    /// problem when a login-launched instance is already running.
    ///
    /// `NSRunningApplication` lives in AppKit; it queries the running-app
    /// list from launchservicesd.
    private static func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let mePID = getpid()
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != mePID }
        for app in others {
            app.terminate()
        }
    }

    /// Which SF Symbol to render in the menu bar right now. Derived from the
    /// view model's published phase + suppression state so it updates
    /// automatically when either changes (SwiftUI handles the re-render).
    ///
    /// Iconography:
    /// - working:  cup.and.saucer       (a quiet "break is coming")
    /// - firing:   cup.and.saucer.fill  (the break is happening)
    /// - paused / deferred: pause.circle (auto-paused or holding a ready break)
    private var labelSymbol: String {
        if case .deferred = viewModel.phase {
            return "pause.circle"
        }
        if viewModel.suppression.isActive {
            return "pause.circle"
        }
        switch viewModel.phase {
        case .working: return "cup.and.saucer"
        case .firing: return "cup.and.saucer.fill"
        case .deferred: return "pause.circle"
        }
    }
}

