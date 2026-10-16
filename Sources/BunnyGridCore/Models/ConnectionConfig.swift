import Foundation

/// Database engines BunnyGrid knows how to talk to.
public enum DatabaseKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case sqlite
    case postgresql
    case mysql
    case mariadb

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sqlite: "SQLite"
        case .postgresql: "PostgreSQL"
        case .mysql: "MySQL"
        case .mariadb: "MariaDB"
        }
    }

    public var defaultPort: Int? {
        switch self {
        case .sqlite: nil
        case .postgresql: 5432
        case .mysql, .mariadb: 3306
        }
    }

    public var isFileBased: Bool { self == .sqlite }

    /// Whether the engine exposes schemas inside a database (PostgreSQL)
    /// or treats databases as the namespace level (MySQL/MariaDB, SQLite).
    public var hasSchemas: Bool { self == .postgresql }
}

public enum TLSMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case disable
    case prefer
    case require

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .disable: "Disabled"
        case .prefer: "Prefer"
        case .require: "Require"
        }
    }
}

/// Color tag shown next to a connection, as in Navicat's connection colors.
public enum ConnectionColor: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, red, orange, yellow, green, blue, purple, gray

    public var id: String { rawValue }
}

/// A saved connection. The password is never stored here; it lives in the Keychain
/// under the connection's `id`.
public struct ConnectionConfig: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: DatabaseKind
    public var host: String
    public var port: Int
    public var username: String
    public var database: String
    /// Path to the database file for file-based engines.
    public var filePath: String
    public var tls: TLSMode
    public var color: ConnectionColor
    public var readOnly: Bool
    /// Folder the connection is listed under in the navigator, if any.
    public var group: String?

    public init(
        id: UUID = UUID(),
        name: String = "",
        kind: DatabaseKind = .postgresql,
        host: String = "localhost",
        port: Int? = nil,
        username: String = "",
        database: String = "",
        filePath: String = "",
        tls: TLSMode = .prefer,
        color: ConnectionColor = .none,
        readOnly: Bool = false,
        group: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port ?? kind.defaultPort ?? 0
        self.username = username
        self.database = database
        self.filePath = filePath
        self.tls = tls
        self.color = color
        self.readOnly = readOnly
        self.group = group
    }

    /// Name shown in the UI, falling back to something derived from the target.
    public var displayName: String {
        if !name.isEmpty { return name }
        if kind.isFileBased { return URL(fileURLWithPath: filePath).lastPathComponent }
        return username.isEmpty ? host : "\(username)@\(host)"
    }
}
