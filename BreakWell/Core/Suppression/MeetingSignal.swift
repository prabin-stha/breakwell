import AppKit

// MARK: - MeetingSignal
//
// Purpose: Detects "user is in a meeting" by matching the frontmost app
// against a list of known comms apps (Zoom, Teams, Slack, Discord,
// FaceTime, etc.).
//
// Architecture role: A SuppressionSignal in Core/Suppression. Cheap and
// permission-free — we don't ask for microphone access. Users on browser
// meetings (Google Meet, Around) can hit "Pause for 1 hour" manually.
//
// Key types defined:
//   - MeetingSignal: @Observable @MainActor class
//
// Used by:
//   - BreakWellApp (constructs)
//   - SettingsView (binds the enabled toggle)
//   - SuppressionEngine (subscribes to stateDidChange)
//
// Depends on:
//   - AppKit for NSWorkspace (frontmost-app observation)
//
// Swift concepts a learner will see here:
//   - didSet on a stored property: runs custom code every time the property
//     is assigned. Used here to re-apply the enabled flag when the user
//     toggles it.
//   - getpid(): C-level POSIX call available in Swift. Returns the current
//     process's PID — used to recognize "is this our own window?".
//   - Set<String>: O(1) membership lookup vs O(n) for an Array.

/// Detects "user is in a meeting" by checking whether the frontmost app's
/// bundle ID is on a known list. Process-only — no mic permission needed.
@MainActor
@Observable
final class MeetingSignal: SuppressionSignal {
    private(set) var isActive: Bool = false
    /// Friendly name of the detected meeting app (e.g. "Zoom") for the
    /// reason string. Nil when no meeting app is frontmost.
    private(set) var detectedAppName: String?

    var reason: String {
        if let detectedAppName {
            return "In \(detectedAppName)"
        }
        return "In a meeting"
    }

    /// User-toggleable. didSet re-applies when changed.
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            recompute()
        }
    }

    /// Known meeting app bundle identifiers. Intentionally narrow:
    /// - Only apps whose *primary* purpose is real-time meetings.
    /// - Excludes async-comms apps (Slack, Discord) — most time in those
    ///   isn't a meeting, so including them caused spurious pauses.
    /// - Excludes recording tools (Loom) — those are caught by the
    ///   screen-recording signal, which is the right signal for them.
    /// - Google Meet via Chrome isn't detectable from bundle ID alone
    ///   (Chrome is just a browser); users in browser meetings can hit
    ///   "Pause for 1 hour" manually.
    private let knownBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.microsoft.teams.work",
        "com.cisco.webexmeetingsapp",
        "Cisco-Systems.Spark",
        "com.apple.FaceTime",
        "com.google.meetings"
    ]

    private var processActive = false
    private var workspaceObserver: NSObjectProtocol?

    @ObservationIgnored private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    var stateDidChange: AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.continuations.removeValue(forKey: id)
                }
            }
        }
    }

    init(enabled: Bool = true) {
        self.enabled = enabled
    }

    func start() {
        guard workspaceObserver == nil else { return }
        // didActivateApplicationNotification fires every time the frontmost
        // app changes (cmd-tab, dock click, etc.). We refresh on every one.
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshProcessActive()
            }
        }
        refreshProcessActive()
    }

    // MARK: - Detection

    private func refreshProcessActive() {
        let frontApp = NSWorkspace.shared.frontmostApplication
        // If our own Settings window is frontmost, preserve the prior state.
        // The user's "real" foreground app (Zoom, Slack, etc.) hasn't
        // actually changed — they're just briefly looking at our window.
        // `getpid()` is the POSIX call that returns our PID.
        if frontApp?.processIdentifier == getpid() { return }
        let bundleID = frontApp?.bundleIdentifier ?? ""
        processActive = knownBundleIDs.contains(bundleID)
        if processActive {
            detectedAppName = frontApp?.localizedName
        }
        recompute()
    }

    private func recompute() {
        let nowActive = enabled && processActive
        if !nowActive {
            detectedAppName = nil
        }
        // Only yield to subscribers on a true on/off transition.
        guard nowActive != isActive else { return }
        isActive = nowActive
        for cont in continuations.values { cont.yield() }
    }
}
