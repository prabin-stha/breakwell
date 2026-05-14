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
    private var groupingEngine = GroupingEngine()
    private let bannerHandler: (@Sendable (ReminderContent) -> Void)?

    private(set) var phase: CoordinatorPhase = .working(remaining: 0)
    private var tickTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<CoordinatorPhase>.Continuation] = [:]

    private var isSuppressed = false
    private var deferredFireAt: Date?
    private let postDeferralGrace: TimeInterval = 5

    init(tracks: [any ReminderTrack], bannerHandler: (@Sendable (ReminderContent) -> Void)? = nil) {
        let now = Date()
        for track in tracks {
            nextFireDates[track.id] = now.addingTimeInterval(track.interval.seconds)
        }
        self.tracks = tracks
        self.bannerHandler = bannerHandler
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

    /// Replace (or add) a track. Resets its next-fire date to now + new interval.
    /// Matches phase 1's "edit work interval = restart countdown" behavior.
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

    /// Add more time to the currently firing break. Called from the overlay's
    /// "+5 min · extend break" button — the user wants to rest longer.
    func extendCurrentBreak(by seconds: TimeInterval) {
        guard case .firing(let remaining, let content) = phase else { return }
        setPhase(.firing(remaining: remaining + seconds, content: content))
        logger.info("extended \(content.trackID) by \(Int(seconds))s")
    }

    /// Push a track's next firing further into the future. Used by the
    /// pre-break heads-up's snooze buttons.
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

    /// Fire an overlay-level track immediately. For phase 2.5 milestone 1 this
    /// means the eye-rest track; later it will pick the relevant overlay track.
    func takeBreakNow() {
        guard let track = tracks.first(where: { $0.interruption == .overlay }) ?? tracks.first else { return }
        startFiring(track: track)
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
        startFiring(track: track)
        logger.info("→ deferred \(content.trackID) taken manually")
    }

    /// Driven by `SuppressionEngine`. Same defer/grace/absorb semantics as phase 2.
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

            // Banner tracks (water etc.) fire as side effects. They don't
            // change the phase and aren't considered a "break" — the working
            // countdown stays focused on eye-rest.
            let dueBanners = tracks.filter {
                $0.interruption == .banner &&
                (nextFireDates[$0.id] ?? .distantFuture) <= now
            }
            for track in dueBanners {
                if !isSuppressed {
                    bannerHandler?(track.makeContent())
                    logger.info("→ \(track.id) banner sent")
                }
                nextFireDates[track.id] = now.addingTimeInterval(track.interval.seconds)
            }

            // Overlay tracks (eye-rest etc.) drive the phase via the grouping engine.
            let overlayTracks = tracks.filter { $0.interruption == .overlay }
            let group = groupingEngine.tracksToFire(
                now: now,
                tracks: overlayTracks,
                nextFireDates: nextFireDates
            )

            if let primary = group.first {
                if isSuppressed {
                    let content = primary.makeContent()
                    setPhase(.deferred(since: now, content: content))
                    logger.info("→ \(primary.id) deferred")
                } else {
                    startFiring(track: primary)
                }
            } else {
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
                startFiring(track: track)
                logger.info("→ \(content.trackID) deferred firing now")
            }
        }
    }

    private func startFiring(track: any ReminderTrack) {
        // Overlay-level firings only — banner tracks are handled inline in tick().
        guard track.interruption == .overlay else {
            logger.error("startFiring called on non-overlay track \(track.id) — ignoring")
            return
        }
        let content = track.makeContent()
        let dur = track.duration.seconds
        setPhase(.firing(remaining: dur, content: content))
        // Next-fire date is set in endFiring so it's always "interval after this
        // firing actually ended" — robust to tick-timing drift.
    }

    private func endFiring() {
        deferredFireAt = nil
        if case .firing(_, let content) = phase,
           let track = tracks.first(where: { $0.id == content.trackID }) {
            nextFireDates[track.id] = Date().addingTimeInterval(track.interval.seconds)
        }
        recomputeWorkingState()
    }

    private func recomputeWorkingState() {
        let now = Date()
        // Only overlay-level tracks influence the working countdown — banners
        // (water, etc.) are not "breaks" and don't appear in "Next break in X".
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
