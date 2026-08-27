// Property-access helpers for Core Audio objects.
//
// Adapted from AudioCap (https://github.com/insidegui/AudioCap),
// Copyright (c) Guilherme Rambo, BSD 2-Clause License. See NOTICE.

import AudioToolbox
import CoreAudio

public struct CoreAudioError: Error, CustomStringConvertible {
    public let call: String
    public let status: OSStatus

    public var description: String {
        let chars = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: status >> $0) }
        let fourCC = chars.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
            ? " '\(String(decoding: chars, as: UTF8.self))'" : ""
        return "\(call) failed: \(status)\(fourCC)"
    }
}

func check(_ call: String, _ status: OSStatus) throws {
    guard status == noErr else { throw CoreAudioError(call: call, status: status) }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    var isValid: Bool { self != AudioObjectID(kAudioObjectUnknown) }

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a fixed-size property value.
    func read<T>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 default defaultValue: T) throws -> T {
        var address = AudioObjectID.address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = defaultValue
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
        }
        try check("AudioObjectGetPropertyData", status)
        return value
    }

    /// Reads a variable-length list-of-object-IDs property.
    func readObjectList(_ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var address = AudioObjectID.address(selector)
        var size: UInt32 = 0
        try check("AudioObjectGetPropertyDataSize",
                  AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size))
        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        guard count > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: count)
        try check("AudioObjectGetPropertyData",
                  AudioObjectGetPropertyData(self, &address, 0, nil, &size, &values))
        return values
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        try read(selector, default: "" as CFString) as String
    }

    /// `kAudioHardwarePropertyTranslatePIDToProcessObject`, system object only.
    static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var object = AudioObjectID(kAudioObjectUnknown)
        try check("AudioObjectGetPropertyData(TranslatePIDToProcessObject)",
                  AudioObjectGetPropertyData(
                    .system, &address, UInt32(MemoryLayout<pid_t>.size), &qualifier,
                    &size, &object))
        return object
    }

    /// Total channel count in the given scope, via `kAudioDevicePropertyStreamConfiguration`.
    func channelCount(scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectID.address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
