import Foundation

public struct QueryHistoryEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var connectionID: UUID
    public var sql: String
    public var executedAt: Date
    public var durationMilliseconds: Double
    public var rowCount: Int?
    public var error: String?

    public init(id: UUID = UUID(), connectionID: UUID, sql: String, executedAt: Date = Date(), durationMilliseconds: Double, rowCount: Int? = nil, error: String? = nil) {
        self.id = id
        self.connectionID = connectionID
        self.sql = sql
        self.executedAt = executedAt
        self.durationMilliseconds = durationMilliseconds
        self.rowCount = rowCount
        self.error = error
    }
}

/// Persists executed queries as JSON, newest first, capped at `limit` entries.
public struct QueryHistoryStore: Sendable {
    public let fileURL: URL
    public let limit: Int

    public init(fileURL: URL, limit: Int = 1_000) {
        self.fileURL = fileURL
        self.limit = limit
    }

    public func load() throws -> [QueryHistoryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([QueryHistoryEntry].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ entries: [QueryHistoryEntry]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Array(entries.prefix(limit))).write(to: fileURL, options: .atomic)
    }

    /// Inserts `entry` at the top. Re-running the same SQL on the same connection moves it up
    /// instead of adding a duplicate.
    public func adding(_ entry: QueryHistoryEntry, to entries: [QueryHistoryEntry]) -> [QueryHistoryEntry] {
        let normalized = entry.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = entries.filter {
            !($0.connectionID == entry.connectionID && $0.sql.trimmingCharacters(in: .whitespacesAndNewlines) == normalized)
        }
        updated.insert(entry, at: 0)
        return Array(updated.prefix(limit))
    }
}
