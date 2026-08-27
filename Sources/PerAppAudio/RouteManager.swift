import AppKit
import AudioRoutingEngine
import AudioToolbox
import CoreAudio
import SwiftUI
import os

private let log = Logger(subsystem: "dev.perappvolume.app", category: "RouteManager")

/// Owns every desired route, the live routes derived from them, and the lists the
/// popover renders.
///
/// The `entries` dictionary is the desired state and the thing that gets persisted: an
/// entry is created when the user picks a device and removed only when the user clears
/// it. A live `Route` is derived from an entry whenever both the app and the device are
/// present; when either goes away the route is torn down but the entry stays, pending,
/// and `reconcile()` rebuilds it as soon as both come back.
///
/// Concurrency contract: this class is main-actor state. The `Route` objects themselves
/// live on `workQueue` (`LiveRoutes`), because `Route.start()` sleeps while the aggregate
/// settles. Only `workQueue` ever calls `Route.stop()`; the main actor keeps a reference
/// solely to write `.gain` and read the watchdog counters without queueing behind a
/// start — and every path that stops a route drops that reference *before* enqueuing the
/// stop, so the main actor can never touch a torn-down route's render state.
@MainActor
final class RouteManager: ObservableObject {

    enum Status: Equatable {
        case starting
        case running
        /// Desired, but the app is not running (or has no audio process object yet).
        case waitingForApp
        /// Desired, but the output device is not attached.
        case waitingForDevice
        case failed(String)
    }

    struct Entry {
        var deviceUID: String
        var deviceName: String
        var appName: String
        var gain: Float
        var status: Status
        /// The `apply` that owns this entry. A start that finishes after a newer
        /// apply/clear finds a mismatch here and discards itself.
        var generation: Int
        var route: Route?

        var isPending: Bool { status == .waitingForApp || status == .waitingForDevice }
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
    /// Bundle IDs of everything NSWorkspace considers running, refreshed with the rows.
    private var runningBundleIDs: Set<String> = []
    /// Drives reconcile (and the watchdog) while the popover is closed; nil when there
    /// is nothing to maintain.
    private var maintenanceTimer: Timer?

    private nonisolated let live = LiveRoutes()
    private nonisolated let workQueue = DispatchQueue(label: "dev.perappvolume.routework")

    init() {
        // Saved routes come back pending; `reconcile()` below starts the ones whose app
        // and device are both already there, and later ticks pick up the rest.
        for (id, saved) in RouteStore.load() {
            entries[id] = Entry(deviceUID: saved.deviceUID, deviceName: saved.deviceName,
                                appName: saved.appName, gain: saved.gain,
                                status: .waitingForApp, generation: 0, route: nil)
        }
        refresh()

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
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        syncTimer()
    }

    // MARK: - Route control

    /// The user picked a device for this app.
    func apply(row: AppRow, deviceUID: String) {
        guard let process = row.process,
              let device = devices.first(where: { $0.uid == deviceUID }) else { return }
        // Re-picking the device a route already runs on (or is starting on) would
        // otherwise cut the audio for a full rebuild. A failed or pending one is worth
        // retrying — that is what re-picking the same device means.
        if let current = entries[row.id], current.deviceUID == deviceUID,
           current.status == .running || current.status == .starting { return }

        startRoute(id: row.id, process: process, device: device)
        persist()
        syncTimer()
    }

    /// Forgets the route entirely: tears it down, drops the saved entry. The app reverts
    /// to the system default output on its own.
    func clear(id: String) {
        guard entries[id] != nil else { return }
        generation += 1
        entries[id] = nil
        stopLiveRoute(id: id)
        persist()
        syncTimer()
    }

    func resetAll() {
        generation += 1
        entries.removeAll()
        stopAllLiveRoutes()
        persist()
        syncTimer()
    }

    func setGain(id: String, gain: Float) {
        entries[id]?.gain = gain
        entries[id]?.route?.gain = gain
    }

    /// Called when the slider drag ends, so a drag writes UserDefaults once rather than
    /// once per frame.
    func commitGain() { persist() }

    /// Stops every route and waits — briefly — for the work queue to drain, so quitting
    /// does not leave a tap or an aggregate behind. Deliberately does NOT touch `entries`
    /// or the store: quitting is not the user forgetting their routes. The wait is
    /// bounded because the stops queue behind any start already in flight, and
    /// `Route.start()` sleeps; process exit releases the taps and private aggregates
    /// anyway, so a hung Quit button would be the worse trade. Never call
    /// `DispatchQueue.main.sync` from `workQueue`.
    func shutDown() {
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        generation += 1
        stopAllLiveRoutes()
        let drained = DispatchSemaphore(value: 0)
        workQueue.async { drained.signal() }
        _ = drained.wait(timeout: .now() + 1)
    }

    /// Builds (or rebuilds) the live route for an entry. The caller has already checked
    /// that both the process and the device are present.
    private func startRoute(id: String, process: AudioProcess, device: AudioOutputDevice) {
        generation += 1
        let generation = self.generation
        let gain = entries[id]?.gain ?? 1
        entries[id] = Entry(deviceUID: device.uid, deviceName: device.name,
                            appName: process.name, gain: gain, status: .starting,
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

    /// Keeps the entry but tears the live route down, so the app falls back to the system
    /// default output until whatever it is waiting for comes back. Idempotent: the 2 s
    /// tick calls it repeatedly for as long as the app or device stays away.
    private func markPending(id: String, _ status: Status) {
        guard let entry = entries[id], entry.status != status else { return }
        generation += 1
        entries[id]?.status = status
        stopLiveRoute(id: id)
    }

    /// Drops the main-actor reference to the route *first*, then stops it on the work
    /// queue. The ordering is what makes the periodic `tapActivity` read safe.
    private func stopLiveRoute(id: String) {
        entries[id]?.route = nil
        workQueue.async { [live] in live.byBundleID.removeValue(forKey: id)?.stop() }
    }

    private func stopAllLiveRoutes() {
        for id in entries.keys { entries[id]?.route = nil }
        workQueue.async { [live] in
            for route in live.byBundleID.values { route.stop() }
            live.byBundleID.removeAll()
        }
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

    private func persist() {
        RouteStore.save(entries.mapValues {
            SavedRoute(deviceUID: $0.deviceUID, deviceName: $0.deviceName,
                       appName: $0.appName, gain: $0.gain)
        })
    }

    // MARK: - Refresh and reconcile

    func refresh() {
        refreshDevices()
        refreshRows()
        reconcile()
    }

    private func scheduleReconcile() {
        reconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        reconcileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Brings the live routes in line with the desired entries: starts what can run,
    /// tears down what cannot, and leaves everything else alone. Every transition here is
    /// idempotent, so it is safe to call on every device notification and every tick.
    private func reconcile() {
        for (id, entry) in entries {
            let device = devices.first { $0.uid == entry.deviceUID }
            switch entry.status {
            case .starting, .failed:
                // In flight, or waiting for the user to retry by re-picking the device.
                continue
            case .running:
                // A route survives its app dropping off the audio-process list (that
                // happens while an app is merely idle); only the app or the device
                // actually going away tears it down.
                if device == nil { markPending(id: id, .waitingForDevice) }
                else if !runningBundleIDs.contains(id) { markPending(id: id, .waitingForApp) }
            case .waitingForApp, .waitingForDevice:
                guard let device else { markPending(id: id, .waitingForDevice); continue }
                // An app registers its audio process object a moment after it launches,
                // so a pending entry may wait a few ticks past didLaunchApplication.
                guard let process = rows.first(where: { $0.id == id })?.process else {
                    markPending(id: id, .waitingForApp)
                    continue
                }
                log.notice("re-applying pending route for \(id, privacy: .public)")
                startRoute(id: id, process: process, device: device)
            }
        }
    }

    private func refreshDevices() {
        // Enumeration throws while the HAL churns — which is exactly when the hot-plug
        // listener fires. Treating that as "no devices exist" would tear down every
        // route, so a failed read reconciles nothing; only a successful one does.
        guard let enumerated = try? AudioOutputDevice.all() else { return }
        if enumerated != devices { devices = enumerated }
    }

    private func refreshRows() {
        guard let processes = try? AudioProcess.all() else { return }
        let running = Dictionary(
            NSWorkspace.shared.runningApplications.compactMap { app in
                app.bundleIdentifier.map { ($0, app) }
            }, uniquingKeysWith: { a, _ in a })
        runningBundleIDs = Set(running.keys)

        // We register an audio process object of our own; routing ourselves is nonsense.
        let ownBundleID = Bundle.main.bundleIdentifier
        var newRows = processes
            .filter { $0.id != ownBundleID }
            .map { AppRow(id: $0.id, name: $0.name, isPlaying: $0.isPlaying, process: $0) }
        // A routed app that has fallen off the audio-process list — or is not running at
        // all, for a route restored from disk — still needs a row, to show what it is
        // waiting for and to clear from. It has no process to build a route with, only a ✕.
        let listed = Set(newRows.map(\.id))
        for (id, entry) in entries where !listed.contains(id) {
            newRows.append(AppRow(id: id, name: running[id]?.localizedName ?? entry.appName,
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

    // MARK: - Maintenance timer

    /// Reconcile has to keep running with the popover closed — that is where a pending
    /// route is waiting for its app or its device — but only while there is something to
    /// maintain.
    private func syncTimer() {
        guard !entries.isEmpty else {
            maintenanceTimer?.invalidate()
            maintenanceTimer = nil
            return
        }
        guard maintenanceTimer == nil else { return }
        // `.common` mode: a plain scheduled timer stops firing while the menu-bar popover
        // is tracking events.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.maintain() }
        }
        RunLoop.main.add(timer, forMode: .common)
        maintenanceTimer = timer
    }

    private func maintain() {
        refresh()
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
