import AppKit
import SwiftUI

@main
struct PerAppAudioApp: App {
    @StateObject private var manager = RouteManager()

    var body: some Scene {
        MenuBarExtra("Per-App Audio", systemImage: "speaker.wave.2.circle") {
            PopoverView()
        }
        .menuBarExtraStyle(.window)
        // Also forces the @StateObject to exist at launch: MenuBarExtra's content
        // closure is lazy, so the listeners would otherwise wait for the first open.
        .environmentObject(manager)
    }
}

/// Natural height of the row list, so the scroll view can be given a definite one.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct PopoverView: View {
    @EnvironmentObject private var manager: RouteManager
    @StateObject private var launchAtLogin = LaunchAtLogin()
    @State private var search = ""
    @State private var listHeight: CGFloat = 0

    /// Apps playing right now, plus everything routed, kept at the top.
    private var isPromoted: (RouteManager.AppRow) -> Bool {
        { $0.isPlaying || manager.entries[$0.id] != nil }
    }

    private var matches: [RouteManager.AppRow] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return manager.rows }
        return manager.rows.filter {
            $0.name.lowercased().contains(query) || $0.id.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            let rows = matches
            let promoted = rows.filter(isPromoted)
            let others = rows.filter { !isPromoted($0) }

            if rows.isEmpty {
                Text(manager.rows.isEmpty
                     ? "No apps playing audio."
                     : "No apps match “\(search)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 12).padding(.vertical, 28)
            } else {
                ScrollView {
                    // Eager VStack, not Lazy: a lazy container inside a scroll view that
                    // has not been given a height materializes nothing, which rendered an
                    // empty popover. The list is tens of rows at most, so laziness buys
                    // nothing anyway.
                    VStack(alignment: .leading, spacing: 0) {
                        if !promoted.isEmpty {
                            SectionLabel("Now Playing")
                            ForEach(promoted) { AppRowView(row: $0) }
                        }
                        if !others.isEmpty {
                            SectionLabel("Other Audio Apps")
                            ForEach(others) { AppRowView(row: $0) }
                        }
                    }
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: ContentHeightKey.self,
                                               value: geometry.size.height)
                    })
                }
                // A ScrollView has no intrinsic height, and the popover window sizes
                // itself to its content, so without a definite height here the whole list
                // collapses to nothing. Measure the rows and clamp.
                .frame(height: min(max(listHeight, 44), 380))
                .onPreferenceChange(ContentHeightKey.self) { height in
                    listHeight = height
                }
            }

            Divider()
            footer
        }
        .frame(width: 400)
        // The popover is the only place these lists are visible, so refresh while it is
        // open (apps start and stop playing without any launch/terminate notification)
        // and never while it is closed.
        .task {
            while !Task.isCancelled {
                manager.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Per-App Audio").font(.headline)
                Spacer()
                if !manager.entries.isEmpty {
                    Text("\(manager.entries.count) routed")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("Search apps", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Launch at login", isOn: Binding(get: { launchAtLogin.isEnabled },
                                                    set: { _ in launchAtLogin.toggle() }))
                .toggleStyle(.checkbox)
                .font(.callout)
            HStack {
                Button("Reset All") { manager.resetAll() }
                    .disabled(manager.entries.isEmpty)
                Spacer()
                Button("Quit") {
                    manager.shutDown()
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // The registration can be changed from System Settings behind our back.
        .onAppear { launchAtLogin.refresh() }
    }
}

private struct SectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.caption2).fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 8).padding(.bottom, 2)
    }
}

struct AppRowView: View {
    @EnvironmentObject private var manager: RouteManager
    let row: RouteManager.AppRow

    var body: some View {
        let entry = manager.entries[row.id]

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let icon = manager.icons[row.id] {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                } else {
                    Image(systemName: "app.dashed").frame(width: 18, height: 18)
                }
                Text(row.name).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)

                Picker("", selection: deviceSelection(entry)) {
                    Text("Default output").tag(String?.none)
                    // A pending route's device is not in the list — without a matching
                    // tag the picker would render blank rather than the choice the user
                    // made and we are still holding.
                    if let entry,
                       !manager.devices.contains(where: { $0.uid == entry.deviceUID }) {
                        Text(entry.deviceName).tag(Optional(entry.deviceUID))
                    }
                    ForEach(manager.devices) { Text($0.name).tag(Optional($0.uid)) }
                }
                .labelsHidden()
                .frame(width: 150)
                .disabled(row.process == nil)
                // Greyed, not hidden: the route is still ours, just not live.
                .opacity(entry?.isPending == true ? 0.55 : 1)
                .help(entry?.status == .waitingForDevice
                      ? "\(entry?.deviceName ?? "Device") disconnected — will reconnect"
                      : "")

                Button { manager.clear(id: row.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .opacity(entry == nil ? 0 : 1)
                    .disabled(entry == nil)
                    .help("Stop routing and fall back to the default output")
            }

            if let entry {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(entry.gain) },
                                          set: { manager.setGain(id: row.id, gain: Float($0)) }),
                           in: 0...2,
                           onEditingChanged: { editing in
                               if !editing { manager.commitGain() }
                           })
                    Text("\(Int((entry.gain * 100).rounded()))%")
                        .font(.caption).monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                switch entry.status {
                case .starting:
                    Text("Starting…").font(.caption).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                case .waitingForApp:
                    note("clock", "Waiting for \(row.name)")
                case .waitingForDevice:
                    note("cable.connector.slash", "\(entry.deviceName) disconnected")
                case .running:
                    // Deliberately does not name a cause: a silent tap that repeated
                    // rebuilds did not fix could be the macOS 26 bug, a missing
                    // system-audio grant, or an app that is genuinely quiet.
                    if manager.stalled.contains(row.id) {
                        note("exclamationmark.triangle", "No audio from this app’s tap")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// A pending route's one-line explanation. Deliberately quiet: the route is still
    /// there, it just cannot run right now, and it will come back on its own.
    private func note(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Picking a device starts (or switches) the route immediately; picking
    /// "Default output" tears it down.
    private func deviceSelection(_ entry: RouteManager.Entry?) -> Binding<String?> {
        Binding(get: { entry?.deviceUID },
                set: { uid in
                    if let uid { manager.apply(row: row, deviceUID: uid) }
                    else { manager.clear(id: row.id) }
                })
    }
}
