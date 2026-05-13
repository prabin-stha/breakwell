import CoreAudio
import Foundation
import os

enum AudioDeviceKind {
    case input
    case output

    var defaultDeviceSelector: AudioObjectPropertySelector {
        switch self {
        case .input: kAudioHardwarePropertyDefaultInputDevice
        case .output: kAudioHardwarePropertyDefaultOutputDevice
        }
    }

    var logCategory: String {
        switch self {
        case .input: "mic"
        case .output: "audio-out"
        }
    }
}

/// Generic "is any process using this audio device?" monitor.
/// Uses CoreAudio HAL property listeners on `kAudioDevicePropertyDeviceIsRunningSomewhere`.
/// Event-driven (no polling) and doesn't capture audio. Tracks the current default
/// device — re-attaches when the default changes (e.g. headphones plugged in).
@MainActor
final class AudioDeviceActivityMonitor {
    private let kind: AudioDeviceKind
    private let logger: Logger

    private(set) var isActive: Bool = false
    var onChange: (() -> Void)?

    private var deviceID: AudioDeviceID?
    private var runningListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var running = false

    init(kind: AudioDeviceKind) {
        self.kind = kind
        self.logger = Logger(subsystem: "com.prabin.BreakWell", category: kind.logCategory)
    }

    func start() {
        guard !running else { return }
        running = true
        attachToDefaultDevice()
        installDefaultDeviceListener()
    }

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
        var address = runningSomewhereAddress
        AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, block)
        deviceID = nil
        runningListener = nil
    }

    private func installRunningListener(on device: AudioDeviceID) {
        var address = runningSomewhereAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
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

    private func readState() {
        guard let device = deviceID else {
            updateActive(false)
            return
        }
        var running: UInt32 = 0
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
        logger.info("active: \(nowActive)")
        onChange?()
    }

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

    private var runningSomewhereAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private var defaultDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kind.defaultDeviceSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
