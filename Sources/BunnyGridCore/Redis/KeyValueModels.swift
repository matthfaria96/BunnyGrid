import Foundation

/// Redis data types, as `TYPE` names them.
public enum RedisKeyType: Hashable, Sendable, Identifiable, CaseIterable {
    case string, hash, list, set, zset, stream, json
    case other(String)

    public static let allCases: [RedisKeyType] = [.string, .hash, .list, .set, .zset, .stream, .json]

    public init(typeName: String) {
        switch typeName.lowercased() {
        case "string": self = .string
        case "hash": self = .hash
        case "list": self = .list
        case "set": self = .set
        case "zset": self = .zset
        case "stream": self = .stream
        case "rejson-rl", "json", "rejson": self = .json
        default: self = .other(typeName)
        }
    }

    public var id: String { typeName }

    /// The name `TYPE` returns and `SCAN … TYPE` accepts.
    public var typeName: String {
        switch self {
        case .string: "string"
        case .hash: "hash"
        case .list: "list"
        case .set: "set"
        case .zset: "zset"
        case .stream: "stream"
        case .json: "ReJSON-RL"
        case .other(let name): name
        }
    }

    public var displayName: String {
        switch self {
        case .string: "String"
        case .hash: "Hash"
        case .list: "List"
        case .set: "Set"
        case .zset: "Sorted Set"
        case .stream: "Stream"
        case .json: "JSON"
        case .other(let name): name
        }
    }
}

/// One key from a SCAN, with its type when the server reported it.
public struct RedisKeyEntry: Hashable, Sendable, Identifiable {
    public var key: String
    public var type: RedisKeyType?

    public var id: String { key }

    public init(key: String, type: RedisKeyType? = nil) {
        self.key = key
        self.type = type
    }
}

public struct RedisScanPage: Sendable {
    /// "0" when the scan is complete.
    public var cursor: String
    public var keys: [String]

    public var isComplete: Bool { cursor == "0" }
}

/// TYPE, TTL, MEMORY USAGE and length of one key.
public struct RedisKeyInfo: Hashable, Sendable {
    public var key: String
    public var type: RedisKeyType
    /// Seconds; -1 without expiry, -2 when the key does not exist.
    public var ttl: Int64
    public var memoryBytes: Int64?
    /// STRLEN, HLEN, LLEN, SCARD, ZCARD, XLEN; nil for JSON and unknown types.
    public var length: Int64?

    public var exists: Bool { ttl != -2 }
}

public struct RedisStreamEntry: Hashable, Sendable, Identifiable {
    public var id: String
    public var fields: [RedisPair]

    public init(id: String, fields: [RedisPair]) {
        self.id = id
        self.fields = fields
    }
}

public struct RedisPair: Hashable, Sendable {
    public var field: Data
    public var value: Data

    public init(field: Data, value: Data) {
        self.field = field
        self.value = value
    }

    public init(_ field: String, _ value: String) {
        self.init(field: Data(field.utf8), value: Data(value.utf8))
    }
}

public struct RedisScoredMember: Hashable, Sendable {
    public var member: Data
    public var score: Double

    public init(member: Data, score: Double) {
        self.member = member
        self.score = score
    }
}

/// A key's value, read up to a limit of elements (`isTruncated` when more exist).
public enum RedisValue: Hashable, Sendable {
    case string(Data)
    case hash([RedisPair])
    case list([Data])
    case set([Data])
    case zset([RedisScoredMember])
    case stream([RedisStreamEntry])
    case json(String)
    case unsupported(String)

    public var count: Int {
        switch self {
        case .string, .json, .unsupported: 1
        case .hash(let p): p.count
        case .list(let l), .set(let l): l.count
        case .zset(let z): z.count
        case .stream(let s): s.count
        }
    }
}

/// Key counts of one database from `INFO keyspace` ("db0:keys=12,expires=1,avg_ttl=0").
public struct RedisKeyspace: Hashable, Sendable {
    public var keys: Int
    public var expires: Int
    public var averageTTL: Int

    /// Totals of two nodes (cluster keyspace); the average TTL is the larger one.
    func adding(_ other: RedisKeyspace) -> RedisKeyspace {
        RedisKeyspace(keys: keys + other.keys, expires: expires + other.expires, averageTTL: max(averageTTL, other.averageTTL))
    }
}

/// INFO, CLIENT LIST and SLOWLOG parsed for the server pane.
public enum RedisInfo {
    public struct Section: Hashable, Sendable, Identifiable {
        public var name: String
        public var entries: [Entry]
        public var id: String { name }
    }

    public struct Entry: Hashable, Sendable, Identifiable {
        public var key: String
        public var value: String
        public var id: String { key }
    }

    /// `# Server` headings followed by `key:value` lines.
    public static func parse(_ text: String) -> [Section] {
        var sections: [Section] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                sections.append(Section(name: line.dropFirst().trimmingCharacters(in: .whitespaces), entries: []))
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            if sections.isEmpty { sections.append(Section(name: "Info", entries: [])) }
            sections[sections.count - 1].entries.append(Entry(key: String(line[..<colon]), value: String(line[line.index(after: colon)...])))
        }
        return sections
    }

    /// Database index → counts, from the Keyspace section.
    public static func keyspace(_ text: String) -> [Int: RedisKeyspace] {
        var result: [Int: RedisKeyspace] = [:]
        for section in parse(text) where section.name.lowercased() == "keyspace" {
            for entry in section.entries where entry.key.hasPrefix("db") {
                guard let index = Int(entry.key.dropFirst(2)) else { continue }
                let fields = fields(entry.value, separator: ",")
                result[index] = RedisKeyspace(keys: Int(fields["keys"] ?? "") ?? 0, expires: Int(fields["expires"] ?? "") ?? 0,
                                              averageTTL: Int(fields["avg_ttl"] ?? "") ?? 0)
            }
        }
        return result
    }

    /// "a=1,b=2" or "a=1 b=2" as a dictionary.
    public static func fields(_ text: String, separator: Character) -> [String: String] {
        var out: [String: String] = [:]
        for part in text.split(separator: separator) {
            guard let eq = part.firstIndex(of: "=") else { continue }
            out[String(part[..<eq])] = String(part[part.index(after: eq)...])
        }
        return out
    }

    /// CLIENT LIST: one client per line of space-separated `key=value`.
    public static func clients(_ text: String) -> [[String: String]] {
        text.split(whereSeparator: \.isNewline).map { fields(String($0), separator: " ") }.filter { !$0.isEmpty }
    }

    public struct SlowlogEntry: Hashable, Sendable, Identifiable {
        public var id: Int64
        public var timestamp: Date
        public var durationMicroseconds: Int64
        public var command: String
        public var client: String
    }

    /// SLOWLOG GET: arrays of id, unix time, microseconds, arguments[, client address, client name].
    public static func slowlog(_ reply: RESPValue) -> [SlowlogEntry] {
        (reply.elements ?? []).compactMap { item in
            guard let parts = item.elements, parts.count >= 4, let id = parts[0].int, let time = parts[1].int, let micros = parts[2].int else { return nil }
            let args = (parts[3].elements ?? []).map { RedisCommandLine.quote($0.data ?? Data()) }
            return SlowlogEntry(id: id, timestamp: Date(timeIntervalSince1970: TimeInterval(time)), durationMicroseconds: micros,
                                command: args.joined(separator: " "), client: parts.count > 4 ? parts[4].string ?? "" : "")
        }
    }
}

/// Folders built from key names split on a separator (":"), as Navicat and other Redis clients show them.
public enum RedisKeyTree {
    public indirect enum Node: Hashable, Sendable, Identifiable {
        /// `path` is the full prefix including the trailing separator ("user:" for keys "user:1", "user:2").
        case folder(name: String, path: String, children: [Node], keyCount: Int)
        case key(name: String, entry: RedisKeyEntry)

        public var id: String {
            switch self {
            case .folder(_, let path, _, _): "folder:" + path
            case .key(_, let entry): "key:" + entry.key
            }
        }

        public var name: String {
            switch self {
            case .folder(let name, _, _, _), .key(let name, _): name
            }
        }
    }

    private final class Builder {
        var folders: [String: Builder] = [:]
        var keys: [(String, RedisKeyEntry)] = []
        var count = 0
    }

    /// Folders first, then keys, each sorted naturally. An empty separator gives a flat list.
    /// A key equal to a folder's prefix ("a" next to "a:b") stays a key beside the folder.
    public static func build(_ entries: [RedisKeyEntry], separator: String) -> [Node] {
        let root = Builder()
        for entry in entries {
            var node = root
            var parts = separator.isEmpty ? [entry.key] : entry.key.components(separatedBy: separator)
            let leaf = parts.removeLast()
            for part in parts {
                node.count += 1
                if let next = node.folders[part] { node = next } else {
                    let next = Builder()
                    node.folders[part] = next
                    node = next
                }
            }
            node.count += 1
            node.keys.append((leaf, entry))
        }
        return nodes(root, prefix: "", separator: separator)
    }

    private static func nodes(_ builder: Builder, prefix: String, separator: String) -> [Node] {
        let order: (String, String) -> Bool = { $0.localizedStandardCompare($1) == .orderedAscending }
        var out: [Node] = []
        for name in builder.folders.keys.sorted(by: order) {
            let child = builder.folders[name]!
            let path = prefix + name + separator
            out.append(.folder(name: name, path: path, children: nodes(child, prefix: path, separator: separator), keyCount: child.count))
        }
        for (name, entry) in builder.keys.sorted(by: { order($0.0, $1.0) }) {
            out.append(.key(name: name, entry: entry))
        }
        return out
    }
}

/// The key browser's contract, apart from the SQL `DatabaseDriver`. Every call names its database
/// (Redis' SELECT index), so one connection can serve the whole tree.
public protocol KeyValueDatabaseDriver: AnyObject, Sendable {
    var config: ConnectionConfig { get }
    func connect() async throws
    func disconnect() async

    func databaseCount() async throws -> Int
    func keyspace() async throws -> [Int: RedisKeyspace]
    func scan(database: Int, cursor: String, pattern: String?, type: RedisKeyType?, count: Int) async throws -> RedisScanPage
    func keyTypes(database: Int, keys: [String]) async throws -> [String: RedisKeyType]
    func keyInfo(database: Int, key: String) async throws -> RedisKeyInfo
    func readValue(database: Int, key: String, type: RedisKeyType, limit: Int) async throws -> RedisValue

    func rename(database: Int, key: String, to newKey: String) async throws
    /// nil removes the expiry (PERSIST).
    func setTTL(database: Int, key: String, seconds: Int64?) async throws
    func delete(database: Int, keys: [String]) async throws

    /// Runs one command on `database` and returns the raw reply (errors come back as `.error`).
    func command(database: Int, _ arguments: [Data]) async throws -> RESPValue
}
