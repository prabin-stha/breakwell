import Foundation

// MARK: - BreakContent
//
// Purpose: Content + presentation metadata for one kind of break. Title,
// instruction, sound, and an optional rotation of alternate prompts.
//
// Architecture role: Features/Break entry point. The break feature treats
// "what kind of break is this?" as data rather than code — adding a new
// break type (long break, mindfulness, posture) is one `static let` here,
// not a new track class.
//
// About the Features/Break folder:
// Everything related to "a break" lives here — the track that schedules
// it, the overlay that draws it, the random message pool, and the sound
// player. Files here may import AppKit / SwiftUI freely. Generic scheduling
// logic that doesn't know about breaks specifically stays in Core/.
//
// Key types defined:
//   - BreakContent: the value type
//   - BreakContent.shortBreak: the default preset used by the shipped
//     short-break track. (Long-break preset will join later.)
//
// Used by:
//   - BreakTrack (carries a `content: BreakContent` field; reads title /
//     instruction / soundName when building ReminderContent)
//   - BreakOverlayView (receives the rotating prompt via BreakMessage)
//   - BreakSoundPlayer (reads soundName via the firing's ReminderContent)
//
// Swift concepts a learner will see here:
//   - extension on the same type for static members: `extension BreakContent`
//     splits "default presets" from the type's core definition. Common
//     Swift idiom for keeping a struct's body lean.
//   - Optional fallback via `??`: `alternates.randomElement() ?? BreakMessage(...)`
//     returns the random pick if available, otherwise a constructed fallback.

/// Content + presentation metadata for a single break type. Future break
/// presets (long break, mindfulness, posture) become additional
/// `BreakContent` values; the `BreakTrack` type stays the same.
///
/// `Sendable` value type — safe to pass between actors (the coordinator and
/// the MainActor UI layer both read it).
struct BreakContent: Sendable, Equatable {
    let title: String
    let instruction: String
    let soundName: String?
    /// Optional rotation of varied prompts. If non-empty, the overlay picks
    /// one at random per firing; otherwise it falls back to `title` +
    /// `instruction` as the displayed copy.
    let alternates: [BreakMessage]
}

extension BreakContent {
    /// Default short-break content. Pulls its varied prompt rotation from
    /// `BreakMessages.pool` so each firing shows a different practical
    /// suggestion ("stand up and stretch", "get some water", etc.).
    static let shortBreak = BreakContent(
        title: "Time for a short break",
        instruction: "Step away from your screen for a few minutes.",
        soundName: "Glass",
        alternates: BreakMessages.pool
    )

    /// Pick a random prompt for this break. Falls back to a `BreakMessage`
    /// built from `title` + `instruction` if no alternates are configured.
    func randomMessage() -> BreakMessage {
        alternates.randomElement() ?? BreakMessage(title: title, description: instruction)
    }
}
