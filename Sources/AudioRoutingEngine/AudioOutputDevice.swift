import AudioToolbox
import CoreAudio

/// A physical (or user-created) audio device that can play audio.
public struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String

    /// Every device on the system with at least one output channel.
    public static func all() throws -> [AudioOutputDevice] {
        try AudioObjectID.system.readObjectList(kAudioHardwarePropertyDevices)
            .compactMap { deviceID -> AudioOutputDevice? in
                guard deviceID.channelCount(scope: kAudioObjectPropertyScopeOutput) > 0,
                      let uid = try? deviceID.readString(kAudioDevicePropertyDeviceUID),
                      let name = try? deviceID.readString(kAudioObjectPropertyName)
                else { return nil }
                return AudioOutputDevice(id: deviceID, uid: uid, name: name)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The system's current default output device, if it is in `all()`.
    public static func systemDefault() -> AudioOutputDevice? {
        guard let id = try? AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultOutputDevice,
            default: AudioObjectID(kAudioObjectUnknown)) else { return nil }
        return (try? all())?.first { $0.id == id }
    }
}
