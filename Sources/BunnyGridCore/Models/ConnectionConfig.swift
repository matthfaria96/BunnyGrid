import Foundation

/// Database engines BunnyGrid knows how to talk to.
public enum DatabaseKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case sqlite
    case postgresql
    case mysql
    case mariadb
    case sqlserver
    case redis
    case mongodb

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sqlite: "SQLite"
        case .postgresql: "PostgreSQL"
        case .mysql: "MySQL"
        case .mariadb: "MariaDB"
        case .sqlserver: "SQL Server"
        case .redis: "Redis"
        case .mongodb: "MongoDB"
        }
    }

    public var defaultPort: Int? {
        switch self {
        case .sqlite: nil
        case .postgresql: 5432
        case .mysql, .mariadb: 3306
        case .sqlserver: 1433
        case .redis: 6379
        case .mongodb: 27017
        }
    }

    public var isFileBased: Bool { self == .sqlite }

    /// Whether the engine exposes schemas inside a database (PostgreSQL, SQL Server)
    /// or treats databases as the namespace level (MySQL/MariaDB, SQLite).
    public var hasSchemas: Bool { self == .postgresql || self == .sqlserver }

    /// The schema unqualified names resolve to: `public` on PostgreSQL, `dbo` on SQL Server.
    public var defaultSchema: String? {
        switch self {
        case .postgresql: "public"
        case .sqlserver: "dbo"
        default: nil
        }
    }

    /// Engines that open one connection per database (the navigator's database nodes each get a driver).
    public var connectsPerDatabase: Bool { self == .postgresql || self == .sqlserver }

    /// The database a server-level connection attaches to when none is configured.
    public var serverDatabase: String? {
        switch self {
        case .postgresql: "postgres"
        case .sqlserver: "master"
        default: nil
        }
    }

    /// Key-value engines browse keys instead of tables (`KeyValueDatabaseDriver`).
    public var isKeyValue: Bool { self == .redis }
    /// Document stores (MongoDB): collections of documents instead of SQL tables; the driver also
    /// implements `DocumentDatabaseDriver`.
    public var isDocumentStore: Bool { self == .mongodb }
}

/// SSL modes, named after libpq's `sslmode` (MySQL's `ssl-mode` maps onto the same five).
public enum TLSMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Plain TCP.
    case disable
    /// Encrypt when the server supports it, otherwise fall back to plain TCP. No certificate check.
    case prefer
    /// Always encrypt; fail if the server can't. No certificate check.
    case require
    /// Always encrypt and check the server certificate against the CA (or the system's trusted roots).
    case verifyCA = "verify-ca"
    /// As verify-ca, and the certificate must also name the host.
    case verifyFull = "verify-full"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .disable: "Disabled"
        case .prefer: "Prefer"
        case .require: "Require"
        case .verifyCA: "Verify CA"
        case .verifyFull: "Verify Full"
        }
    }

    /// Whether the connection must be encrypted (fails instead of falling back to plain TCP).
    public var isEnforced: Bool { self != .disable && self != .prefer }
    /// Whether the server certificate chain is checked.
    public var verifiesCertificate: Bool { self == .verifyCA || self == .verifyFull }
}

/// Certificate files for the SSL tab. Paths are PEM files on disk; the client key's passphrase is
/// in the Keychain (`KeychainStore.sslKeyAccount`).
public struct SSLFiles: Codable, Hashable, Sendable {
    /// CA (PostgreSQL's "root certificate") the server certificate must chain to. Empty uses the system's trusted roots.
    public var caCertificatePath: String
    /// Client certificate and key, for servers that authenticate clients by certificate.
    public var clientCertificatePath: String
    public var clientKeyPath: String

    public init(caCertificatePath: String = "", clientCertificatePath: String = "", clientKeyPath: String = "") {
        self.caCertificatePath = caCertificatePath
        self.clientCertificatePath = clientCertificatePath
        self.clientKeyPath = clientKeyPath
    }

    public var isEmpty: Bool { caCertificatePath.isEmpty && clientCertificatePath.isEmpty && clientKeyPath.isEmpty }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        caCertificatePath = try c.decodeIfPresent(String.self, forKey: .caCertificatePath) ?? ""
        clientCertificatePath = try c.decodeIfPresent(String.self, forKey: .clientCertificatePath) ?? ""
        clientKeyPath = try c.decodeIfPresent(String.self, forKey: .clientKeyPath) ?? ""
    }
}

/// How the SSH tunnel logs in.
public enum SSHAuthMethod: String, Codable, CaseIterable, Sendable, Identifiable {
    case password
    case publicKey

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .password: "Password"
        case .publicKey: "Public Key"
        }
    }
}

/// One extra SQLite database file of a connection (Navicat's Databases tab): ATTACHed as `alias`.
public struct AttachedDatabase: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var alias: String
    public var path: String

    public init(alias: String, path: String) {
        self.alias = alias
        self.path = path
    }

    /// A default alias for a file: its name without extension, as an identifier (`sales-2024.db` → `sales_2024`).
    public static func suggestedAlias(for path: String, taken: [String]) -> String {
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        var base = String(stem.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        if base.isEmpty || base.first!.isNumber { base = "db_" + base }
        let lowered = Set(taken.map { $0.lowercased() } + ["main", "temp"])
        var alias = base, n = 2
        while lowered.contains(alias.lowercased()) { alias = "\(base)_\(n)"; n += 1 }
        return alias
    }
}

/// The SSH tab: connect to the database through a local port forwarded over SSH.
/// The SSH password or the key's passphrase is in the Keychain (`KeychainStore.sshAccount`).
public struct SSHTunnelConfig: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var host: String
    public var port: Int
    public var username: String
    public var authMethod: SSHAuthMethod
    /// OpenSSH private key file (ed25519 or RSA) or a PEM ECDSA key, for `.publicKey`.
    public var privateKeyPath: String

    public init(enabled: Bool = false, host: String = "", port: Int = 22, username: String = "", authMethod: SSHAuthMethod = .password, privateKeyPath: String = "") {
        self.enabled = enabled
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.privateKeyPath = privateKeyPath
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        authMethod = try c.decodeIfPresent(SSHAuthMethod.self, forKey: .authMethod) ?? .password
        privateKeyPath = try c.decodeIfPresent(String.self, forKey: .privateKeyPath) ?? ""
    }
}

/// Secrets a driver needs at connect time, read from the Keychain by the app. Never persisted.
public struct ConnectionSecrets: Hashable, Sendable {
    public var password: String?
    /// The SSH password, or the private key's passphrase, depending on `SSHTunnelConfig.authMethod`.
    public var sshSecret: String?
    /// Passphrase of an encrypted SSL client key.
    public var sslKeyPassphrase: String?

    public init(password: String? = nil, sshSecret: String? = nil, sslKeyPassphrase: String? = nil) {
        self.password = password
        self.sshSecret = sshSecret
        self.sslKeyPassphrase = sslKeyPassphrase
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
    /// Free-form notes (Navicat's Remarks tab), shown in the Info pane.
    public var remarks: String?
    /// Connect when BunnyGrid starts (Advanced tab).
    public var autoConnect: Bool?
    /// SQL run on every new connection, e.g. `SET search_path …` (Advanced tab). Statements are split on `;`.
    public var initialQueries: String?
    /// SSL tab: CA and client certificate files (the mode is `tls`).
    public var ssl: SSLFiles?
    /// SSH tab: tunnel to the server through an SSH host.
    public var ssh: SSHTunnelConfig?
    /// Unix domain socket (Advanced tab, "Use socket file"). When set, `host` and `port` are ignored.
    public var socketPath: String?
    /// MongoDB: SRV, auth source and mechanism, replica set (nil for other engines).
    public var mongo: MongoOptions?
    /// Databases tab, SQLite: more database files ATTACHed on every connection, beside main.
    public var attachedDatabases: [AttachedDatabase]?
    /// Databases tab, servers: the databases the navigator lists (nil or empty lists them all).
    public var visibleDatabases: [String]?

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

    /// The SSH tunnel, when it is switched on.
    public var activeSSH: SSHTunnelConfig? {
        guard !kind.isFileBased, let ssh, ssh.enabled else { return nil }
        return ssh
    }

    /// The socket file, when one is set (server engines only).
    public var activeSocketPath: String? {
        guard !kind.isFileBased, let path = socketPath?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return nil }
        return (path as NSString).expandingTildeInPath
    }

    /// The databases to list in the navigator: `visibleDatabases` in server order, plus the connection's
    /// own database (always shown); everything when no choice was made.
    public func visible(_ databases: [String]) -> [String] {
        guard let chosen = visibleDatabases, !chosen.isEmpty else { return databases }
        let keep = Set(chosen).union(database.isEmpty ? [] : [database])
        return databases.filter { keep.contains($0) }
    }

    /// Name shown in the UI, falling back to something derived from the target.
    public var displayName: String {
        if !name.isEmpty { return name }
        if kind.isFileBased { return URL(fileURLWithPath: filePath).lastPathComponent }
        return username.isEmpty ? host : "\(username)@\(host)"
    }
}
