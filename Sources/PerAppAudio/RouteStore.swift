import Foundation
import os

private let log = Logger(subsystem: "dev.perappvolume.app", category: "RouteStore")

/// One route the user asked for, as it survives a relaunch.
///
/// This is *desired* state, not a live route: it outlives the app quitting, the target
/// app quitting and the output device being unplugged. Only an explicit ✕ or Reset All
/// removes one. The names are cached so a row for an app that is not running — or a
/// device that is not attached — can still say what it is waiting for.
struct SavedRoute: Codable, Equatable {
    var deviceUID: String
    var deviceName: String
    var appName: String
    var gain: Float
}

/// The desired routes, keyed by bundle ID, as one JSON blob in UserDefaults.
enum RouteStore {
    private static let key = "routes"

    static func load() -> [String: SavedRoute] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        do {
            return try JSONDecoder().decode([String: SavedRoute].self, from: data)
        } catch {
            // A shape we cannot read is worse than none: starting empty loses the saved
            // routes but leaves the user a working app they can re-route.
            log.error("discarding unreadable saved routes: \(error, privacy: .public)")
            return [:]
        }
    }

    static func save(_ routes: [String: SavedRoute]) {
        guard !routes.isEmpty else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(routes), forKey: key)
        } catch {
            log.error("failed to save routes: \(error, privacy: .public)")
        }
    }
}
