import ServiceManagement
import SwiftUI
import os

private let log = Logger(subsystem: "dev.perappvolume.app", category: "LaunchAtLogin")

/// The app's own login-item registration, via `SMAppService.mainApp` (macOS 13+):
/// no helper bundle, no extra entitlement.
///
/// Registration wants a stable code signature and a settled bundle location, so an
/// ad-hoc-signed build run out of `build/` can be refused. That is not an error worth
/// putting in the user's face: the toggle reports what the system actually says, so a
/// refused registration simply leaves it off, with the reason in the log. The same is
/// true of `.requiresApproval`, which is the user having switched the login item off in
/// System Settings — also honestly rendered as off.
@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var isEnabled = false

    init() { refresh() }

    func refresh() { isEnabled = SMAppService.mainApp.status == .enabled }

    func toggle() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            log.error("launch at login toggle failed: \(error, privacy: .public)")
        }
        refresh()
    }
}
