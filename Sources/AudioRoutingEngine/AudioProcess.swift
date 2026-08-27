import AppKit
import AudioToolbox
import CoreAudio

/// A running application that Core Audio knows about, as a tap target.
///
/// One app can own several audio process objects (helper processes — Spotify and
/// Chromium both do this), so a process is identified by bundle ID and carries every
/// matching object ID; the tap is built over all of them.
public struct AudioProcess: Identifiable, Hashable, Sendable {
    public let id: String  // bundle ID
    public let name: String
    public let pids: [pid_t]
    public let objectIDs: [AudioObjectID]
    /// True while at least one of the app's process objects is actively playing audio.
    /// Stays true for a routed app: the tap mutes the normal output but the app is
    /// still running output into it.
    public let isPlaying: Bool

    /// Every running application that has at least one audio process object.
    public static func all() throws -> [AudioProcess] {
        let runningByBundleID = Dictionary(
            NSWorkspace.shared.runningApplications.compactMap { app -> (String, String)? in
                guard let bundleID = app.bundleIdentifier else { return nil }
                return (bundleID, app.localizedName ?? bundleID)
            },
            uniquingKeysWith: { first, _ in first })

        var byBundleID:
            [String: (name: String, pids: [pid_t], objects: [AudioObjectID], playing: Bool)] = [:]
        for object in try AudioObjectID.system.readObjectList(
            kAudioHardwarePropertyProcessObjectList) {
            guard let bundleID = try? object.readString(kAudioProcessPropertyBundleID),
                  !bundleID.isEmpty,
                  let name = runningByBundleID[bundleID],
                  let pid = try? object.read(kAudioProcessPropertyPID, default: pid_t(-1)),
                  pid > 0
            else { continue }
            let playing = (try? object.read(kAudioProcessPropertyIsRunningOutput,
                                            default: UInt32(0))) == 1
            byBundleID[bundleID, default: (name, [], [], false)].pids.append(pid)
            byBundleID[bundleID]!.objects.append(object)
            byBundleID[bundleID]!.playing = byBundleID[bundleID]!.playing || playing
        }

        return byBundleID
            .map { AudioProcess(id: $0.key, name: $0.value.name, pids: $0.value.pids,
                                objectIDs: $0.value.objects, isPlaying: $0.value.playing) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
