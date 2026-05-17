import Foundation
import os

// MARK: - ReminderCoordinator
//
// Purpose: Decides when each ReminderTrack fires, holds the live state of any
// currently-presented reminder, and resolves conflicts when two tracks try to
// surface at once.
//
// Architecture role: Core scheduling logic. Knows about tracks and how they
// should be presented; does NOT know how to draw a window or play a sound.
// Side-effect dispatch goes out through `presentHandler` / `dismissHandler`
// closures that the App layer wires to the right UI controllers.
//
// Key types defined:
//   - CoordinatorPhase: the public state-of-the-world (working / firing / deferred)
//   - ReminderCoordinator: the actor itself
//
// Used by:
//   - BreakWellApp (constructs it, hands it tracks + handlers)
//   - OverlayPresenter, BreakSoundPlayer, PreBreakNotifier (observe phaseStream)
//   - SchedulerViewModel (bridges actor state into SwiftUI)
//
// Depends on:
//   - os.Logger — Apple's structured logging API, replaces print()
//
// Swift concepts a learner will see here:
//   - actor: isolates mutable state for safe concurrent access. Calls into
//     an actor from outside are implicitly async (the caller "hops in").
//   - AsyncStream<T>: an async-iterable sequence. Used here to publish phase
//     changes to observers without callbacks or KVO.
//   - Task { ... }: kicks off concurrent work that may outlive the current call.
//   - [weak self]: avoids retain cycles when long-lived closures capture the
//     actor that owns them.
//   - nonisolated: marks code that doesn't need the actor's protection, letting
//     non-actor callers use it without `await`.

/// Phase model exposed to the rest of the app. Replaces phase 1's `BreakPhase`.
///
/// The coordinator emits one of these values via `phaseStream()` whenever
/// scheduling state changes. UI layers (SchedulerViewModel, MenuBarView)
/// observe this stream to render the right thing.
///
/// - Note: `nonisolated` here means the enum value itself can cross actor
///   boundaries freely (it's a `Sendable` value type). Without this, passing
///   a `CoordinatorPhase` from the actor to MainActor would require an `await`.
nonisolated enum CoordinatorPhase: Sendable, Equatable {
    /// Counting down to the next overlay-level track that's due to fire.
    /// `remaining` is the number of seconds left.
    case working(remaining: TimeInterval)

    /// An overlay-level track is currently presenting. The countdown ticks
    /// down each second; when it hits 0 the coordinator transitions out.
    case firing(remaining: TimeInterval, content: ReminderContent)

    /// A track was due to fire while suppressed (user is in a meeting, etc.).
    /// Held until suppression clears, then fires within a grace window — or
    /// is absorbed into the next cycle if too much time passed.
    case deferred(since: Date, content: ReminderContent)
}

/// A break that the user chose to "snooze" (deferred without rescheduling
/// the next firing). Conceptually: "I see the break, not right now, leave
/// a marker so I can take it on my own terms."
///
/// Lifecycle:
///   - Created when `ReminderCoordinator.snooze(trackId:)` is called
///   - Cleared when the user either takes the break (via
///     `takeSnoozedBreak(trackId:)`) or explicitly cancels it (via
///     `clearSnooze(trackId:)`)
///   - Also auto-cleared when the same track fires naturally — the new
///     firing supersedes the snoozed marker (the user is being asked
///     again anyway)
///   - NOT persisted across app restarts: a stale snooze from yesterday
///     would feel buggy
nonisolated struct SnoozedReminder: Equatable, Sendable {
    let trackId: String
    let snoozedAt: Date
    /// The break duration that *would* have run if the user took it.
    /// Stored on the snoozed marker so the indicator UI (and any future
    /// "take snoozed break" path) doesn't have to look the track up.
    let originalDuration: Duration
    /// When the next firing for this track is currently scheduled. The
    /// indicator uses this to draw a circular progress ring showing time
    /// until the break re-fires — `(now - snoozedAt) / (nextFireAt - snoozedAt)`.
    let nextFireAt: Date
}

/// Owns one or more `ReminderTrack`s and is the single source of truth for
/// "what should be on screen right now."
///
/// `ReminderCoordinator` is an `actor`: Swift guarantees only one task at a
/// time mutates its internal state. We rely on that because the coordinator
/// is poked by three concurrent sources — a 1-second tick task, UI button
/// taps, and suppression-signal updates — that would otherwise race.
///
/// The coordinator does not present UI itself. It emits state changes via
/// `phaseStream()` and invokes the `presentHandler` / `dismissHandler`
/// closures it was constructed with. The App layer wires those to the right
/// `NSWindow` controllers.
///
/// Example usage:
/// ```swift
/// let coordinator = ReminderCoordinator(
///     tracks: [shortBreak, waterTrack],
///     presentHandler: { content in /* show appropriate UI */ },
///     dismissHandler: { level in /* hide appropriate UI */ }
/// )
/// await coordinator.start()
/// ```
///
/// - Note: Because this is an actor, every method called from outside is
///   implicitly `async`. That's the cost of safe shared state.
actor ReminderCoordinator {
    // os.Logger is Apple's structured logging API. It's lighter than print()
    // and shows up in Console.app filtered by subsystem + category.
    private let logger = Logger(subsystem: "com.prabin.BreakWell", category: "scheduler")

    private var tracks: [any ReminderTrack] = []
    private var nextFireDates: [String: Date] = [:]

    // `@Sendable` marks these closures as safe to invoke from any actor /
    // thread context. Keeping them as `let` (vs `var`) means they can't be
    // swapped at runtime, which makes the actor's behavior easier to reason about.
    private let presentHandler: (@Sendable (ReminderContent) -> Void)?
    private let dismissHandler: (@Sendable (InterruptionLevel) -> Void)?

    // `private(set)` exposes the value for reading but keeps mutation
    // actor-private. External readers still cross the actor boundary (and
    // pay an `await`) when they touch this.
    private(set) var phase: CoordinatorPhase = .working(remaining: 0)
    private var tickTask: Task<Void, Never>?

    // Stream continuations keyed by UUID so we can clean up individual
    // subscribers when their stream terminates (see `phaseStream()` below).
    private var continuations: [UUID: AsyncStream<CoordinatorPhase>.Continuation] = [:]
    /// Separate stream that yields a track ID when a firing reaches the
    /// end of its duration naturally (i.e. the user did NOT skip or
    /// preempt). Used by stat counters that want to track completed
    /// breaks, not initiated ones.
    private var completionContinuations: [UUID: AsyncStream<String>.Continuation] = [:]
    /// Snapshots of `snoozedReminders` published whenever the list
    /// changes. UI layers subscribe to drive a persistent "break pending"
    /// indicator without polling.
    private var snoozeContinuations: [UUID: AsyncStream<[SnoozedReminder]>.Continuation] = [:]

    /// Breaks the user has snoozed and not yet taken or cancelled.
    /// `private(set)` so external readers can snapshot the current list
    /// across the actor boundary; mutation only happens through the
    /// `snooze` / `takeSnoozedBreak` / `clearSnooze` methods.
    private(set) var snoozedReminders: [SnoozedReminder] = []

    private var isSuppressed = false
    private var deferredFireAt: Date?
    private let postDeferralGrace: TimeInterval = 5

    // MARK: - Conflict resolution state

    /// Snapshot of the currently-presented surface. Used by `tryShow` to
    /// resolve cross-priority conflicts (overlay preempts card, etc.).
    private struct ShowingState {
        let track: any ReminderTrack
        let presentedAt: Date
        // Task is reference-typed; storing it inside a value-typed struct is
        // fine because we only ever cancel it via this reference.
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
            // `track.interval` is a `Duration`. Our `.seconds` extension
            // (ReminderTrack.swift) converts it to a TimeInterval (Double seconds).
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

    /// Kick off the 1-second tick loop. Idempotent: calling twice is a no-op.
    func start() {
        guard tickTask == nil else { return }
        recomputeWorkingState()
        logger.info("started — tracks: \(self.tracks.count)")
        // `Task { ... }` schedules a new concurrent task. `[weak self]`
        // prevents the task from retaining the actor — without it, the task
        // would keep the actor alive forever and `stop()` couldn't deinit.
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                // Apple's Duration-based sleep API. The `try?` swallows
                // CancellationError, which is fine because the while-loop
                // already checks `Task.isCancelled` on the next iteration.
                try? await Task.sleep(for: .seconds(1))
                // Crossing into the actor — implicit `await`. The actor's
                // serial executor ensures `tick()` doesn't race other methods.
                await self?.tick()
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - Track management

    /// Replace or add a track and reset its next-fire date to now + interval.
    /// This intentionally restarts the countdown when a user edits the work
    /// interval in Settings; if you'd rather preserve elapsed time, change
    /// the body here.
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

    /// Push a track's next firing further into the future. Used by the
    /// pre-break heads-up's snooze button (in tandem with `snooze` so the
    /// imminent firing doesn't immediately supersede the snooze marker).
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

    /// User explicitly asked for a break. Preempts whatever's currently
    /// showing rather than going through priority resolution — the user's
    /// intent overrides the schedule.
    func takeBreakNow() {
        guard let track = tracks.first(where: { $0.interruption == .overlay }) ?? tracks.first else { return }
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

    // MARK: - Snooze (defer with persistent indicator)

    /// Dismiss the currently-firing break for `trackId` and record a
    /// `SnoozedReminder` so the UI can show a persistent "break pending"
    /// indicator.
    ///
    /// - Parameters:
    ///   - trackId: which track the snooze applies to.
    ///   - postponeBy: optional override for the next-fire date. When
    ///     supplied, the next firing is rescheduled to `now + postponeBy`
    ///     (this is what the overlay's "+5m / +10m / +15m" buttons want).
    ///     When nil, the regular schedule continues unmodified — useful
    ///     for "wait for next scheduled break" semantics.
    ///
    /// If a snooze already exists for the same track, it's replaced —
    /// snoozing the "same break" twice doesn't accumulate markers.
    func snooze(trackId: String, postponeBy seconds: TimeInterval? = nil) {
        guard let track = tracks.first(where: { $0.id == trackId }) else { return }

        let now = Date()

        // If the break is currently on screen for this track, dismiss it.
        // (The snooze command can also be invoked from the heads-up,
        // which is before the firing — in that case there's nothing
        // currently firing for us to clear.) `endFiring` resets
        // `nextFireDates[trackId]` to `now + interval`, which we may
        // overwrite below if the caller specified an explicit postpone.
        if case .firing(_, let content) = phase, content.trackID == trackId {
            endFiring()
        }

        // Caller-supplied postpone: place the next firing exactly
        // `seconds` from now (overriding the auto-reschedule above).
        if let seconds {
            nextFireDates[trackId] = now.addingTimeInterval(seconds)
            if case .working = phase {
                recomputeWorkingState()
            }
        }

        // Capture whatever next-fire date is now scheduled — could be
        // from endFiring's auto-reschedule, the explicit postpone above,
        // or (worst-case fallback) snoozedAt itself if neither path ran.
        // The indicator uses this to draw its progress ring.
        let nextFireAt = nextFireDates[trackId] ?? now

        let entry = SnoozedReminder(
            trackId: trackId,
            snoozedAt: now,
            originalDuration: track.duration,
            nextFireAt: nextFireAt
        )
        snoozedReminders.removeAll { $0.trackId == trackId }
        snoozedReminders.append(entry)
        publishSnoozedReminders()

        let postponeNote = seconds.map { " (refire in \(Int($0))s)" } ?? ""
        logger.info("snoozed \(trackId)\(postponeNote)")
    }

    /// Take a previously-snoozed break right now. Removes the snooze
    /// marker and immediately presents the break (preempting anything
    /// currently on screen). The next-fire date is left alone — taking
    /// the snoozed break counts as fulfilling this cycle, and `endFiring`
    /// will reschedule normally when the break completes.
    func takeSnoozedBreak(trackId: String) {
        guard let track = tracks.first(where: { $0.id == trackId }) else { return }
        guard snoozedReminders.contains(where: { $0.trackId == trackId }) else {
            // Idempotent — if the snooze isn't there (already taken /
            // cleared / superseded), nothing to do.
            return
        }

        snoozedReminders.removeAll { $0.trackId == trackId }
        publishSnoozedReminders()

        if let current = currentlyShowing {
            preempt(current.track)
        }
        present(track)
        logger.info("→ took snoozed break \(trackId)")
    }

    /// Cancel a snoozed break without taking it. The indicator goes away;
    /// the regular schedule continues uninterrupted.
    func clearSnooze(trackId: String) {
        guard snoozedReminders.contains(where: { $0.trackId == trackId }) else { return }
        snoozedReminders.removeAll { $0.trackId == trackId }
        publishSnoozedReminders()
        logger.info("cleared snooze \(trackId)")
    }

    func takeDeferredBreakNow() {
        guard case .deferred(_, let content) = phase,
              let track = tracks.first(where: { $0.id == content.trackID }) else { return }
        deferredFireAt = nil
        tryShow(track)
        logger.info("→ deferred \(content.trackID) taken manually")
    }

    /// Driven by `SuppressionEngine`. Same defer/grace/absorb semantics as
    /// phase 2: while suppressed, an overlay that wants to fire enters the
    /// `.deferred` phase; when suppression clears we either fire after a
    /// short grace or absorb it into the next cycle.
    func setSuppressed(_ suppressed: Bool) {
        guard suppressed != isSuppressed else { return }
        isSuppressed = suppressed
        logger.info("suppressed: \(suppressed)")
        handleSuppressionChange()
    }

    // MARK: - Observation

    /// Hands out an `AsyncStream` of phase changes. Each subscriber gets its
    /// own continuation; the actor multicasts to all of them on every change.
    ///
    /// Usage:
    /// ```swift
    /// for await phase in await coordinator.phaseStream() {
    ///     // react to the new phase
    /// }
    /// ```
    func phaseStream() -> AsyncStream<CoordinatorPhase> {
        AsyncStream { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            // Send the current phase immediately so subscribers don't sit
            // idle until the next state change.
            continuation.yield(self.phase)
            // `onTermination` fires when the consumer iterator goes away or
            // calls `.finish()`. We use it to clean up our continuation
            // bookkeeping — without this, the dict would grow forever.
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                // We're outside the actor here (this closure runs on whatever
                // thread the consumer was on), so we hop back in via Task.
                Task { await self.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    /// Yields a track ID whenever a firing ends naturally (timer ran out;
    /// the user did NOT skip and the firing was NOT preempted). Subscribers
    /// can filter by trackID prefix (`"break."`, `"water"`, etc.) to count
    /// only the completions they care about.
    func completionStream() -> AsyncStream<String> {
        AsyncStream { continuation in
            let id = UUID()
            self.completionContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeCompletionContinuation(id) }
            }
        }
    }

    private func removeCompletionContinuation(_ id: UUID) {
        completionContinuations.removeValue(forKey: id)
    }

    /// Yields the full list of currently-snoozed reminders whenever it
    /// changes. UI layers subscribe to drive the persistent indicator(s)
    /// without polling. The current snapshot is yielded immediately on
    /// subscribe so newly-attached views don't sit idle until the next
    /// mutation.
    func snoozedRemindersStream() -> AsyncStream<[SnoozedReminder]> {
        AsyncStream { continuation in
            let id = UUID()
            self.snoozeContinuations[id] = continuation
            continuation.yield(self.snoozedReminders)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeSnoozeContinuation(id) }
            }
        }
    }

    private func removeSnoozeContinuation(_ id: UUID) {
        snoozeContinuations.removeValue(forKey: id)
    }

    /// Broadcast the current `snoozedReminders` snapshot. Called after
    /// every mutation so subscribers stay in lockstep with the actor's
    /// own copy.
    private func publishSnoozedReminders() {
        let snapshot = snoozedReminders
        for cont in snoozeContinuations.values { cont.yield(snapshot) }
    }

    // MARK: - Internals

    private func setPhase(_ newPhase: CoordinatorPhase) {
        phase = newPhase
        for cont in continuations.values { cont.yield(newPhase) }
    }

    /// The 1-second heartbeat. Driven by the `tickTask` started in `start()`.
    /// Handles three phase branches: `working` (look for due tracks),
    /// `firing` (count the current break down), `deferred` (wait for the
    /// post-suppression grace).
    private func tick() {
        switch phase {
        case .working:
            let now = Date()
            // Sort by priority descending so the highest-priority track gets
            // the first crack at presenting; lower-priority tracks behind it
            // get deferred via `tryShow`.
            let due = tracks
                .filter { (nextFireDates[$0.id] ?? .distantFuture) <= now }
                .sorted { $0.interruption.priority > $1.interruption.priority }

            for track in due {
                if isSuppressed {
                    // Every shipped track is overlay-level, so suppression
                    // always routes through the explicit `.deferred` phase.
                    // If a future surface lands at a lower interruption
                    // level, branch here.
                    let content = track.makeContent()
                    setPhase(.deferred(since: now, content: content))
                    logger.info("→ \(track.id) deferred (suppressed)")
                    for other in due where other.id != track.id {
                        nextFireDates[other.id] = now.addingTimeInterval(other.interval.seconds)
                    }
                    return
                } else {
                    tryShow(track)
                }
            }

            // If tryShow transitioned us into firing/deferred we shouldn't
            // overwrite that; only recompute when we're still in `.working`.
            if case .working = phase {
                recomputeWorkingState()
            }

        case .firing(let remaining, let content):
            let next = remaining - 1
            if next <= 0 {
                // Natural completion — emit on the dedicated stream BEFORE
                // endFiring so subscribers see the same trackID we're about
                // to clear. skipBreak() and preempt() also call endFiring,
                // but neither emits, which is the point of this branch.
                let trackID = content.trackID
                for cont in completionContinuations.values { cont.yield(trackID) }
                endFiring()
                logger.info("→ \(trackID) finished")
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

    /// Decide whether `track` should present now, preempt the current surface,
    /// or defer for later. Called for every due track every tick.
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

        // Any snooze marker for this track is now stale — the new firing
        // supersedes it. `takeSnoozedBreak` removes its own entry before
        // calling here, so the only callers that hit a non-empty match
        // are the natural-cadence paths (tick, takeBreakNow, deferred
        // catch-up). Broadcast only when something actually changed.
        if snoozedReminders.contains(where: { $0.trackId == track.id }) {
            snoozedReminders.removeAll { $0.trackId == track.id }
            publishSnoozedReminders()
        }

        switch track.interruption {
        case .overlay:
            let content = track.makeContent()
            setPhase(.firing(remaining: track.duration.seconds, content: content))
            // Next-fire date is set in endFiring after the firing concludes,
            // so the interval starts counting from when the user actually
            // finishes the break — not when the break began.
            currentlyShowing = ShowingState(track: track, presentedAt: presentedAt, expirationTask: nil)
        }
    }

    private func preempt(_ track: any ReminderTrack) {
        // Cancel the auto-clear task — we're about to mark the slot empty
        // ourselves, and we don't want a stale callback later.
        currentlyShowing?.expirationTask?.cancel()
        currentlyShowing = nil

        switch track.interruption {
        case .overlay:
            endFiring()
        }
    }

    private func deferTrack(_ track: any ReminderTrack) {
        let count = (deferralCounts[track.id] ?? 0) + 1
        if count > maxDeferrals {
            // Drop the deferral and put the track back on its normal schedule;
            // accumulating deferrals forever would result in a thundering herd
            // when the conflict finally clears.
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
        // Guard against a stale task firing after the user already replaced
        // the showing track (or we preempted it).
        guard let current = currentlyShowing, current.track.id == trackID else { return }
        currentlyShowing = nil
        logger.info("\(trackID) presentation slot freed")
    }

    private func endFiring() {
        deferredFireAt = nil
        if case .firing(_, let content) = phase,
           let track = tracks.first(where: { $0.id == content.trackID }) {
            // Schedule the next firing from "now" rather than "when this break
            // began" — keeps the interval honest if the user extended the break.
            nextFireDates[track.id] = Date().addingTimeInterval(track.interval.seconds)
        }
        currentlyShowing = nil
        recomputeWorkingState()
    }

    /// Compute "next break in X seconds" from the soonest overlay-level track.
    /// Banner / card tracks intentionally don't count here — they're not breaks.
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
            // We waited longer than a full work interval — fold this break
            // into the next cycle rather than firing a back-to-back break.
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
