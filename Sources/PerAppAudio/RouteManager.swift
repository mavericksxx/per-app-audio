import AppKit
import AudioRoutingEngine
import AudioToolbox
import CoreAudio
import SwiftUI

/// Owns every active route and the lists the popover renders.
///
/// Concurrency contract: this class is main-actor state. The `Route` objects themselves
/// live on `workQueue` (`LiveRoutes`), because `Route.start()` sleeps while the aggregate
/// settles. Only `workQueue` ever calls `Route.stop()`; the main actor keeps a reference
/// solely to write `.gain` without queueing behind a start.
@MainActor
final class RouteManager: ObservableObject {

    enum Status: Equatable {
        case starting
        case running
        case failed(String)
    }

    struct Entry {
        var deviceUID: String
        var gain: Float
        var status: Status
        /// The `apply` that owns this entry. A start that finishes after a newer
        /// apply/clear finds a mismatch here and discards itself.
        var generation: Int
        var route: Route?
    }

    /// One line in the popover: an app that is producing audio, or one we route (which
    /// stays listed even if it drops off the audio-process list, so it can be cleared).
    struct AppRow: Identifiable, Equatable {
        let id: String  // bundle ID
        let name: String
        let isPlaying: Bool
        let process: AudioProcess?
    }

    @Published private(set) var rows: [AppRow] = []
    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published private(set) var entries: [String: Entry] = [:]
    @Published private(set) var icons: [String: NSImage] = [:]

    private var generation = 0
    private var reconcileWork: DispatchWorkItem?
    private var listeners: [SystemPropertyListener] = []

    private nonisolated let live = LiveRoutes()
    private nonisolated let workQueue = DispatchQueue(label: "dev.perappvolume.routework")

    init() {
        refreshDevices()
        refreshRows()

        // Device arrival/removal fires in bursts (and creating our own aggregate trips it
        // too), so debounce and reconcile idempotently rather than trusting the edge.
        listeners = [
            SystemPropertyListener(kAudioHardwarePropertyDevices) { [weak self] in
                self?.scheduleReconcile()
            },
            SystemPropertyListener(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
                self?.scheduleReconcile()
            },
        ]

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRows() }
            }
        }
    }

    // MARK: - Route control

    func apply(row: AppRow, deviceUID: String) {
        guard let process = row.process,
              let device = devices.first(where: { $0.uid == deviceUID }) else { return }
        // Re-picking the device a route already runs on would otherwise cut the audio
        // for a full rebuild. A failed route is worth retrying.
        if let current = entries[row.id], current.deviceUID == deviceUID {
            if case .failed = current.status {} else { return }
        }

        generation += 1
        let generation = self.generation
        let id = row.id
        let gain = entries[id]?.gain ?? 1
        entries[id] = Entry(deviceUID: device.uid, gain: gain, status: .starting,
                            generation: generation, route: nil)

        workQueue.async { [live, weak self] in
            // Unconditional: at most one live route per bundle ID, whatever raced.
            live.byBundleID.removeValue(forKey: id)?.stop()
            let route = Route(process: process, device: device)
            route.gain = gain
            do {
                try route.start()
                live.byBundleID[id] = route
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.attach(route, id: id, generation: generation) }
                }
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.finishFailed(id: id, generation: generation, error: error)
                    }
                }
            }
        }
    }

    /// Tears the route down; the app reverts to the system default output on its own.
    func clear(id: String) {
        guard entries[id] != nil else { return }
        generation += 1
        entries[id] = nil
        workQueue.async { [live] in live.byBundleID.removeValue(forKey: id)?.stop() }
    }

    func resetAll() {
        generation += 1
        entries.removeAll()
        workQueue.async { [live] in
            for route in live.byBundleID.values { route.stop() }
            live.byBundleID.removeAll()
        }
    }

    func setGain(id: String, gain: Float) {
        entries[id]?.gain = gain
        entries[id]?.route?.gain = gain
    }

    /// Stops every route and waits — briefly — for the work queue to drain, so quitting
    /// does not leave a tap or an aggregate behind. The wait is bounded because the stops
    /// queue behind any start already in flight, and `Route.start()` sleeps; process exit
    /// releases the taps and private aggregates anyway, so a hung Quit button would be
    /// the worse trade. Never call `DispatchQueue.main.sync` from `workQueue`.
    func shutDown() {
        resetAll()
        let drained = DispatchSemaphore(value: 0)
        workQueue.async { drained.signal() }
        _ = drained.wait(timeout: .now() + 1)
    }

    private func attach(_ route: Route, id: String, generation: Int) {
        guard entries[id]?.generation == generation else { return }  // superseded
        entries[id]?.route = route
        entries[id]?.status = .running
    }

    private func finishFailed(id: String, generation: Int, error: Error) {
        guard entries[id]?.generation == generation else { return }
        entries[id]?.status = .failed("\(error)")
    }

    // MARK: - Refresh and reconcile

    func refresh() {
        refreshDevices()
        refreshRows()
    }

    private func scheduleReconcile() {
        reconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        reconcileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Teardown-only-on-vanish: a device appearing (including an aggregate we just made)
    /// changes nothing, so the listener can fire as often as it likes.
    private func refreshDevices() {
        // Enumeration throws while the HAL churns — which is exactly when the hot-plug
        // listener fires. Treating that as "no devices exist" would clear every route,
        // so a failed read reconciles nothing; only a successful one does.
        guard let enumerated = try? AudioOutputDevice.all() else { return }
        devices = enumerated
        let available = Set(devices.map(\.uid))
        for id in Array(entries.keys) where !available.contains(entries[id]!.deviceUID) {
            clear(id: id)
        }
    }

    private func refreshRows() {
        guard let processes = try? AudioProcess.all() else { return }
        let running = Dictionary(
            NSWorkspace.shared.runningApplications.compactMap { app in
                app.bundleIdentifier.map { ($0, app) }
            }, uniquingKeysWith: { a, _ in a })

        // A routed app that quit can never come back on its own; drop its route.
        for id in Array(entries.keys) where running[id] == nil { clear(id: id) }

        // We register an audio process object of our own; routing ourselves is nonsense.
        let ownBundleID = Bundle.main.bundleIdentifier
        var newRows = processes
            .filter { $0.id != ownBundleID }
            .map { AppRow(id: $0.id, name: $0.name, isPlaying: $0.isPlaying, process: $0) }
        // A routed app that has fallen off the audio-process list still needs a row to
        // clear from. It has no process to (re)build a route with, only a ✕.
        let listed = Set(newRows.map(\.id))
        for id in entries.keys where !listed.contains(id) {
            newRows.append(AppRow(id: id, name: running[id]?.localizedName ?? id,
                                  isPlaying: false, process: nil))
        }
        newRows.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // Republish only on a real change: the popover polls while it is open, and
        // reassigning `rows` closes an open device menu and moves rows under the cursor.
        if newRows != rows { rows = newRows }

        for row in newRows where icons[row.id] == nil {
            if let icon = running[row.id]?.icon { icons[row.id] = icon }
        }
    }
}

/// The live `Route` objects. Only `RouteManager.workQueue` — a serial queue — touches
/// this, which is what the `@unchecked` stands in for; `Route` itself is not Sendable.
final class LiveRoutes: @unchecked Sendable {
    var byBundleID: [String: Route] = [:]
}

/// A Core Audio property listener on the system object, delivered on the main queue.
final class SystemPropertyListener {
    private var address: AudioObjectPropertyAddress
    private var block: AudioObjectPropertyListenerBlock?

    init(_ selector: AudioObjectPropertySelector, onChange: @escaping @MainActor () -> Void) {
        address = AudioObjectPropertyAddress(mSelector: selector,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
        // Registered on the main queue, so `assumeIsolated` holds.
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { onChange() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                               &address, DispatchQueue.main, block) == noErr {
            self.block = block
        }
    }

    deinit {
        guard let block else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                               &address, DispatchQueue.main, block)
    }
}
