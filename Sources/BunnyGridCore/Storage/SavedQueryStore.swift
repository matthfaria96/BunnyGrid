import Foundation

/// A named query saved under a database, shown in the navigator's Queries folder.
public struct SavedQuery: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var connectionID: UUID
    public var database: String
    public var name: String
    public var sql: String
    public var updatedAt: Date

    public init(id: UUID = UUID(), connectionID: UUID, database: String, name: String, sql: String, updatedAt: Date = Date()) {
        self.id = id
        self.connectionID = connectionID
        self.database = database
        self.name = name
        self.sql = sql
        self.updatedAt = updatedAt
    }
}

/// A starred object, listed in the Favorites menu.
public struct FavoriteObject: Codable, Hashable, Identifiable, Sendable {
    public var connectionID: UUID
    public var database: String
    public var schema: String?
    public var name: String
    public var kind: DatabaseObjectKind

    public init(connectionID: UUID, database: String, schema: String?, name: String, kind: DatabaseObjectKind) {
        self.connectionID = connectionID
        self.database = database
        self.schema = schema
        self.name = name
        self.kind = kind
    }

    public var id: String { "\(connectionID.uuidString)/\(database)/\(schema ?? "")/\(name)" }

    public var object: DatabaseObject { DatabaseObject(schema: schema, name: name, kind: kind) }
}


/// Generic JSON file store for small lists (saved queries, favorites).
public struct JSONListStore<Element: Codable & Sendable>: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> [Element] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Element].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ elements: [Element]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(elements).write(to: fileURL, options: .atomic)
    }
}
