import Foundation

/// Paths and settings shared by the app and the broadcast extension.
/// Both processes see the same App Group container.
enum Shared {
    static var appGroup: String {
        Bundle.main.object(forInfoDictionaryKey: "AppGroup") as? String ?? "group.com.example.carmirror"
    }

    static var containerURL: URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            fatalError("App Group '\(appGroup)' is not configured. Check APP_GROUP in project.yml and signing.")
        }
        return url
    }

    /// HLS playlist + segments written by the extension, served by the app.
    static var streamDir: URL { containerURL.appendingPathComponent("stream", isDirectory: true) }
    static var statusURL: URL { containerURL.appendingPathComponent("status.json") }

    static let playlistName = "live.m3u8"
    static let port: UInt16 = 8089
}

struct BroadcastStatus: Codable {
    enum State: String, Codable { case live, stopped }
    var state: State
    var sessionID: String
    var updated: Date

    static func read() -> BroadcastStatus? {
        guard let data = try? Data(contentsOf: Shared.statusURL) else { return nil }
        return try? JSONDecoder().decode(BroadcastStatus.self, from: data)
    }

    func write() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Shared.statusURL, options: .atomic)
    }
}
