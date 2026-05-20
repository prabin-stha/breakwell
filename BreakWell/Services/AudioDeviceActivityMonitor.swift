import CoreAudio
import Foundation
import os

// MARK: - AudioDeviceActivityMonitor
//
// Purpose: Detects when *any* process on the Mac is using the default
// audio input (mic) or output device. Event-driven via CoreAudio HAL
// property listeners — no polling, no audio capture.
//
// Architecture role: A reusable service that publishes a single Bool
// signal. Used by MicSignal / SpeakerSignal (in the SuppressionEngine) to
// flag "user is on a call / listening to something" as a reason to pause
// break reminders.
//
// About the Services/ folder:
// Services/ holds long-lived, mostly-singleton helpers that wrap a system
// framework (CoreAudio, ServiceManagement, UserNotifications). They sit
// between AppKit/SwiftUI views above and the OS below. None of them know
// about ReminderTracks or BreakContent — they expose neutral primitives
// (isActive Bool, post(content:) call, register() side effect) that
// feature code wires up.
//
// Key types defined:
//   - AudioDeviceKind: enum picking input vs output
//   - AudioDeviceActivityMonitor: @MainActor class wrapping the listeners
//
// Used by:
//   - SuppressionEngine's mic + speaker signals
//
// CoreAudio / Swift concepts a learner will see here:
//   - AudioObject API: CoreAudio represents every device + the system itself
//     as an "object" identified by AudioObjectID. You read/write properties
//     keyed by (selector, scope, element). Listeners fire when properties
//     change — that's how we get event-driven mic/output state without
//     polling.
//   - `kAudioDevicePropertyDeviceIsRunningSomewhere`: a per-device property
//     that says "some process on this Mac is currently using me". Perfect
//     for "is anyone on a call right now?" without enumerating processes.
//   - Two-listener pattern: one on the current default device for activity,
//     one on the system object for default-device-changed (so we re-attach
//     when the user plugs in headphones or switches input).
//   - `AudioObjectPropertyListenerBlock`: a closure-based listener. Pre-block
//     variant required a C function pointer — the block API is the modern
//     Swift-friendly form.
//   - `MainActor.assumeIsolated`: the listener block runs on DispatchQueue.main
//     but isn't typed as MainActor-isolated. We bridge in by asserting we
//     are in fact on the main actor.
//   - `MemoryLayout<T>.size`: Swift's equivalent of C `sizeof`. CoreAudio
//     wants property sizes as UInt32 byte counts.
//   - `[weak self]` in listener blocks: prevents a retain cycle (monitor →
//     CoreAudio holds block → block captures monitor).

/// Which device to monitor — affects only the "which selector to subscribe
/// to" choice; the listener wiring is identical for both.
enum AudioDeviceKind {
    case input
    case output

    /// CoreAudio selector for "the system's default device of this kind".
    var defaultDeviceSelector: AudioObjectPropertySelector {
        switch self {
        case .input: kAudioHardwarePropertyDefaultInputDevice
        case .output: kAudioHardwarePropertyDefaultOutputDevice
        }
    }

    /// Used for os.Logger so input vs output entries are easy to filter.
    var logCategory: String {
        switch self {
        case .input: "mic"
        case .output: "audio-out"
        }
    }
}

/// Generic "is any process using this audio device?" monitor.
///
/// Uses CoreAudio HAL property listeners on
/// `kAudioDevicePropertyDeviceIsRunningSomewhere`. Event-driven (no
/// polling) and doesn't capture audio. Tracks the current default device
/// — re-attaches when the default changes (e.g. headphones plugged in).
///
/// Example usage:
/// ```swift
/// let mic = AudioDeviceActivityMonitor(kind: .input)
/// mic.onChange = { print("mic active:", mic.isActive) }
/// mic.start()
/// // ... later
/// mic.stop()
/// ```
@MainActor
final class AudioDeviceActivityMonitor {
    private let kind: AudioDeviceKind
    private let logger: Logger

    /// True when at least one process is currently using the device.
    private(set) var isActive: Bool = false
    /// Called on every state change. Caller sets this before `start()`.
    var onChange: (() -> Void)?

    private var deviceID: AudioDeviceID?
    // Hold the blocks so we can remove them later — Add/Remove must use
    // the same block reference.
    private var runningListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var running = false

    init(kind: AudioDeviceKind) {
        self.kind = kind
        self.logger = Logger(subsystem: "com.prabin.BreakWell", category: kind.logCategory)
    }

    /// Begin monitoring. Idempotent. Attaches to the current default
    /// device and listens for default-device changes.
    func start() {
        guard !running else { return }
        running = true
        attachToDefaultDevice()
        installDefaultDeviceListener()
    }

    /// Stop monitoring and detach all listeners. Emits one final
    /// "isActive=false" change if we were active when stop was called.
    func stop() {
        guard running else { return }
        running = false
        detachFromCurrentDevice()
        removeDefaultDeviceListener()
        let wasActive = isActive
        isActive = false
        if wasActive { onChange?() }
    }

    // MARK: - Default device tracking

    private func attachToDefaultDevice() {
        guard let device = currentDefaultDevice() else {
            logger.info("no default device")
            return
        }
        deviceID = device
        readState()
        installRunningListener(on: device)
    }

    private func detachFromCurrentDevice() {
        guard let device = deviceID, let block = runningListener else {
            deviceID = nil
            runningListener = nil
            return
        }
        // CoreAudio's address structs are passed by pointer (inout) — we
        // need a mutable local so we can pass `&address`.
        var address = runningSomewhereAddress
        AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, block)
        deviceID = nil
        runningListener = nil
    }

    /// Subscribe to "is this device currently in use" changes. The block
    /// runs on the main queue (we passed DispatchQueue.main).
    private func installRunningListener(on device: AudioDeviceID) {
        var address = runningSomewhereAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // The block isn't typed @MainActor even though it runs there,
            // so we bridge into the main actor explicitly before touching
            // our isolated state.
            MainActor.assumeIsolated {
                self?.readState()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block)
        if status == noErr {
            runningListener = block
        } else {
            logger.error("install running listener failed: \(status)")
        }
    }

    /// Subscribe to "default device changed" on the system object. When
    /// fired, we detach from the old device and re-attach to the new one
    /// (so plugging in AirPods doesn't blind us).
    private func installDefaultDeviceListener() {
        var address = defaultDeviceAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.detachFromCurrentDevice()
                self.attachToDefaultDevice()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            // `kAudioObjectSystemObject` is the singleton CoreAudio object
            // representing "the audio system itself" — that's where the
            // default-device property lives.
            AudioObjectID(kAudioObjectSystemObject),
            &address, DispatchQueue.main, block
        )
        if status == noErr {
            defaultDeviceListener = block
        } else {
            logger.error("install default-device listener failed: \(status)")
        }
    }

    private func removeDefaultDeviceListener() {
        guard let block = defaultDeviceListener else { return }
        var address = defaultDeviceAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address, DispatchQueue.main, block
        )
        defaultDeviceListener = nil
    }

    // MARK: - State

    /// Re-read the "is running" property from the OS and publish if it
    /// changed. Called both on listener fire and on initial attach.
    private func readState() {
        guard let device = deviceID else {
            updateActive(false)
            return
        }
        var running: UInt32 = 0
        // CoreAudio writes the property value into a caller-provided
        // buffer. We tell it the buffer size up front via `size` (inout).
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = runningSomewhereAddress
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
        guard status == noErr else {
            logger.error("read IsRunningSomewhere failed: \(status)")
            return
        }
        updateActive(running != 0)
    }

    private func updateActive(_ nowActive: Bool) {
        guard nowActive != isActive else { return }
        isActive = nowActive
        logger.debug("active: \(nowActive)")
        onChange?()
    }

    /// Ask the system object for the current default device ID. Returns
    /// nil when there's no device (e.g. all outputs unplugged).
    private func currentDefaultDevice() -> AudioDeviceID? {
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultDeviceAddress
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    // MARK: - Property addresses
    //
    // A CoreAudio property is identified by a (selector, scope, element)
    // triple. We define the two we need as computed properties so each
    // call site reads as a single value.

    /// "Is some process using this device right now?" — per-device.
    private var runningSomewhereAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// "Which device is the current default for this kind?" — on the
    /// system object. Selector switches based on input vs output.
    private var defaultDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kind.defaultDeviceSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
