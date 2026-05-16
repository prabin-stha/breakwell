import AppKit
import CoreAudio
import os

// MARK: - MediaPlaybackSignal
//
// Purpose: Detects "user is watching or listening to something" by checking
// whether the frontmost app is currently producing audio output.
//
// Architecture role: A SuppressionSignal in Core/Suppression. The audio
// query is per-process (not just "any audio anywhere"), so background music
// in another Space doesn't false-positive while you're working in silence.
//
// Key types defined:
//   - MediaPlaybackSignal: @Observable @MainActor class
//
// Used by:
//   - BreakWellApp (constructs)
//   - SuppressionEngine (subscribes to stateDidChange)
//
// Depends on:
//   - CoreAudio (process-object query — macOS 14+ API)
//   - AppKit for NSWorkspace.frontmostApplication
//
// Swift concepts a learner will see here:
//   - C interop with CoreAudio: AudioObjectGetPropertyData uses inout
//     pointers and raw selectors. Swift makes this verbose; the layout
//     `AudioObjectPropertyAddress(...)` + `AudioObjectGetPropertyData(...)`
//     is the canonical pattern for any HAL query.
//   - withUnsafeMutableBufferPointer: lets us pass an array's storage to a
//     C function expecting a pointer + length.

/// Active when the frontmost app is currently producing audio output.
/// Catches YouTube in any window size, video calls outside our known
/// meeting-app list, music in a fullscreen player, etc.
///
/// Uses macOS 14's per-process audio attribution
/// (`kAudioProcessPropertyIsRunningOutput`) so audio from background apps
/// in other Spaces doesn't trigger a false positive.
///
/// - Note: Polls every 5 seconds. CoreAudio doesn't push notifications for
///   process-level audio state, so polling is the simplest workable
///   approach. 5s is a balance between responsiveness and battery.
@MainActor
@Observable
final class MediaPlaybackSignal: SuppressionSignal {
    private let logger = Logger(subsystem: "com.prabin.BreakWell", category: "media")

    private(set) var isActive: Bool = false

    var reason: String { "Audio playing" }

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            recompute()
        }
    }

    private var frontmostHasAudio = false
    private var pollTask: Task<Void, Never>?

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
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func poll() {
        guard let front = NSWorkspace.shared.frontmostApplication else {
            update(audio: false)
            return
        }
        // If our own Settings window is frontmost, preserve the prior state
        // — same reasoning as MeetingSignal. The user's real audio context
        // (Safari, etc.) hasn't actually changed.
        if front.processIdentifier == getpid() { return }
        let audio = isProcessProducingAudio(pid: front.processIdentifier)
        update(audio: audio)
    }

    private func update(audio: Bool) {
        guard audio != frontmostHasAudio else { return }
        frontmostHasAudio = audio
        logger.info("frontmost audio: \(audio)")
        recompute()
    }

    private func recompute() {
        let nowActive = enabled && frontmostHasAudio
        guard nowActive != isActive else { return }
        isActive = nowActive
        for cont in continuations.values { cont.yield() }
    }

    // MARK: - Per-process audio check

    /// Asks "is this PID currently producing audio output?" via CoreAudio's
    /// process-object API. Doesn't require any permissions and doesn't
    /// capture any audio data — just reads metadata about who's playing.
    ///
    /// The CoreAudio C API is verbose. The shape is always:
    ///  1. Make an `AudioObjectPropertyAddress` describing what you want.
    ///  2. Call `AudioObjectGetPropertyDataSize` to learn how big the
    ///     result is.
    ///  3. Allocate enough room, call `AudioObjectGetPropertyData` to fill it.
    ///
    /// We do that twice: once for the global "list of audio processes",
    /// then once per audio process to find ours.
    private func isProcessProducingAudio(pid: pid_t) -> Bool {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // Step 1: ask how big the process-object list is.
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddress, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return false }

        // Step 2: allocate room and fetch the list. `withUnsafeMutableBufferPointer`
        // gives the C call a contiguous pointer into our Swift array.
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var audioObjectIDs = [AudioObjectID](repeating: 0, count: count)
        status = audioObjectIDs.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &listAddress, 0, nil, &dataSize, buffer.baseAddress!
            )
        }
        guard status == noErr else { return false }

        // Step 3: for each process object, ask its PID. If it matches ours,
        // ask whether it's currently running output.
        var pidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        for audioObjectID in audioObjectIDs {
            var processPID: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            status = AudioObjectGetPropertyData(audioObjectID, &pidAddress, 0, nil, &pidSize, &processPID)
            guard status == noErr, processPID == pid else { continue }

            var isRunning: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            status = AudioObjectGetPropertyData(audioObjectID, &runningAddress, 0, nil, &runningSize, &isRunning)
            guard status == noErr else { return false }
            return isRunning != 0
        }
        return false
    }
}
