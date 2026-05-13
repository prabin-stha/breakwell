import EventKit
import Foundation
import os

/// Active during a calendar event marked as "busy". Includes a pre-event buffer
/// (N minutes before the event starts). Reads from all calendars the user has
/// granted access to.
///
/// Requires full calendar access (macOS 14+ API: `requestFullAccessToEvents`).
/// Without it, the signal stays inactive — caller is responsible for requesting.
@MainActor
@Observable
final class CalendarSignal: SuppressionSignal {
    private let logger = Logger(subsystem: "com.prabin.BreakWell", category: "calendar")

    private(set) var isActive: Bool = false
    private(set) var currentEventTitle: String?

    var reason: String {
        if let currentEventTitle, !currentEventTitle.isEmpty {
            return "Calendar — \(currentEventTitle)"
        }
        return "Calendar event"
    }

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            recompute()
        }
    }

    var bufferMinutes: Int {
        didSet {
            guard bufferMinutes != oldValue else { return }
            recompute()
        }
    }

    private let store = EKEventStore()
    private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var changeObserver: NSObjectProtocol?
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

    init(enabled: Bool = false, bufferMinutes: Int = 2) {
        self.enabled = enabled
        self.bufferMinutes = bufferMinutes
    }

    func start() {
        guard pollTask == nil else { return }
        // Refresh when calendars change.
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recompute() }
        }
        // Time-based transitions (event start/end) need polling.
        // 30s cadence gives <30s lag for "meeting starts" — plenty fine.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.recompute()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Returns true if access is granted after the call.
    func requestAccessIfNeeded() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess:
            return true
        case .denied, .restricted:
            logger.info("calendar access denied/restricted")
            return false
        case .notDetermined, .writeOnly, .authorized:
            do {
                let granted = try await store.requestFullAccessToEvents()
                logger.info("calendar access requested: granted=\(granted)")
                if granted { recompute() }
                return granted
            } catch {
                logger.error("requestFullAccessToEvents failed: \(error.localizedDescription)")
                return false
            }
        @unknown default:
            return false
        }
    }

    private func recompute() {
        guard enabled else {
            update(active: false, title: nil)
            return
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            update(active: false, title: nil)
            return
        }

        let calendars = store.calendars(for: .event)
        let now = Date()
        let buffer = TimeInterval(bufferMinutes * 60)
        // ±1 hour window to catch in-progress events and upcoming ones within buffer.
        let windowStart = now.addingTimeInterval(-60 * 60)
        let windowEnd = now.addingTimeInterval(60 * 60)
        let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: calendars)
        let events = store.events(matching: predicate)

        for event in events {
            guard event.availability == .busy,
                  let startDate = event.startDate,
                  let endDate = event.endDate else { continue }
            let effectiveStart = startDate.addingTimeInterval(-buffer)
            if now >= effectiveStart && now < endDate {
                update(active: true, title: event.title)
                return
            }
        }
        update(active: false, title: nil)
    }

    private func update(active: Bool, title: String?) {
        let changed = (active != isActive) || (title != currentEventTitle)
        isActive = active
        currentEventTitle = title
        if changed {
            for cont in continuations.values { cont.yield() }
        }
    }
}
