import Foundation
import Observation

// MARK: - Settings
//
// Purpose: Persisted user preferences. Wraps `UserDefaults` with typed
// properties and emits change callbacks so downstream services can react
// (e.g. update the eye-rest interval in the coordinator when the user
// edits it in the Settings window).
//
// Architecture role: The single source of truth for user-configurable
// values. Read by SettingsView (the UI) and by BreakWellApp (which wires
// changes through to the right components).
//
// About the Core/Settings folder:
// Only one file lives here — the persistent settings model. Kept out of
// `UI/` so the model can be referenced from `Core/` and `Services/` without
// dragging SwiftUI types along. The SwiftUI Settings *view* is in `UI/`.
//
// Key types defined:
//   - Settings: @Observable class storing every user preference
//
// Used by:
//   - BreakWellApp (constructs, wires `on*Changed` callbacks)
//   - SettingsView (binds property bindings via @Bindable)
//   - Many signal/track constructors (read initial values)
//
// Swift concepts a learner will see here:
//   - @Observable macro: replaces the older @Published / ObservableObject
//     dance. Stored properties are tracked automatically; SwiftUI views
//     re-render when the values they read change.
//   - didSet on stored properties: runs custom code every time the property
//     is assigned. We use it for both persistence (write to UserDefaults)
//     and notification (fire the matching callback).
//   - private nested enum used as a namespace: `Keys` doesn't have cases,
//     it just holds constants. Keeps them private to this file without
//     polluting the global namespace.
//   - UserDefaults.register(defaults:): sets fallback values that apply on
//     first launch (when no value has been written). Beats sprinkling
//     `??` defaults through every read site.

/// Persisted, observable user preferences.
///
/// The class follows a consistent pattern: each stored property has a
/// `didSet` that writes the new value to `UserDefaults` and (optionally)
/// fires a closure callback. The App layer assigns those callbacks at
/// launch — that's how Settings stays ignorant of the coordinator / signals
/// it ends up driving.
///
/// Example usage:
/// ```swift
/// let settings = Settings()
/// settings.onDurationsChanged = { work, breakDur in
///     // push new values to the coordinator
/// }
/// // Later, from the Settings window: changing settings.workMinutes
/// // automatically persists AND invokes onDurationsChanged.
/// ```
///
/// - Note: `@MainActor` because SwiftUI views read these properties from
///   the main actor; matching the isolation here removes a lot of `await`
///   ceremony at the call sites.
@MainActor
@Observable
final class Settings {
    /// String constants for each UserDefaults key. Nested + private so the
    /// only way to read/write them is through the typed properties below.
    private enum Keys {
        static let workMinutes = "workMinutes"
        static let breakSeconds = "breakSeconds"
        static let preBreakNotification = "preBreakNotification"
        static let launchAtLogin = "launchAtLogin"
        static let soundEnabled = "soundEnabled"
        static let meetingDetection = "meetingDetection"
        static let mediaPlaybackDetection = "mediaPlaybackDetection"
        static let screenSharingDetection = "screenSharingDetection"
    }

    /// Injected so tests can swap in an in-memory `UserDefaults`. Defaults
    /// to `.standard` for the real app.
    private let defaults: UserDefaults

    // MARK: - Change callbacks
    //
    // Each callback is `var` (settable by the App after construction) and
    // optional (nil-safe to invoke). This indirection lets Settings notify
    // downstream services without knowing their concrete types.

    /// Fires when work or break durations change.
    var onDurationsChanged: ((TimeInterval, TimeInterval) -> Void)?
    /// Fires when the launch-at-login toggle changes.
    var onLaunchAtLoginChanged: ((Bool) -> Void)?
    /// Fires when the meeting-detection toggle changes.
    var onMeetingDetectionChanged: ((Bool) -> Void)?
    var onMediaPlaybackDetectionChanged: ((Bool) -> Void)?
    var onScreenSharingDetectionChanged: ((Bool) -> Void)?

    // MARK: - Timing

    var workMinutes: Int {
        didSet {
            defaults.set(workMinutes, forKey: Keys.workMinutes)
            // Both durations are reported together because changing one
            // could affect the scheduler's view of the cycle as a whole.
            onDurationsChanged?(workDuration, breakDuration)
        }
    }
    var breakSeconds: Int {
        didSet {
            defaults.set(breakSeconds, forKey: Keys.breakSeconds)
            onDurationsChanged?(workDuration, breakDuration)
        }
    }

    // MARK: - Notifications

    var preBreakNotification: Bool {
        didSet { defaults.set(preBreakNotification, forKey: Keys.preBreakNotification) }
    }
    var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            onLaunchAtLoginChanged?(launchAtLogin)
        }
    }
    var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }

    // MARK: - Suppression / smart-pause toggles

    var meetingDetection: Bool {
        didSet {
            defaults.set(meetingDetection, forKey: Keys.meetingDetection)
            onMeetingDetectionChanged?(meetingDetection)
        }
    }
    var mediaPlaybackDetection: Bool {
        didSet {
            defaults.set(mediaPlaybackDetection, forKey: Keys.mediaPlaybackDetection)
            onMediaPlaybackDetectionChanged?(mediaPlaybackDetection)
        }
    }
    var screenSharingDetection: Bool {
        didSet {
            defaults.set(screenSharingDetection, forKey: Keys.screenSharingDetection)
            onScreenSharingDetectionChanged?(screenSharingDetection)
        }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `register(defaults:)` seeds these values for any key that hasn't
        // been written yet. They behave like "factory defaults" — once a
        // user changes a value, the registered default no longer applies
        // to that key. Calling register on every launch is fine and idempotent.
        defaults.register(defaults: [
            // 25 min work / 5 min break — standard Pomodoro cadence. The
            // break is meaningful (long enough to actually step away),
            // not the old 20-second eye-rest token gesture.
            Keys.workMinutes: 25,
            Keys.breakSeconds: 300,
            Keys.preBreakNotification: true,
            Keys.launchAtLogin: false,
            Keys.soundEnabled: true,
            Keys.meetingDetection: true,
            Keys.mediaPlaybackDetection: true,
            Keys.screenSharingDetection: true
        ])
        // Read each value into its property. Init runs BEFORE didSet, so
        // these assignments don't trigger UserDefaults writes or callbacks.
        self.workMinutes = defaults.integer(forKey: Keys.workMinutes)
        // Migrate stale values from the eye-rest-era Stepper (which allowed
        // any 5-second step from 10 to 600). The Picker only accepts a
        // discrete preset list now; snap unknown values to the default so
        // upgraders don't see an empty Picker on first launch.
        //
        // We compute the migrated value on a local before assigning to
        // `self.breakSeconds` because Swift forbids reading a stored
        // property (even to test it) until every stored property in the
        // type has been initialized.
        let allowedBreakDurations: Set<Int> = [60, 120, 180, 300, 420, 600, 900]
        let savedBreakSeconds = defaults.integer(forKey: Keys.breakSeconds)
        if allowedBreakDurations.contains(savedBreakSeconds) {
            self.breakSeconds = savedBreakSeconds
        } else {
            self.breakSeconds = 300
            defaults.set(300, forKey: Keys.breakSeconds)
        }
        self.preBreakNotification = defaults.bool(forKey: Keys.preBreakNotification)
        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        self.soundEnabled = defaults.bool(forKey: Keys.soundEnabled)
        self.meetingDetection = defaults.bool(forKey: Keys.meetingDetection)
        self.mediaPlaybackDetection = defaults.bool(forKey: Keys.mediaPlaybackDetection)
        self.screenSharingDetection = defaults.bool(forKey: Keys.screenSharingDetection)
    }

    // MARK: - Derived values
    //
    // Computed properties for things downstream code wants in a different
    // shape than what we store. Keeping them here means there's one place
    // to fix the conversion if we ever change units again.

    /// Work interval as a real TimeInterval (seconds). Routes through
    /// `AppTiming.secondsPerMinute` so the global test-mode knob applies.
    var workDuration: TimeInterval { workMinutes.minutesAsSeconds }

    /// Break duration is stored in seconds directly (no minutes conversion).
    var breakDuration: TimeInterval { TimeInterval(breakSeconds) }
}
