import Foundation

/// Redis-only connection settings. A Redis Cluster is detected from the server (`cluster_enabled:1`); Sentinel
/// is chosen here: the host/port fields (and `sentinels`) name the sentinels, and the driver connects to the
/// master they report for `sentinelMaster`.
public struct RedisOptions: Codable, Hashable, Sendable {
    public var sentinelMaster: String
    /// More sentinels (`host:port`) besides `host`/`port`.
    public var sentinels: [String]

    public init(sentinelMaster: String = "", sentinels: [String] = []) {
        self.sentinelMaster = sentinelMaster
        self.sentinels = sentinels
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sentinelMaster = try c.decodeIfPresent(String.self, forKey: .sentinelMaster) ?? ""
        sentinels = try c.decodeIfPresent([String].self, forKey: .sentinels) ?? []
    }

    public var usesSentinel: Bool { !sentinelMaster.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Key → hash slot, slot → node, and redirect parsing for Redis Cluster.
public enum RedisCluster {
    public static let slotCount = 16384

    public struct Node: Hashable, Sendable {
        public var host: String
        public var port: Int
        public var address: String { "\(host):\(port)" }

        public init(host: String, port: Int) {
            self.host = host
            self.port = port
        }

        public init?(_ text: String) {
            guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]) else { return nil }
            var host = String(text[..<colon])
            if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            self.init(host: host, port: port)
        }
    }

    public struct SlotRange: Hashable, Sendable {
        public var lower: Int
        public var upper: Int
        public var master: Node
    }

    /// CRC16-CCITT (XMODEM), as the cluster spec uses.
    public static func crc16(_ bytes: some Sequence<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }

    /// The slot of a key, honouring hash tags (`{user1}.name` hashes `user1`).
    public static func slot(_ key: Data) -> Int {
        let bytes = [UInt8](key)
        if let open = bytes.firstIndex(of: UInt8(ascii: "{")),
           let close = bytes[(open + 1)...].firstIndex(of: UInt8(ascii: "}")), close > open + 1 {
            return Int(crc16(bytes[(open + 1)..<close]) % UInt16(slotCount))
        }
        return Int(crc16(bytes) % UInt16(slotCount))
    }

    public static func slot(_ key: String) -> Int { slot(Data(key.utf8)) }

    /// `CLUSTER SLOTS`: `[[start, end, [host, port, id…], replicas…], …]`. Empty hosts mean the node that answered.
    public static func slotRanges(_ reply: RESPValue, defaultHost: String) -> [SlotRange] {
        (reply.elements ?? []).compactMap { entry in
            guard let parts = entry.elements, parts.count >= 3, let lower = parts[0].int, let upper = parts[1].int,
                  let master = parts[2].elements, master.count >= 2, let port = master[1].int else { return nil }
            var host = master[0].string ?? ""
            if host.isEmpty || host == "?" { host = defaultHost }
            return SlotRange(lower: Int(lower), upper: Int(upper), master: Node(host: host, port: Int(port)))
        }.sorted { $0.lower < $1.lower }
    }

    /// `MOVED 3999 127.0.0.1:6381` / `ASK 3999 127.0.0.1:6381`.
    public enum Redirect: Equatable, Sendable {
        case moved(slot: Int, node: Node)
        case ask(slot: Int, node: Node)
    }

    public static func redirect(_ message: String) -> Redirect? {
        let parts = message.split(separator: " ")
        guard parts.count >= 3, let slot = Int(parts[1]), let node = Node(String(parts[2])) else { return nil }
        switch parts[0] {
        case "MOVED": return .moved(slot: slot, node: node)
        case "ASK": return .ask(slot: slot, node: node)
        default: return nil
        }
    }

    /// Commands without keys, run on any node (the first one).
    static let keylessCommands: Set<String> = [
        "PING", "INFO", "DBSIZE", "TIME", "CONFIG", "CLIENT", "SLOWLOG", "COMMAND", "CLUSTER", "ECHO", "HELLO", "AUTH",
        "SELECT", "SCAN", "KEYS", "RANDOMKEY", "LASTSAVE", "ROLE", "MEMORY", "FLUSHDB", "FLUSHALL", "MULTI", "EXEC", "DISCARD",
        "WAIT", "ACL", "MODULE", "FUNCTION", "SCRIPT", "PUBLISH", "PUBSUB", "LATENCY", "DEBUG", "SAVE", "BGSAVE", "SHUTDOWN",
        "READONLY", "READWRITE", "ASKING", "QUIT", "RESET", "SWAPDB", "MONITOR",
    ]

    /// The key a command routes by: the first key argument for the usual commands (`EVAL`/`FCALL` after numkeys,
    /// `XREAD`/`XREADGROUP` after STREAMS, `OBJECT`/`MEMORY USAGE`/`XINFO` after the subcommand).
    public static func routingKey(_ command: [Data]) -> Data? {
        guard let first = command.first else { return nil }
        let name = String(decoding: first, as: UTF8.self).uppercased()
        func arg(_ i: Int) -> Data? { command.indices.contains(i) ? command[i] : nil }
        switch name {
        case "EVAL", "EVALSHA", "EVAL_RO", "EVALSHA_RO", "FCALL", "FCALL_RO":
            guard let n = arg(2).flatMap({ Int(String(decoding: $0, as: UTF8.self)) }), n > 0 else { return nil }
            return arg(3)
        case "XREAD", "XREADGROUP":
            guard let i = command.firstIndex(where: { String(decoding: $0, as: UTF8.self).uppercased() == "STREAMS" }) else { return nil }
            return arg(i + 1)
        case "OBJECT", "XINFO", "XGROUP": return arg(2)
        case "MEMORY": return String(decoding: arg(1) ?? Data(), as: UTF8.self).uppercased() == "USAGE" ? arg(2) : nil
        default:
            return keylessCommands.contains(name) ? nil : arg(1)
        }
    }

    /// A cluster-wide SCAN cursor: which master (by index) and that node's own cursor, as `node:cursor` ("0" ends).
    public static func scanCursor(_ text: String) -> (node: Int, cursor: String) {
        let parts = text.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let node = Int(parts[0]) else { return (0, text.isEmpty ? "0" : text) }
        return (node, String(parts[1]))
    }
}

/// Sentinel replies.
public enum RedisSentinel {
    /// `SENTINEL GET-MASTER-ADDR-BY-NAME name` → `[host, port]` (nil when the master is unknown).
    public static func masterAddress(_ reply: RESPValue) -> RedisCluster.Node? {
        guard let parts = reply.elements, parts.count == 2, let host = parts[0].string, let port = parts[1].string.flatMap(Int.init) else { return nil }
        return RedisCluster.Node(host: host, port: port)
    }
}
