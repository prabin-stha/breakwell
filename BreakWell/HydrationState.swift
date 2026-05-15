import Foundation
import Observation

/// Persistent hydration state — last drink time, today's count, the day anchor
/// for reset logic. Exposes `recencyScore` (0–1) that decays linearly to zero
/// over `decayDuration`, refreshed every 5s so the popover bar drains live.
@MainActor
@Observable
final class HydrationState {
    private(set) var lastDrinkAt: Date?
    private(set) var todayCount: Int = 0
    private(set) var dayAnchor: Date

    /// Live recency value, refreshed in the background.
    private(set) var recencyScore: Double = 0

    /// Configurable from settings.
    var decayDuration: TimeInterval = 90 * 60
    /// Hour of day at which "today" resets (0–23, default 4 = 4am).
    var dailyResetHour: Int = 4 {
        didSet { rollOverIfNeeded() }
    }

    private let defaults: UserDefaults
    private enum Keys {
        static let blob = "hydrationState"
    }

    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Initialize dayAnchor before any other methods can run.
        self.dayAnchor = Self.computeAnchor(now: Date(), resetHour: 4)
        load()
        rollOverIfNeeded()
        recomputeRecencyScore()
        startRefresh()
    }

    // MARK: - Public commands

    func recordDrink() {
        rollOverIfNeeded()
        lastDrinkAt = Date()
        todayCount += 1
        save()
        recomputeRecencyScore()
    }

    /// User-friendly "Last drink X ago" string. Uses `Just now` for < 1 min.
    var lastDrinkText: String {
        guard let last = lastDrinkAt else { return "No drinks yet today" }
        let elapsed = Int(Date().timeIntervalSince(last).rounded())
        if elapsed < 60 { return "Just now" }
        let minutes = elapsed / 60
        if minutes < 60 { return "Last drink \(minutes) min ago" }
        let hours = minutes / 60
        let leftover = minutes % 60
        if leftover == 0 { return "Last drink \(hours)h ago" }
        return "Last drink \(hours)h \(leftover)m ago"
    }

    // MARK: - Refresh loop

    private func startRefresh() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.recomputeRecencyScore()
                self?.rollOverIfNeeded()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func recomputeRecencyScore() {
        guard let last = lastDrinkAt else {
            if recencyScore != 0 { recencyScore = 0 }
            return
        }
        let elapsed = Date().timeIntervalSince(last)
        let score = max(0, min(1, 1.0 - elapsed / decayDuration))
        if abs(score - recencyScore) > 0.001 {
            recencyScore = score
        }
    }

    // MARK: - Day rollover

    private func rollOverIfNeeded() {
        let current = Self.computeAnchor(now: Date(), resetHour: dailyResetHour)
        if current > dayAnchor {
            dayAnchor = current
            todayCount = 0
            save()
        }
    }

    /// Computes the most recent reset moment at or before `now`.
    /// E.g. if reset hour is 4 and now is 3am Tuesday, returns Monday 4am.
    private static func computeAnchor(now: Date, resetHour: Int) -> Date {
        let cal = Calendar.current
        let todayReset = cal.date(bySettingHour: resetHour, minute: 0, second: 0, of: now) ?? now
        if now < todayReset {
            return cal.date(byAdding: .day, value: -1, to: todayReset) ?? todayReset
        }
        return todayReset
    }

    // MARK: - Persistence (single JSON blob in UserDefaults)

    private struct Blob: Codable {
        let lastDrinkAt: Date?
        let todayCount: Int
        let dayAnchor: Date
    }

    private func save() {
        let blob = Blob(lastDrinkAt: lastDrinkAt, todayCount: todayCount, dayAnchor: dayAnchor)
        if let data = try? JSONEncoder().encode(blob) {
            defaults.set(data, forKey: Keys.blob)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: Keys.blob),
              let blob = try? JSONDecoder().decode(Blob.self, from: data) else { return }
        lastDrinkAt = blob.lastDrinkAt
        todayCount = blob.todayCount
        dayAnchor = blob.dayAnchor
    }
}
