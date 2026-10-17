import Foundation

/// Parses connection URIs such as `postgresql://user:pass@host:5432/db?sslmode=require`,
/// `mysql://user@host/db`, `mariadb://…` and `sqlite:///path/to/file.db`.
public enum ConnectionURI {
    public struct Parsed: Sendable, Equatable {
        public var config: ConnectionConfig
        public var password: String?
    }

    public enum ParseError: LocalizedError, Equatable, Sendable {
        case invalid
        case unsupportedScheme(String)

        public var errorDescription: String? {
            switch self {
            case .invalid: "That doesn't look like a connection URI."
            case .unsupportedScheme(let scheme): "“\(scheme)” connections aren't supported yet. Use postgresql://, mysql://, mariadb:// or sqlite://."
            }
        }
    }

    public static func parse(_ text: String) throws -> Parsed {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = trimmed.range(of: "://") else { throw ParseError.invalid }
        let scheme = trimmed[..<schemeEnd.lowerBound].lowercased()

        let kind: DatabaseKind
        switch scheme {
        case "postgres", "postgresql", "pgsql": kind = .postgresql
        case "mysql", "mysqlx": kind = .mysql
        case "mariadb": kind = .mariadb
        case "sqlite", "file": kind = .sqlite
        default: throw ParseError.unsupportedScheme(scheme)
        }

        if kind == .sqlite {
            let path = String(trimmed[schemeEnd.upperBound...]).removingPercentEncoding ?? ""
            guard !path.isEmpty else { throw ParseError.invalid }
            let config = ConnectionConfig(name: URL(fileURLWithPath: path).lastPathComponent, kind: .sqlite, filePath: path)
            return Parsed(config: config, password: nil)
        }

        guard let components = URLComponents(string: trimmed) else { throw ParseError.invalid }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        // Socket files: libpq's `?host=/tmp` or a percent-encoded path as the host (`postgresql://%2Ftmp/db`), MySQL's `?socket=`.
        var host = components.host ?? ""
        var socketPath = query["socket"].flatMap { $0.isEmpty ? nil : $0 }
        if let queryHost = query["host"], queryHost.hasPrefix("/") { socketPath = queryHost }
        if host.hasPrefix("/") {
            socketPath = host
            host = ""
        }
        if host.isEmpty {
            guard socketPath != nil else { throw ParseError.invalid }
            host = "localhost"
        }
        var database = components.path
        if database.hasPrefix("/") { database.removeFirst() }
        var config = ConnectionConfig(
            kind: kind,
            host: host,
            port: components.port,
            username: components.user?.removingPercentEncoding ?? "",
            database: database.removingPercentEncoding ?? database,
            tls: tlsMode(query["sslmode"] ?? query["ssl-mode"] ?? query["ssl"] ?? "")
        )
        let files = SSLFiles(
            caCertificatePath: query["sslrootcert"] ?? query["ssl-ca"] ?? query["sslca"] ?? "",
            clientCertificatePath: query["sslcert"] ?? query["ssl-cert"] ?? "",
            clientKeyPath: query["sslkey"] ?? query["ssl-key"] ?? ""
        )
        if !files.isEmpty { config.ssl = files }
        config.socketPath = socketPath
        return Parsed(config: config, password: components.password?.removingPercentEncoding)
    }

    /// libpq `sslmode` and MySQL `ssl-mode` values (and the `ssl=true/false` shorthand).
    static func tlsMode(_ value: String) -> TLSMode {
        switch value.lowercased() {
        case "disable", "disabled", "false", "0": .disable
        case "require", "required", "true", "1": .require
        case "verify-ca", "verify_ca": .verifyCA
        case "verify-full", "verify_full", "verify_identity", "verify-identity": .verifyFull
        default: .prefer
        }
    }

    /// The connection as a URI (without the password unless one is given), for the URI button.
    /// SSH settings have no URI form and are left out.
    public static func string(for config: ConnectionConfig, password: String? = nil) -> String {
        if config.kind == .sqlite {
            return "sqlite://" + (config.filePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? config.filePath)
        }
        let postgres = config.kind == .postgresql
        var components = URLComponents()
        components.scheme = postgres ? "postgresql" : config.kind.rawValue
        components.host = config.host
        components.port = config.port
        if !config.username.isEmpty { components.user = config.username }
        if let password, !password.isEmpty { components.password = password }
        components.path = config.database.isEmpty ? "" : "/" + config.database
        var items: [URLQueryItem] = []
        let mode: String? = switch config.tls {
        case .prefer: nil
        case .disable: postgres ? "disable" : "DISABLED"
        case .require: postgres ? "require" : "REQUIRED"
        case .verifyCA: postgres ? "verify-ca" : "VERIFY_CA"
        case .verifyFull: postgres ? "verify-full" : "VERIFY_IDENTITY"
        }
        if let mode { items.append(URLQueryItem(name: postgres ? "sslmode" : "ssl-mode", value: mode)) }
        if let files = config.ssl {
            if !files.caCertificatePath.isEmpty { items.append(URLQueryItem(name: postgres ? "sslrootcert" : "ssl-ca", value: files.caCertificatePath)) }
            if !files.clientCertificatePath.isEmpty { items.append(URLQueryItem(name: postgres ? "sslcert" : "ssl-cert", value: files.clientCertificatePath)) }
            if !files.clientKeyPath.isEmpty { items.append(URLQueryItem(name: postgres ? "sslkey" : "ssl-key", value: files.clientKeyPath)) }
        }
        if let socket = config.socketPath, !socket.isEmpty {
            items.append(URLQueryItem(name: postgres ? "host" : "socket", value: socket))
        }
        if !items.isEmpty { components.queryItems = items }
        return components.string ?? ""
    }
}

