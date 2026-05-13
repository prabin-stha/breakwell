import AppKit
import CoreAudio
import os

/// Active when the frontmost app is producing audio output.
/// Catches "watching/listening to media": YouTube in any window size, video calls
/// outside our known meeting-app list, music in a fullscreen player, etc.
///
/// Uses macOS 14's per-process audio attribution (`kAudioProcessPropertyIsRunningOutput`)
/// so background audio from apps in other Spaces doesn't false-positive.
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
        // If our own Settings window is frontmost, preserve the prior state —
        // the user's actual context (Safari, etc.) hasn't really changed.
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

    /// Asks "is this PID currently producing audio output?" without permissions.
    private func isProcessProducingAudio(pid: pid_t) -> Bool {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddress, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return false }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var audioObjectIDs = [AudioObjectID](repeating: 0, count: count)
        status = audioObjectIDs.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &listAddress, 0, nil, &dataSize, buffer.baseAddress!
            )
        }
        guard status == noErr else { return false }

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
