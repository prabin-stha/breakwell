import Foundation
import Observation

@MainActor
@Observable
final class Settings {
    private enum Keys {
        static let workMinutes = "workMinutes"
        static let breakSeconds = "breakSeconds"
        static let preBreakNotification = "preBreakNotification"
        static let launchAtLogin = "launchAtLogin"
        static let soundEnabled = "soundEnabled"
        static let meetingDetectionMode = "meetingDetectionMode"
        static let mediaPlaybackDetection = "mediaPlaybackDetection"
        static let screenSharingDetection = "screenSharingDetection"
        static let calendarDetection = "calendarDetection"
        static let calendarBufferMinutes = "calendarBufferMinutes"
        static let waterEnabled = "waterEnabled"
        static let waterIntervalMinutes = "waterIntervalMinutes"
    }

    private let defaults: UserDefaults

    /// Set by the app on launch — fires when work/break durations change so the
    /// scheduler can pick them up. Kept as a closure to avoid Settings knowing about
    /// the scheduler directly.
    var onDurationsChanged: ((TimeInterval, TimeInterval) -> Void)?

    /// Set by the app on launch — fires when the launch-at-login toggle changes.
    var onLaunchAtLoginChanged: ((Bool) -> Void)?

    /// Set by the app on launch — fires when the meeting-detection mode changes.
    var onMeetingDetectionModeChanged: ((MeetingDetectionMode) -> Void)?

    var onMediaPlaybackDetectionChanged: ((Bool) -> Void)?

    var onScreenSharingDetectionChanged: ((Bool) -> Void)?

    var onCalendarDetectionChanged: ((Bool) -> Void)?
    var onCalendarBufferChanged: ((Int) -> Void)?

    var onWaterEnabledChanged: ((Bool) -> Void)?
    var onWaterIntervalChanged: ((Int) -> Void)?

    var workMinutes: Int {
        didSet {
            defaults.set(workMinutes, forKey: Keys.workMinutes)
            onDurationsChanged?(workDuration, breakDuration)
        }
    }
    var breakSeconds: Int {
        didSet {
            defaults.set(breakSeconds, forKey: Keys.breakSeconds)
            onDurationsChanged?(workDuration, breakDuration)
        }
    }
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
    var meetingDetectionMode: MeetingDetectionMode {
        didSet {
            defaults.set(meetingDetectionMode.rawValue, forKey: Keys.meetingDetectionMode)
            onMeetingDetectionModeChanged?(meetingDetectionMode)
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
    var calendarDetection: Bool {
        didSet {
            defaults.set(calendarDetection, forKey: Keys.calendarDetection)
            onCalendarDetectionChanged?(calendarDetection)
        }
    }
    var calendarBufferMinutes: Int {
        didSet {
            defaults.set(calendarBufferMinutes, forKey: Keys.calendarBufferMinutes)
            onCalendarBufferChanged?(calendarBufferMinutes)
        }
    }
    var waterEnabled: Bool {
        didSet {
            defaults.set(waterEnabled, forKey: Keys.waterEnabled)
            onWaterEnabledChanged?(waterEnabled)
        }
    }
    var waterIntervalMinutes: Int {
        didSet {
            defaults.set(waterIntervalMinutes, forKey: Keys.waterIntervalMinutes)
            onWaterIntervalChanged?(waterIntervalMinutes)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.workMinutes: 20,
            Keys.breakSeconds: 20,
            Keys.preBreakNotification: true,
            Keys.launchAtLogin: false,
            Keys.soundEnabled: true,
            Keys.meetingDetectionMode: MeetingDetectionMode.processOnly.rawValue,
            Keys.mediaPlaybackDetection: true,
            Keys.screenSharingDetection: true,
            Keys.calendarDetection: false,
            Keys.calendarBufferMinutes: 2,
            Keys.waterEnabled: true,
            Keys.waterIntervalMinutes: 60
        ])
        self.workMinutes = defaults.integer(forKey: Keys.workMinutes)
        self.breakSeconds = defaults.integer(forKey: Keys.breakSeconds)
        self.preBreakNotification = defaults.bool(forKey: Keys.preBreakNotification)
        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        self.soundEnabled = defaults.bool(forKey: Keys.soundEnabled)
        let modeRaw = defaults.string(forKey: Keys.meetingDetectionMode) ?? MeetingDetectionMode.processOnly.rawValue
        self.meetingDetectionMode = MeetingDetectionMode(rawValue: modeRaw) ?? .processOnly
        self.mediaPlaybackDetection = defaults.bool(forKey: Keys.mediaPlaybackDetection)
        self.screenSharingDetection = defaults.bool(forKey: Keys.screenSharingDetection)
        self.calendarDetection = defaults.bool(forKey: Keys.calendarDetection)
        self.calendarBufferMinutes = defaults.integer(forKey: Keys.calendarBufferMinutes)
        self.waterEnabled = defaults.bool(forKey: Keys.waterEnabled)
        self.waterIntervalMinutes = defaults.integer(forKey: Keys.waterIntervalMinutes)
    }

    var workDuration: TimeInterval { TimeInterval(workMinutes * 60) }
    var breakDuration: TimeInterval { TimeInterval(breakSeconds) }
}
