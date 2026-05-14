import SwiftUI
import EventKit
import AppKit

struct SettingsView: View {
    @Bindable var settings: Settings
    let viewModel: SchedulerViewModel
    let signals: SignalRefs

    var body: some View {
        TabView {
            GeneralSettingsView(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            SmartPauseSettingsView(settings: settings)
                .tabItem { Label("Smart Pause", systemImage: "moon.zzz") }
            DiagnosticsView(viewModel: viewModel, signals: signals)
                .tabItem { Label("Activity", systemImage: "waveform") }
        }
        .frame(width: 480, height: 460)
    }
}

struct SignalRefs {
    let manualPause: ManualPauseSignal
    let meeting: MeetingSignal
    let media: MediaPlaybackSignal
    let screenSharing: ScreenSharingSignal
    let calendar: CalendarSignal
    let idle: IdleSignal
}

// MARK: - General

private struct GeneralSettingsView: View {
    @Bindable var settings: Settings

    var body: some View {
        Form {
            Section {
                Stepper(value: $settings.workMinutes, in: 1...60) {
                    LabeledContent("Work interval", value: "\(settings.workMinutes) min")
                }
                Stepper(value: $settings.breakSeconds, in: 10...600, step: 5) {
                    LabeledContent("Break duration", value: formatBreakDuration(settings.breakSeconds))
                }
            } header: {
                Text("Timing")
            } footer: {
                Text("During a break you can extend it by 5 minutes from the overlay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Show a 30-second heads-up before each break", isOn: $settings.preBreakNotification)
                Toggle("Play a sound when breaks start and end", isOn: $settings.soundEnabled)
            }

            Section("Water reminders") {
                Toggle("Remind me to drink water", isOn: $settings.waterEnabled)
                if settings.waterEnabled {
                    Stepper(value: $settings.waterIntervalMinutes, in: 30...180, step: 15) {
                        LabeledContent("Reminder every", value: "\(settings.waterIntervalMinutes) min")
                    }
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }
        }
        .formStyle(.grouped)
    }

    private func formatBreakDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) sec" }
        let m = seconds / 60
        let s = seconds % 60
        if s == 0 { return "\(m) min" }
        return "\(m) min \(s) sec"
    }
}

// MARK: - Smart Pause

private struct SmartPauseSettingsView: View {
    @Bindable var settings: Settings
    @State private var calendarStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    var body: some View {
        Form {
            Section {
                Picker("Pause during meetings", selection: $settings.meetingDetectionMode) {
                    ForEach(MeetingDetectionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text(meetingHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Meetings")
            }

            Section {
                Toggle("Pause while watching or listening to media", isOn: $settings.mediaPlaybackDetection)
                Text("Pauses breaks whenever the app you're using is playing audio — videos, calls, music.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Media")
            }

            Section {
                Toggle("Pause while a recording app is open", isOn: $settings.screenSharingDetection)
                Text("Pauses breaks while OBS, Streamlabs, Loom, or ScreenFlow is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Screen recording")
            }

            Section {
                Toggle("Pause during calendar events", isOn: $settings.calendarDetection)
                if settings.calendarDetection {
                    calendarPermissionRow
                    Stepper(value: $settings.calendarBufferMinutes, in: 0...15) {
                        LabeledContent("Start pausing before events", value: "\(settings.calendarBufferMinutes) min")
                    }
                }
            } header: {
                Text("Calendar")
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshCalendarStatus() }
        .onChange(of: settings.calendarDetection) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                refreshCalendarStatus()
            }
        }
        // EventKit doesn't broadcast auth-status changes. Refresh whenever the
        // app becomes active again — that's when the user has come back from
        // System Settings after toggling the permission.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshCalendarStatus()
        }
    }

    private var meetingHelpText: String {
        switch settings.meetingDetectionMode {
        case .off:
            "Meetings won't pause your breaks."
        case .processOnly:
            "Pauses while you're in Zoom, Teams, Slack, Discord, FaceTime, or similar apps."
        case .micActivity:
            "Pauses whenever any app is using your microphone — also catches browser calls like Google Meet."
        }
    }

    @ViewBuilder
    private var calendarPermissionRow: some View {
        HStack {
            Text("Calendar access")
            Spacer()
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusLabel)
                    .foregroundStyle(.secondary)
                if calendarStatus == .denied || calendarStatus == .restricted {
                    Button("Open System Settings…") {
                        openCalendarPrivacyPane()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var statusLabel: String {
        switch calendarStatus {
        case .fullAccess: "Allowed"
        case .authorized: "Allowed"
        case .writeOnly: "Limited — full access needed"
        case .denied: "Not allowed"
        case .restricted: "Blocked by system policy"
        case .notDetermined: "Not requested yet"
        @unknown default: "Unknown"
        }
    }

    private var statusColor: Color {
        switch calendarStatus {
        case .fullAccess, .authorized: .green
        case .denied, .restricted, .writeOnly: .red
        case .notDetermined: .secondary
        @unknown default: .secondary
        }
    }

    private func refreshCalendarStatus() {
        calendarStatus = EKEventStore.authorizationStatus(for: .event)
    }

    private func openCalendarPrivacyPane() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Diagnostics

private struct DiagnosticsView: View {
    let viewModel: SchedulerViewModel
    let signals: SignalRefs

    var body: some View {
        Form {
            Section {
                LabeledContent("Right now", value: phaseLabel)
                LabeledContent("Auto-paused", value: viewModel.suppression.isActive ? "Yes" : "No")
                if let reason = viewModel.suppression.reason {
                    LabeledContent("Reason", value: reason)
                }
            } header: {
                Text("Status")
            }

            Section {
                signalRow(name: "Paused by you",
                          isActive: signals.manualPause.isActive,
                          reason: signals.manualPause.reason)
                signalRow(name: "Screen recording app",
                          isActive: signals.screenSharing.isActive,
                          reason: signals.screenSharing.reason)
                signalRow(name: "Calendar event",
                          isActive: signals.calendar.isActive,
                          reason: signals.calendar.reason)
                signalRow(name: "Meeting",
                          isActive: signals.meeting.isActive,
                          reason: signals.meeting.reason)
                signalRow(name: "Audio playing",
                          isActive: signals.media.isActive,
                          reason: signals.media.reason)
                signalRow(name: "Away from computer",
                          isActive: signals.idle.isActive,
                          reason: signals.idle.reason)
            } header: {
                Text("What can pause your breaks")
            } footer: {
                Text("Listed in order of priority. The topmost active item is the reason shown elsewhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var phaseLabel: String {
        switch viewModel.phase {
        case .working(let r):
            let mins = Int(r) / 60
            let secs = Int(r) % 60
            if mins > 0 {
                return "Working — \(mins)m \(secs)s until next break"
            }
            return "Working — \(secs)s until next break"
        case .firing(let r, _):
            return "On break — \(Int(r))s left"
        case .deferred(let since, _):
            return "Break held since \(since.formatted(date: .omitted, time: .shortened))"
        }
    }

    private func signalRow(name: String, isActive: Bool, reason: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isActive ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
            Text(name)
            Spacer()
            Text(isActive ? reason : "Not active")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
