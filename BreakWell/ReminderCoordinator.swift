import Foundation
import os

/// Phase model exposed to the rest of the app. Replaces phase 1's `BreakPhase`.
nonisolated enum CoordinatorPhase: Sendable, Equatable {
    /// Counting down to the next track that's due to fire.
    case working(remaining: TimeInterval)
    /// A track is currently firing — countdown until it ends.
    case firing(remaining: TimeInterval, content: ReminderContent)
    /// A track was due to fire while suppressed; held until clear or absorbed.
    case deferred(since: Date, content: ReminderContent)
}

/// Owns one or more `ReminderTrack`s and drives their schedules.
/// Single source of truth for "what should be firing right now."
actor ReminderCoordinator {
    private let logger = Logger(subsystem: "com.prabin.BreakWell", category: "coordinator")

    private var tracks: [any ReminderTrack] = []
    private var nextFireDates: [String: Date] = [:]
    private let presentHandler: (@Sendable (ReminderContent) -> Void)?
    private let dismissHandler: (@Sendable (InterruptionLevel) -> Void)?

    private(set) var phase: CoordinatorPhase = .working(remaining: 0)
    private var tickTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<CoordinatorPhase>.Continuation] = [:]

    private var isSuppressed = false
    private var deferredFireAt: Date?
    private let postDeferralGrace: TimeInterval = 5

    // MARK: - Conflict resolution state

    private struct ShowingState {
        let track: any ReminderTrack
        let presentedAt: Date
        var expirationTask: Task<Void, Never>?
    }
    private var currentlyShowing: ShowingState?
    private var deferralCounts: [String: Int] = [:]
    private let preemptionDelay: TimeInterval = 120
    private let maxDeferrals = 3

    init(
        tracks: [any ReminderTrack],
        presentHandler: (@Sendable (ReminderContent) -> Void)? = nil,
        dismissHandler: (@Sendable (InterruptionLevel) -> Void)? = nil
    ) {
        let now = Date()
        for track in tracks {
            nextFireDates[track.id] = now.addingTimeInterval(track.interval.seconds)
        }
        self.tracks = tracks
        self.presentHandler = presentHandler
        self.dismissHandler = dismissHandler
        if let earliest = nextFireDates.values.min() {
            phase = .working(remaining: max(0, earliest.timeIntervalSince(now)))
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard tickTask == nil else { return }
        recomputeWorkingState()
        logger.info("started — tracks: \(self.tracks.count)")
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.tick()
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - Track management

    func updateTrack(_ track: any ReminderTrack) {
        if let i = tracks.firstIndex(where: { $0.id == track.id }) {
            tracks[i] = track
        } else {
            tracks.append(track)
        }
        nextFireDates[track.id] = Date().addingTimeInterval(track.interval.seconds)
        if case .working = phase {
            recomputeWorkingState()
        }
        logger.info("track \(track.id) updated: interval=\(Int(track.interval.seconds))s duration=\(Int(track.duration.seconds))s")
    }

    /// Add more time to the currently firing break.
    func extendCurrentBreak(by seconds: TimeInterval) {
        guard case .firing(let remaining, let content) = phase else { return }
        setPhase(.firing(remaining: remaining + seconds, content: content))
        logger.info("extended \(content.trackID) by \(Int(seconds))s")
    }

    /// Push a track's next firing further into the future.
    func postponeFire(trackID: String, by seconds: TimeInterval) {
        guard let current = nextFireDates[trackID] else { return }
        nextFireDates[trackID] = current.addingTimeInterval(seconds)
        if case .working = phase {
            recomputeWorkingState()
        }
        logger.info("postponed \(trackID) by \(Int(seconds))s")
    }

    func removeTrack(id: String) {
        tracks.removeAll { $0.id == id }
        nextFireDates.removeValue(forKey: id)
        if case .working = phase {
            recomputeWorkingState()
        }
        logger.info("track \(id) removed")
    }

    // MARK: - Commands (from UI)

    func takeBreakNow() {
        guard let track = tracks.first(where: { $0.interruption == .overlay }) ?? tracks.first else { return }
        // User explicitly asked for a break — preempt whatever's showing.
        if let current = currentlyShowing {
            preempt(current.track)
        }
        present(track)
        logger.info("→ manual fire \(track.id)")
    }

    func skipBreak() {
        if case .firing = phase {
            endFiring()
        }
    }

    func takeDeferredBreakNow() {
        guard case .deferred(_, let content) = phase,
              let track = tracks.first(where: { $0.id == content.trackID }) else { return }
        deferredFireAt = nil
        tryShow(track)
        logger.info("→ deferred \(content.trackID) taken manually")
    }

    func setSuppressed(_ suppressed: Bool) {
        guard suppressed != isSuppressed else { return }
        isSuppressed = suppressed
        logger.info("suppressed: \(suppressed)")
        handleSuppressionChange()
    }

    // MARK: - Observation

    func phaseStream() -> AsyncStream<CoordinatorPhase> {
        AsyncStream { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            continuation.yield(self.phase)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    // MARK: - Internals

    private func setPhase(_ newPhase: CoordinatorPhase) {
        phase = newPhase
        for cont in continuations.values { cont.yield(newPhase) }
    }

    private func tick() {
        switch phase {
        case .working:
            let now = Date()
            let due = tracks
                .filter { (nextFireDates[$0.id] ?? .distantFuture) <= now }
                // High priority first so it wins any conflict resolution.
                .sorted { $0.interruption.priority > $1.interruption.priority }

            for track in due {
                if isSuppressed {
                    if track.interruption == .overlay {
                        // Overlay suppression uses the existing .deferred phase.
                        let content = track.makeContent()
                        setPhase(.deferred(since: now, content: content))
                        logger.info("→ \(track.id) deferred (suppressed)")
                        // Other due tracks: skip silently this cycle.
                        for other in due where other.id != track.id {
                            nextFireDates[other.id] = now.addingTimeInterval(other.interval.seconds)
                        }
                        return
                    } else {
                        // Banner/card suppression: silently reschedule, no fire.
                        nextFireDates[track.id] = now.addingTimeInterval(track.interval.seconds)
                    }
                } else {
                    tryShow(track)
                }
            }

            // Only recompute when we didn't transition to firing/deferred.
            if case .working = phase {
                recomputeWorkingState()
            }

        case .firing(let remaining, let content):
            let next = remaining - 1
            if next <= 0 {
                endFiring()
                logger.info("→ \(content.trackID) finished")
            } else {
                setPhase(.firing(remaining: next, content: content))
            }

        case .deferred:
            if let fireAt = deferredFireAt, Date() >= fireAt {
                guard case .deferred(_, let content) = phase,
                      let track = tracks.first(where: { $0.id == content.trackID }) else { return }
                deferredFireAt = nil
                tryShow(track)
                logger.info("→ \(content.trackID) deferred firing now")
            }
        }
    }

    // MARK: - tryShow: priority-based conflict resolution

    /// Decide whether `track` should present now, preempt, or defer.
    private func tryShow(_ track: any ReminderTrack) {
        if let current = currentlyShowing {
            if track.interruption.priority > current.track.interruption.priority {
                logger.info("preempting \(current.track.id) for \(track.id)")
                preempt(current.track)
                present(track)
            } else {
                // Equal or lower priority → defer for 2 min, up to 3 attempts.
                deferTrack(track)
            }
        } else {
            present(track)
        }
    }

    private func present(_ track: any ReminderTrack) {
        deferralCounts[track.id] = 0
        let presentedAt = Date()

        switch track.interruption {
        case .overlay:
            let content = track.makeContent()
            setPhase(.firing(remaining: track.duration.seconds, content: content))
            // Next-fire date is set in endFiring after firing concludes.
            currentlyShowing = ShowingState(track: track, presentedAt: presentedAt, expirationTask: nil)

        case .prominentCard, .banner:
            let content = track.makeContent()
            // Schedule next firing immediately — banner/card don't block the cycle.
            nextFireDates[track.id] = presentedAt.addingTimeInterval(track.interval.seconds)
            // Auto-clear `currentlyShowing` after the track's duration, matching
            // the controller's own auto-dismiss. If the user closes it earlier
            // (skip / X), the slot stays "showing" until this timeout — a minor
            // imprecision we accept for the first cut.
            let durationSeconds = track.duration.seconds
            let trackID = track.id
            let expirationTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(durationSeconds))
                guard !Task.isCancelled else { return }
                await self?.handleExpiration(trackID: trackID)
            }
            currentlyShowing = ShowingState(track: track, presentedAt: presentedAt, expirationTask: expirationTask)
            presentHandler?(content)
            logger.info("→ \(track.id) presented (\(String(describing: track.interruption)))")

        case .menuBarPulse, .soundOnly:
            nextFireDates[track.id] = presentedAt.addingTimeInterval(track.interval.seconds)
        }
    }

    private func preempt(_ track: any ReminderTrack) {
        currentlyShowing?.expirationTask?.cancel()
        currentlyShowing = nil

        switch track.interruption {
        case .overlay:
            // Drop out of firing immediately. recomputeWorkingState below.
            endFiring()
        case .prominentCard, .banner:
            dismissHandler?(track.interruption)
        case .menuBarPulse, .soundOnly:
            break
        }
    }

    private func deferTrack(_ track: any ReminderTrack) {
        let count = (deferralCounts[track.id] ?? 0) + 1
        if count > maxDeferrals {
            deferralCounts[track.id] = 0
            nextFireDates[track.id] = Date().addingTimeInterval(track.interval.seconds)
            logger.info("dropping \(track.id) after \(self.maxDeferrals) deferrals")
            return
        }
        deferralCounts[track.id] = count
        nextFireDates[track.id] = Date().addingTimeInterval(preemptionDelay)
        logger.info("deferred \(track.id) +2min (attempt \(count) of \(self.maxDeferrals))")
    }

    private func handleExpiration(trackID: String) {
        guard let current = currentlyShowing, current.track.id == trackID else { return }
        currentlyShowing = nil
        logger.info("\(trackID) presentation slot freed")
    }

    private func endFiring() {
        deferredFireAt = nil
        if case .firing(_, let content) = phase,
           let track = tracks.first(where: { $0.id == content.trackID }) {
            nextFireDates[track.id] = Date().addingTimeInterval(track.interval.seconds)
        }
        currentlyShowing = nil
        recomputeWorkingState()
    }

    private func recomputeWorkingState() {
        let now = Date()
        let overlayDates = tracks
            .filter { $0.interruption == .overlay }
            .compactMap { nextFireDates[$0.id] }
        let nextAt = overlayDates.min() ?? now.addingTimeInterval(1)
        let remaining = max(0, nextAt.timeIntervalSince(now))
        setPhase(.working(remaining: remaining))
    }

    private func handleSuppressionChange() {
        guard case .deferred(let since, let content) = phase else { return }
        if isSuppressed {
            deferredFireAt = nil
            return
        }
        guard let track = tracks.first(where: { $0.id == content.trackID }) else { return }
        let elapsed = Date().timeIntervalSince(since)
        if elapsed >= track.interval.seconds {
            deferredFireAt = nil
            nextFireDates[track.id] = Date().addingTimeInterval(track.interval.seconds)
            recomputeWorkingState()
            logger.info("\(track.id) deferred absorbed (waited \(Int(elapsed))s)")
        } else {
            deferredFireAt = Date().addingTimeInterval(postDeferralGrace)
            logger.info("\(track.id) deferred firing in \(Int(self.postDeferralGrace))s")
        }
    }
}
