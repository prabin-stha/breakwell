import AppKit

/// Process-name based screen recording detection. Active when a known
/// recording/streaming app is running. Heuristic — running ≠ actively recording,
/// but for the apps in the list below, launching them usually does mean recording.
///
/// Excludes always-running utilities (CleanShot X, Snagit, QuickTime) that would
/// false-positive.
@MainActor
@Observable
final class ScreenSharingSignal: SuppressionSignal {
    private(set) var isActive: Bool = false
    private(set) var detectedAppName: String?

    var reason: String {
        if let detectedAppName {
            return "\(detectedAppName) is running"
        }
        return "Screen recording in progress"
    }

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            refresh()
        }
    }

    /// Apps where "process running" is a strong signal of active recording/streaming.
    /// Intentionally tight — false positives are worse than false negatives here.
    private let knownBundleIDs: Set<String> = [
        "com.obsproject.obs-studio",          // OBS Studio
        "com.streamlabs.streamlabs-obs",      // Streamlabs OBS
        "com.loom.desktop",                   // Loom
        "net.telestream.screenflow10",        // ScreenFlow 10
        "net.telestream.screenflow11"         // ScreenFlow 11 (bundle ID changes per version)
    ]

    @ObservationIgnored private var launchObserver: NSObjectProtocol?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?
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
        guard launchObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        launchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        terminateObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        guard enabled else {
            update(active: false, name: nil)
            return
        }
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  knownBundleIDs.contains(bundleID) else { continue }
            update(active: true, name: app.localizedName)
            return
        }
        update(active: false, name: nil)
    }

    private func update(active: Bool, name: String?) {
        let nameChanged = name != detectedAppName
        let activeChanged = active != isActive
        detectedAppName = active ? name : nil
        guard activeChanged || nameChanged else { return }
        isActive = active
        for cont in continuations.values { cont.yield() }
    }
}
