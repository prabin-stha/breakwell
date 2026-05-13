import AppKit

enum MeetingDetectionMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case processOnly
    case micActivity

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .processOnly: "By app (Zoom, Slack, Teams…)"
        case .micActivity: "By microphone activity (recommended)"
        }
    }
}

/// Detects "user is in a meeting" via two layered signals:
/// - **Process detection** — frontmost app is a known meeting/comms app (no permissions).
/// - **Microphone activity** — any process is using the default input device (CoreAudio HAL).
///
/// Active behavior depends on `mode`:
/// - `.off`           — never active
/// - `.processOnly`   — process path only
/// - `.micActivity`   — process path OR mic path
@MainActor
@Observable
final class MeetingSignal: SuppressionSignal {
    private(set) var isActive: Bool = false
    private(set) var detectedAppName: String?

    var reason: String {
        if let detectedAppName {
            return "In \(detectedAppName)"
        }
        return "In a meeting"
    }

    var mode: MeetingDetectionMode {
        didSet {
            guard mode != oldValue else { return }
            applyMode()
        }
    }

    /// Known meeting/comms app bundle identifiers. Google Meet via Chrome isn't
    /// detectable from bundle ID alone — but the mic-activity path catches it.
    private let knownBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.microsoft.teams.work",
        "com.cisco.webexmeetingsapp",
        "Cisco-Systems.Spark",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.apple.FaceTime",
        "com.google.meetings",
        "com.loom.desktop"
    ]

    private var processActive = false
    private var micActive = false
    private var workspaceObserver: NSObjectProtocol?
    private let micMonitor = AudioDeviceActivityMonitor(kind: .input)

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

    init(mode: MeetingDetectionMode = .processOnly) {
        self.mode = mode
        micMonitor.onChange = { [weak self] in
            guard let self else { return }
            self.micActive = self.micMonitor.isActive
            self.recompute()
        }
    }

    func start() {
        guard workspaceObserver == nil else { return }
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
        applyMode()
    }

    // MARK: - Mode handling

    private func applyMode() {
        switch mode {
        case .off, .processOnly:
            micMonitor.stop()
            micActive = false
        case .micActivity:
            micMonitor.start()
        }
        recompute()
    }

    // MARK: - Detection paths

    private func refreshProcessActive() {
        let frontApp = NSWorkspace.shared.frontmostApplication
        // If our own Settings window is frontmost, preserve the prior state —
        // the user's actual context (Zoom, Slack, etc.) hasn't really changed.
        if frontApp?.processIdentifier == getpid() { return }
        let bundleID = frontApp?.bundleIdentifier ?? ""
        processActive = knownBundleIDs.contains(bundleID)
        if processActive {
            detectedAppName = frontApp?.localizedName
        }
        recompute()
    }

    private func recompute() {
        let nowActive: Bool
        switch mode {
        case .off:
            nowActive = false
        case .processOnly:
            nowActive = processActive
        case .micActivity:
            nowActive = processActive || micActive
        }

        // Clear the friendly app name if we're not active *or* the mic is what's
        // driving us (generic "In a meeting" copy).
        if !nowActive || (mode == .micActivity && micActive && !processActive) {
            detectedAppName = nil
        }

        guard nowActive != isActive else { return }
        isActive = nowActive
        for cont in continuations.values { cont.yield() }
    }
}
