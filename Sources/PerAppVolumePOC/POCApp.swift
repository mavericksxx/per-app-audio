// Throwaway harness for exercising AudioRoutingEngine. Not the final UI.
// It exists because Core Audio taps only get a TCC grant from a real .app bundle.

import AudioRoutingEngine
import SwiftUI

@MainActor
final class POCModel: ObservableObject {
    @Published var processes: [AudioProcess] = []
    @Published var devices: [AudioOutputDevice] = []
    @Published var selectedProcess: AudioProcess?
    @Published var selectedDevice: AudioOutputDevice?
    @Published var gain: Float = 1 { didSet { route?.gain = gain } }
    @Published var status = "idle"
    @Published var diagnostics = ""
    @Published var isRunning = false

    private var route: Route?
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in
                self.diagnostics = self.route?.diagnostics ?? ""
            }
        }
    }

    func refresh() {
        processes = (try? AudioProcess.all()) ?? []
        devices = (try? AudioOutputDevice.all()) ?? []
        if selectedProcess == nil { selectedProcess = processes.first }
        if selectedDevice == nil { selectedDevice = AudioOutputDevice.systemDefault() ?? devices.first }
    }

    func start() {
        guard let process = selectedProcess, let device = selectedDevice else { return }
        let route = Route(process: process, device: device)
        route.gain = gain
        self.route = route
        status = "starting…"
        // start() sleeps while the aggregate settles, so keep it off the main thread.
        Task.detached {
            do {
                try route.start()
                await MainActor.run {
                    self.isRunning = true
                    self.status = "routing \(process.name) -> \(device.name)"
                }
            } catch {
                await MainActor.run {
                    self.route = nil
                    self.status = "failed: \(error)"
                }
            }
        }
    }

    func stop() {
        route?.stop()
        route = nil
        isRunning = false
        status = "idle"
        diagnostics = ""
    }
}

struct ContentView: View {
    @StateObject private var model = POCModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("App", selection: $model.selectedProcess) {
                ForEach(model.processes) { Text($0.name).tag(Optional($0)) }
            }
            Picker("Output", selection: $model.selectedDevice) {
                ForEach(model.devices) { Text($0.name).tag(Optional($0)) }
            }
            HStack {
                Button(model.isRunning ? "Stop" : "Start") {
                    model.isRunning ? model.stop() : model.start()
                }
                .disabled(model.selectedProcess == nil || model.selectedDevice == nil)
                Button("Refresh lists") { model.refresh() }.disabled(model.isRunning)
            }
            HStack {
                Text("Gain")
                Slider(value: $model.gain, in: 0...2)
                Text(String(format: "%.2f", model.gain)).monospacedDigit().frame(width: 44)
            }
            Text(model.status).font(.callout)
            Text(model.diagnostics.isEmpty ? " " : model.diagnostics)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(20)
        .frame(width: 520)
    }
}

@main
struct PerAppVolumePOCApp: App {
    var body: some Scene {
        Window("Per-App Volume POC", id: "main") { ContentView() }
            .windowResizability(.contentSize)
    }
}
