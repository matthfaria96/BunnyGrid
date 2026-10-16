import Foundation

/// Persists saved connections as JSON in Application Support.
/// Passwords are kept out of this file; see `KeychainStore`.
public struct ConnectionStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = ConnectionStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "BunnyGrid", directoryHint: .isDirectory)
            .appending(path: "connections.json")
    }

    public func load() throws -> [ConnectionConfig] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ConnectionConfig].self, from: data)
    }

    public func save(_ connections: [ConnectionConfig]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(connections).write(to: fileURL, options: .atomic)
    }
}
