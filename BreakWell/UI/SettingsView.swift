import SwiftUI

// MARK: - SettingsView
//
// Purpose: The Settings window. Two tabs — General (timing, sounds, water,
// startup) and Smart Pause (which signals can pause breaks).
//
// Architecture role: The single SwiftUI scene reached via the menu bar's
// "Settings…" item (and ⌘, from inside the popover). Reads/writes
// `Settings`.
//
// About the UI/ folder:
// Currently just this one file. UI/ is the home for app-chrome surfaces
// that don't belong to a single feature — Settings being the canonical
// example, since it spans every feature. Other features keep their views
// inside their own Features/<Name>/ folder.
//
// Key types defined:
//   - SettingsView: the TabView wrapper
//   - GeneralSettingsView / SmartPauseSettingsView: private per-tab views
//
// Used by:
//   - BreakWellApp's `Settings { SettingsView(...) }` scene
//
// SwiftUI / macOS concepts a learner will see here:
//   - @Bindable: lets us pass an @Observable class around and still bind
//     its properties to controls via `$settings.workMinutes`. Equivalent
//     to @ObservedObject + @Published in the older world.
//   - Form + Section + .formStyle(.grouped): macOS Settings idiom that
//     gives the inset-rounded look matching System Settings.
//   - TabView for top-level navigation: macOS auto-renders it as the
//     icon strip familiar from System Settings panes.
//   - Form + Section is SwiftUI's standard pattern for settings panes;
//     `.formStyle(.grouped)` is what produces the inset-rounded cards.

/// The Settings scene. Two tabs surfaced as System Settings-style icons.
struct SettingsView: View {
    @Bindable var settings: Settings

    var body: some View {
        TabView {
            GeneralSettingsView(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            SmartPauseSettingsView(settings: settings)
                .tabItem { Label("Smart Pause", systemImage: "moon.zzz") }
        }
        // Fixed window size — macOS Settings windows are non-resizable
        // by convention, so giving an explicit frame makes the layout
        // predictable.
        .frame(width: 480, height: 420)
    }
}

// MARK: - General

/// Timing, sounds, water, login-at-startup. The big "casual user" tab.
private struct GeneralSettingsView: View {
    @Bindable var settings: Settings

    var body: some View {
        Form {
            Section("Timing") {
                // Stepper + LabeledContent is the conventional Settings
                // pairing: ± buttons on the right, a label-value row on
                // the left. The `value:` projects the formatted text.
                Stepper(value: $settings.workMinutes, in: 1...60) {
                    LabeledContent("Work interval", value: "\(settings.workMinutes) min")
                }
                // Discrete presets rather than a 5-second-step Stepper. The
                // useful break lengths cluster at a handful of values; a
                // free-range Stepper makes you click +24 times to go from
                // 5 min to 7 min.
                Picker("Break duration", selection: $settings.breakSeconds) {
                    ForEach(breakDurationPresets, id: \.self) { seconds in
                        Text(formatBreakDuration(seconds)).tag(seconds)
                    }
                }

            }

            Section("Notifications") {
                Toggle("Show a 30-second heads-up before each break", isOn: $settings.preBreakNotification)
                Toggle("Play a sound when breaks start and end", isOn: $settings.soundEnabled)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }
        }
        // `.grouped` is the macOS-Settings inset-card look. The default
        // formStyle is much more compact and feels out of place in a
        // dedicated Settings window.
        .formStyle(.grouped)
    }

    /// Allowed break durations. All on minute boundaries so the picker
    /// labels read cleanly. To add a new option, drop a value (in seconds)
    /// into this array and the picker picks it up.
    private let breakDurationPresets: [Int] = [60, 120, 180, 300, 420, 600, 900]

    /// Label for a preset. Every preset is currently a whole number of
    /// minutes, so this is just "N min". If a sub-minute preset is ever
    /// added back, extend the formatting here.
    private func formatBreakDuration(_ seconds: Int) -> String {
        "\(seconds / 60) min"
    }
}

// MARK: - Smart Pause

/// Controls for the SuppressionEngine's signals. Each toggle drives one
/// signal's "enabled" flag in Settings; the signal itself reads that flag
/// to decide whether to participate in suppression.
private struct SmartPauseSettingsView: View {
    @Bindable var settings: Settings

    var body: some View {
        Form {
            Section {
                Toggle("Pause during meetings", isOn: $settings.meetingDetection)
                Text("Pauses while you're in Zoom, Teams, Slack, Discord, FaceTime, or similar apps. Browser meetings (Google Meet, Around) aren't auto-detected — use \"Pause for 1 hour\" from the menu bar.")
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
        }
        .formStyle(.grouped)
    }
}

