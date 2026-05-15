import Foundation

/// Central knob for converting "minutes" (from settings UIs) into real
/// `TimeInterval` seconds. Change this in one place to switch the whole app
/// between production timing and fast-iteration testing.
///
/// - `60` — production: a settings "minute" is a real minute.
/// - `1`  — testing: a settings "minute" compresses to one real second.
enum AppTiming {
    static let secondsPerMinute: TimeInterval = 60
}

extension Int {
    /// Treat self as a count of "minutes" (typically from a settings stepper)
    /// and convert to seconds, respecting `AppTiming.secondsPerMinute`.
    var minutesAsSeconds: TimeInterval {
        TimeInterval(self) * AppTiming.secondsPerMinute
    }
}
