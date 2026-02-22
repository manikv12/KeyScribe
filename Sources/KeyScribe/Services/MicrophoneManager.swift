import AVFoundation
import CoreAudio
import Foundation

enum MicrophoneManager {
    static func availableMicrophones() -> [MicrophoneOption] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )

        var devicesByUID: [String: MicrophoneOption] = [:]
        for device in session.devices {
            devicesByUID[device.uniqueID] = MicrophoneOption(uid: device.uniqueID, name: device.localizedName)
        }

        return devicesByUID.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func defaultMicrophoneUID() -> String? {
        AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var defaultDeviceID: AudioDeviceID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &defaultDeviceID
        )

        guard status == noErr, defaultDeviceID != kAudioObjectUnknown else {
            return nil
        }

        return defaultDeviceID
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        let uidRef = uid as CFString
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = withUnsafePointer(to: uidRef) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                UInt32(MemoryLayout<CFString>.size),
                uidPointer,
                &dataSize,
                &deviceID
            )
        }

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }

        return deviceID
    }

    static func setDefaultInput(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var requested = deviceID
        let dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            dataSize,
            &requested
        )

        return status == noErr
    }
}

struct MicrophoneOption: Identifiable, Hashable {
    let uid: String
    let name: String

    var id: String { uid }
}
