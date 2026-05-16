import AppKit

// MARK: - ScreenSharingSignal
//
// Purpose: Detects "user is recording or sharing their screen" by watching
// for known recording apps to be running. A heuristic — running ≠ actively
// recording — but for the apps we list, launching them usually does mean a
// recording session is starting.
//
// Architecture role: A SuppressionSignal in Core/Suppression. Subscribes to
// NSWorkspace launch/terminate notifications and recomputes on each.
//
// Key types defined:
//   - ScreenSharingSignal: @Observable @MainActor class
//
// Used by:
//   - BreakWellApp (constructs)
//   - SuppressionEngine (subscribes to stateDidChange)
//
// Depends on:
//   - AppKit for NSWorkspace + NSRunningApplication
//
// Swift concepts a learner will see here:
//   - NotificationCenter observation via blocks: AppKit publishes events
//     through NSWorkspace.notificationCenter; we register a block and store
//     the returned observer token so we can deregister later.
//   - MainActor.assumeIsolated: the NSWorkspace observer block isn't tagged
//     @MainActor by AppKit but is actually called on the main thread. We
//     assert that fact to satisfy Swift 6 strict-concurrency checking.

/// Process-name based screen-recording detection. Active when one of a
/// curated list of recording apps is currently running. Heuristic — these
/// apps are launched specifically to record, so "running" is a reasonable
/// proxy for "actively recording".
///
/// Intentionally excludes always-running utilities like CleanShot X, Snagit,
/// and QuickTime — those tend to live in the menu bar 24/7 and would
/// false-positive every break.
///
/// - Note: We don't use ScreenCaptureKit's APIs here because macOS doesn't
///   expose "who is currently capturing the screen" publicly. The purple
///   recording dot's state isn't queryable.
@MainActor
@Observable
final class ScreenSharingSignal: SuppressionSignal {
    private(set) var isActive: Bool = false
    /// Localized name of the recording app we detected, for the reason string.
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

    /// Apps where "process running" is a strong signal of active recording
    /// or streaming. Intentionally tight — a false positive here means
    /// breaks get suppressed when nothing's actually being recorded, which
    /// is more annoying than missing a recording case.
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
        // didLaunchApplicationNotification fires when ANY app is launched —
        // we refresh and check whether the launched app is in our set.
        launchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The NSNotification block isn't typed @MainActor, but AppKit
            // delivers it on the main thread. Asserting that lets us call
            // MainActor-isolated methods without a Task hop.
            MainActor.assumeIsolated { self?.refresh() }
        }
        terminateObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Initial reading — in case a recording app was already running at launch.
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
        // Yield whenever EITHER the on/off state OR the detected name changes,
        // so the popover's reason string updates when one recording app quits
        // and another is still running.
        guard activeChanged || nameChanged else { return }
        isActive = active
        for cont in continuations.values { cont.yield() }
    }
}
