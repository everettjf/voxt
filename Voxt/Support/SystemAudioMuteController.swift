import Foundation
import CoreAudio

@MainActor
final class SystemAudioMuteController {
    private let duckRatio: Float32 = 0.2
    private let minimumDuckVolume: Float32 = 0.05

    private var savedVolume: Float32?
    private var mutedDeviceID: AudioDeviceID?

    func muteSystemAudioIfNeeded() {
        guard savedVolume == nil else { return }
        guard let outputDeviceID = defaultOutputDeviceID() else { return }
        guard let volume = getOutputVolume(deviceID: outputDeviceID) else { return }

        let duckedVolume = max(minimumDuckVolume, volume * duckRatio)
        guard duckedVolume < volume else { return }

        savedVolume = volume
        mutedDeviceID = outputDeviceID
        _ = setOutputVolume(deviceID: outputDeviceID, value: duckedVolume)
    }

    func restoreSystemAudioIfNeeded() {
        guard let savedVolume, let deviceID = mutedDeviceID else { return }
        _ = setOutputVolume(deviceID: deviceID, value: savedVolume)
        self.savedVolume = nil
        self.mutedDeviceID = nil
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private func getOutputVolume(deviceID: AudioDeviceID) -> Float32? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &value)
        guard status == noErr else { return nil }
        return value
    }

    private func setOutputVolume(deviceID: AudioDeviceID, value: Float32) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var mutableValue = max(0, min(1, value))
        let dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nil, dataSize, &mutableValue)
        return status == noErr
    }
}
