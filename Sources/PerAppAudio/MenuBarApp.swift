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

struct PopoverView: View {
    @EnvironmentObject private var manager: RouteManager
    @State private var search = ""

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
                     ? "No apps are producing audio yet."
                     : "No apps match “\(search)”.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 18)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !promoted.isEmpty {
                            SectionLabel("Now Playing")
                            ForEach(promoted) { AppRowView(row: $0) }
                        }
                        if !others.isEmpty {
                            SectionLabel("Other Audio Apps")
                            ForEach(others) { AppRowView(row: $0) }
                        }
                    }
                }
                .frame(maxHeight: 380)
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
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search apps", text: $search)
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Button("Reset All") { manager.resetAll() }
                .disabled(manager.entries.isEmpty)
            Spacer()
            Button("Quit") {
                manager.shutDown()
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                    ForEach(manager.devices) { Text($0.name).tag(Optional($0.uid)) }
                }
                .labelsHidden()
                .frame(width: 150)
                .disabled(row.process == nil)

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
                           in: 0...2)
                    Text("\(Int((entry.gain * 100).rounded()))%")
                        .font(.caption).monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                switch entry.status {
                case .starting:
                    Text("Starting…").font(.caption).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                case .running:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
