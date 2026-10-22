import AVFoundation
import CoreAudio
import Foundation

/// A microphone the user can pick.
struct AudioInputDevice: Identifiable, Equatable {
    let id: String          // AVCaptureDevice.uniqueID
    let name: String
    let isDefault: Bool
}

/// A speaker the feedback sounds can be routed to.
struct AudioOutputDevice: Identifiable, Equatable {
    let id: String          // CoreAudio UID
    let name: String
    let deviceID: AudioDeviceID
    let isDefault: Bool
}

enum AudioDeviceList {

    /// Microphones, "System default" first.
    static func inputDevices() -> [AudioInputDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )
        let defaultUID = defaultCaptureDevice()?.uniqueID

        var out: [AudioInputDevice] = []
        if let defaultUID {
            let device = discovery.devices.first { $0.uniqueID == defaultUID }
            out.append(AudioInputDevice(id: defaultUID,
                                        name: device?.localizedName ?? "System default",
                                        isDefault: true))
        } else {
            out.append(AudioInputDevice(id: "", name: "System default", isDefault: true))
        }
        for device in discovery.devices where device.uniqueID != defaultUID {
            out.append(AudioInputDevice(id: device.uniqueID,
                                        name: device.localizedName,
                                        isDefault: false))
        }
        return out
    }

    /// The system default microphone, across SDK generations.
    static func defaultCaptureDevice() -> AVCaptureDevice? {
        if #available(macOS 14.0, *) {
            return AVCaptureDevice.default(.microphone, for: .audio, position: .unspecified)
        }
        return AVCaptureDevice.default(for: .audio)
    }

    /// The capture device for a chosen UID, or the system default.
    static func captureDevice(for uid: String) -> AVCaptureDevice? {
        if uid.isEmpty {
            return defaultCaptureDevice()
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices.first { $0.uniqueID == uid } ?? defaultCaptureDevice()
    }

    // MARK: - Output devices (CoreAudio)

    /// Speakers, "System default" first.
    static func outputDevices() -> [AudioOutputDevice] {
        var out: [AudioOutputDevice] = []
        let defaultID = defaultOutputDeviceID()
        let defaultUID = defaultID.flatMap { deviceUID(for: $0) } ?? ""
        out.append(AudioOutputDevice(id: "",
                                     name: "System default",
                                     deviceID: defaultID ?? 0,
                                     isDefault: true))

        for device in allDevices() {
            guard hasOutputStreams(device) else { continue }
            let deviceUIDValue = deviceUID(for: device) ?? ""
            guard !deviceUIDValue.isEmpty, deviceUIDValue != defaultUID else { continue }
            out.append(AudioOutputDevice(id: deviceUIDValue,
                                         name: deviceName(for: device) ?? "Output",
                                         deviceID: device,
                                         isDefault: false))
        }
        return out
    }

    /// The CoreAudio device for a chosen UID.
    static func outputDevice(for uid: String) -> AudioDeviceID? {
        if uid.isEmpty { return defaultOutputDeviceID() }
        return allDevices().first { deviceUID(for: $0) == uid }
    }

    static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.stride
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else {
            return nil
        }
        return id == 0 ? nil : id
    }

    static func deviceUID(for device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return (uid as String).trimmingCharacters(in: .whitespaces)
    }

    static func deviceName(for device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return (name as String).trimmingCharacters(in: .whitespaces)
    }

    static func hasOutputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }
}
