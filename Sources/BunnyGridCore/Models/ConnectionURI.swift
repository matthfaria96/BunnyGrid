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

        guard let components = URLComponents(string: trimmed), let host = components.host, !host.isEmpty else {
            throw ParseError.invalid
        }
        var database = components.path
        if database.hasPrefix("/") { database.removeFirst() }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        let sslValue = (query["sslmode"] ?? query["ssl-mode"] ?? query["ssl"] ?? "").lowercased()
        let tls: TLSMode = switch sslValue {
        case "disable", "disabled", "false", "0": .disable
        case "require", "required", "verify-ca", "verify-full", "verify_identity", "true", "1": .require
        default: .prefer
        }
        let config = ConnectionConfig(
            kind: kind,
            host: host,
            port: components.port,
            username: components.user?.removingPercentEncoding ?? "",
            database: database.removingPercentEncoding ?? database,
            tls: tls
        )
        return Parsed(config: config, password: components.password?.removingPercentEncoding)
    }

    /// The connection as a URI (without the password unless one is given), for the URI button.
    public static func string(for config: ConnectionConfig, password: String? = nil) -> String {
        if config.kind == .sqlite {
            return "sqlite://" + (config.filePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? config.filePath)
        }
        var components = URLComponents()
        components.scheme = config.kind == .postgresql ? "postgresql" : config.kind.rawValue
        components.host = config.host
        components.port = config.port
        if !config.username.isEmpty { components.user = config.username }
        if let password, !password.isEmpty { components.password = password }
        components.path = config.database.isEmpty ? "" : "/" + config.database
        switch config.tls {
        case .disable: components.queryItems = [URLQueryItem(name: config.kind == .postgresql ? "sslmode" : "ssl-mode", value: config.kind == .postgresql ? "disable" : "DISABLED")]
        case .require: components.queryItems = [URLQueryItem(name: config.kind == .postgresql ? "sslmode" : "ssl-mode", value: config.kind == .postgresql ? "require" : "REQUIRED")]
        case .prefer: break
        }
        return components.string ?? ""
    }
}

