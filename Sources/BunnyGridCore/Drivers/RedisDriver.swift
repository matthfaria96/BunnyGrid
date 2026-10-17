import Foundation
import NIOSSL

public enum RedisError: LocalizedError, Equatable, Sendable {
    case server(String)
    case keyExists(String)
    case unsupportedInConsole(String)

    public var errorDescription: String? {
        switch self {
        case .server(let message): message
        case .keyExists(let key): "A key named “\(key)” already exists."
        case .unsupportedInConsole(let command): "\(command) keeps the connection in a streaming mode, which the console doesn't support yet."
        }
    }
}

/// Redis on a small RESP2/RESP3 client over SwiftNIO (`RedisConnection`). AUTH with a password or an ACL user,
/// SELECT, TLS when the SSL mode is Require or Verify (Redis has no in-protocol upgrade, so Prefer means plain TCP),
/// Unix sockets and the SSH tunnel through `ConnectionEndpoint`. Conforms to `DatabaseDriver` too, so Test Connection,
/// Initial Queries and the session code work unchanged: there, statements are command lines on the default database.
public actor RedisDriver: KeyValueDatabaseDriver, DatabaseDriver {
    public nonisolated let config: ConnectionConfig
    private let secrets: ConnectionSecrets
    private var connection: RedisConnection?
    private var endpoint: ConnectionEndpoint?
    /// The database the connection is on; SELECT is sent only when a call needs another one.
    private var selected = 0
    public private(set) var protocolVersion = 2
    private var hasJSONModule: Bool?

    public init(config: ConnectionConfig, secrets: ConnectionSecrets) {
        self.config = config
        self.secrets = secrets
    }

    /// The Default Database field holds the index ("0"…"15", or "db3").
    public nonisolated var defaultDatabase: Int {
        let text = config.database.trimmingCharacters(in: .whitespaces).lowercased()
        return Int(text.hasPrefix("db") ? String(text.dropFirst(2)) : text) ?? 0
    }

    /// TLS applies over TCP when the mode enforces it.
    nonisolated static func usesTLS(_ config: ConnectionConfig, endpoint: ConnectionEndpoint) -> Bool {
        endpoint.usesTLS && config.tls.isEnforced
    }

    public func connect() async throws {
        guard connection == nil else { return }
        let endpoint = try await ConnectionEndpoint.open(for: config, sshSecret: secrets.sshSecret)
        do {
            let tls = Self.usesTLS(config, endpoint: endpoint)
                ? try ConnectionTLS.configuration(for: config, keyPassphrase: secrets.sslKeyPassphrase) : nil
            let connection: RedisConnection
            do {
                connection = try await RedisConnection.open(address: endpoint.address, tls: tls, serverName: endpoint.tlsServerName)
            } catch {
                throw DatabaseError.connectionFailed(ConnectionErrorText.describe(error))
            }
            do {
                try await handshake(connection)
            } catch {
                await connection.close()
                throw error
            }
            self.connection = connection
            self.endpoint = endpoint
        } catch {
            await endpoint.close()
            throw error
        }
    }

    /// HELLO 3 with AUTH when the server has it (Redis 6+); otherwise AUTH and RESP2. Then SELECT.
    private func handshake(_ connection: RedisConnection) async throws {
        let user = config.username.trimmingCharacters(in: .whitespaces)
        let password = secrets.password ?? ""
        var hello: [String] = ["HELLO", "3"]
        if !password.isEmpty { hello += ["AUTH", user.isEmpty ? "default" : user, password] }
        let reply: RESPValue
        do {
            reply = try await connection.send([hello.map { Data($0.utf8) }])[0]
        } catch {
            throw DatabaseError.connectionFailed(ConnectionErrorText.describe(error))
        }
        if case .error(let message) = reply {
            let upper = message.uppercased()
            if upper.contains("WRONGPASS") || upper.contains("NOAUTH") && !password.isEmpty || upper.contains("INVALID PASSWORD") {
                throw DatabaseError.connectionFailed(message)
            }
            // Older servers or proxies without HELLO: RESP2 with AUTH.
            protocolVersion = 2
            if !password.isEmpty {
                let auth = user.isEmpty ? ["AUTH", password] : ["AUTH", user, password]
                if case .error(let message) = try await connection.send([auth.map { Data($0.utf8) }])[0] {
                    throw DatabaseError.connectionFailed(message)
                }
            }
        } else {
            protocolVersion = 3
        }
        selected = 0
        let db = defaultDatabase
        if db != 0 {
            if case .error(let message) = try await connection.send([["SELECT", String(db)].map { Data($0.utf8) }])[0] {
                throw DatabaseError.connectionFailed(message)
            }
            selected = db
        }
        // Check the connection really answers commands (NOAUTH shows up here when no password was given).
        if case .error(let message) = try await connection.send([[Data("PING".utf8)]])[0] {
            throw DatabaseError.connectionFailed(message)
        }
    }

    public func disconnect() async {
        await connection?.close()
        connection = nil
        await endpoint?.close()
        endpoint = nil
    }

    // MARK: - Commands

    /// Sends commands back to back on `database` (with a SELECT first when needed) and returns their replies.
    func pipeline(database: Int?, _ commands: [[Data]]) async throws -> [RESPValue] {
        guard let connection else { throw DatabaseError.notConnected }
        var batch = commands
        var selects = 0
        if let database, database != selected {
            batch.insert(["SELECT", String(database)].map { Data($0.utf8) }, at: 0)
            selects = 1
            selected = database
        }
        let futures = connection.enqueue(batch)
        do {
            var replies: [RESPValue] = []
            for future in futures { replies.append(try await future.get()) }
            if selects == 1, case .error(let message) = replies[0] {
                selected = -1
                throw RedisError.server(message)
            }
            return Array(replies.dropFirst(selects))
        } catch let error as RedisError {
            throw error
        } catch {
            if !connection.isActive { self.connection = nil }
            throw DatabaseError.queryFailed(ConnectionErrorText.describe(error))
        }
    }

    public func command(database: Int, _ arguments: [Data]) async throws -> RESPValue {
        try await pipeline(database: database, [arguments])[0]
    }

    /// A command whose error reply is thrown.
    func call(_ database: Int?, _ arguments: [String]) async throws -> RESPValue {
        let reply = try await pipeline(database: database, [arguments.map { Data($0.utf8) }])[0]
        if case .error(let message) = reply { throw RedisError.server(message) }
        return reply
    }

    func call(_ database: Int?, _ arguments: [Data]) async throws -> RESPValue {
        let reply = try await pipeline(database: database, [arguments])[0]
        if case .error(let message) = reply { throw RedisError.server(message) }
        return reply
    }

    /// MULTI … EXEC in one write; throws the first error.
    func transaction(_ database: Int, _ commands: [[Data]]) async throws {
        let replies = try await pipeline(database: database, [[Data("MULTI".utf8)]] + commands + [[Data("EXEC".utf8)]])
        for reply in replies {
            if case .error(let message) = reply { throw RedisError.server(message) }
        }
        if let exec = replies.last?.elements {
            for reply in exec { if case .error(let message) = reply { throw RedisError.server(message) } }
        }
    }

    private func checkWritable() throws {
        if config.readOnly { throw DatabaseError.readOnly }
    }

    // MARK: - Browser

    public func databaseCount() async throws -> Int {
        if let reply = try? await call(nil, ["CONFIG", "GET", "databases"]), let value = reply.pairs?.first?.1.int, value > 0 {
            return Int(value)
        }
        // Managed services often block CONFIG; cluster mode has only db0.
        if let info = try? await call(nil, ["INFO", "cluster"]).string, info.contains("cluster_enabled:1") { return 1 }
        return 16
    }

    public func keyspace() async throws -> [Int: RedisKeyspace] {
        RedisInfo.keyspace(try await call(nil, ["INFO", "keyspace"]).string ?? "")
    }

    public func scan(database: Int, cursor: String, pattern: String?, type: RedisKeyType?, count: Int) async throws -> RedisScanPage {
        var args = ["SCAN", cursor]
        if let pattern, !pattern.isEmpty, pattern != "*" { args += ["MATCH", pattern] }
        args += ["COUNT", String(max(count, 1))]
        if let type { args += ["TYPE", type.typeName] }
        let reply = try await call(database, args)
        guard let parts = reply.elements, parts.count == 2 else { throw RedisError.server("Unexpected SCAN reply") }
        return RedisScanPage(cursor: parts[0].string ?? "0", keys: (parts[1].elements ?? []).compactMap(\.string))
    }

    public func keyTypes(database: Int, keys: [String]) async throws -> [String: RedisKeyType] {
        guard !keys.isEmpty else { return [:] }
        let replies = try await pipeline(database: database, keys.map { [Data("TYPE".utf8), Data($0.utf8)] })
        var out: [String: RedisKeyType] = [:]
        for (key, reply) in zip(keys, replies) {
            if let name = reply.string, !reply.isError, name != "none" { out[key] = RedisKeyType(typeName: name) }
        }
        return out
    }

    public func keyInfo(database: Int, key: String) async throws -> RedisKeyInfo {
        let k = Data(key.utf8)
        let replies = try await pipeline(database: database, [
            [Data("TYPE".utf8), k], [Data("TTL".utf8), k], ["MEMORY", "USAGE"].map { Data($0.utf8) } + [k],
        ])
        let type = RedisKeyType(typeName: replies[0].string ?? "none")
        let ttl = replies[1].int ?? -2
        var info = RedisKeyInfo(key: key, type: type, ttl: replies[0].string == "none" ? -2 : ttl,
                                memoryBytes: replies[2].isError ? nil : replies[2].int)
        let lengthCommand: String? = switch type {
        case .string: "STRLEN"
        case .hash: "HLEN"
        case .list: "LLEN"
        case .set: "SCARD"
        case .zset: "ZCARD"
        case .stream: "XLEN"
        case .json, .other: nil
        }
        if let lengthCommand, let length = try? await call(database, [lengthCommand, key]).int { info.length = length }
        return info
    }

    public func readValue(database: Int, key: String, type: RedisKeyType, limit: Int) async throws -> RedisValue {
        let limit = max(limit, 1)
        switch type {
        case .string:
            let reply = try await call(database, ["GET", key])
            return .string(reply.data ?? Data())
        case .hash:
            var pairs: [RedisPair] = []
            var cursor = "0"
            repeat {
                let reply = try await call(database, ["HSCAN", key, cursor, "COUNT", "500"])
                guard let parts = reply.elements, parts.count == 2 else { break }
                cursor = parts[0].string ?? "0"
                for (field, value) in parts[1].pairs ?? [] {
                    pairs.append(RedisPair(field: field.data ?? Data(), value: value.data ?? Data()))
                }
            } while cursor != "0" && pairs.count < limit
            return .hash(Array(pairs.prefix(limit)))
        case .list:
            let reply = try await call(database, ["LRANGE", key, "0", String(limit - 1)])
            return .list((reply.elements ?? []).map { $0.data ?? Data() })
        case .set:
            var members: [Data] = []
            var seen = Set<Data>()
            var cursor = "0"
            repeat {
                let reply = try await call(database, ["SSCAN", key, cursor, "COUNT", "500"])
                guard let parts = reply.elements, parts.count == 2 else { break }
                cursor = parts[0].string ?? "0"
                for member in parts[1].elements ?? [] {
                    let data = member.data ?? Data()
                    if seen.insert(data).inserted { members.append(data) }
                }
            } while cursor != "0" && members.count < limit
            return .set(Array(members.prefix(limit)))
        case .zset:
            let reply = try await call(database, ["ZRANGE", key, "0", String(limit - 1), "WITHSCORES"])
            return .zset(Self.scoredMembers(reply))
        case .stream:
            let reply = try await call(database, ["XREVRANGE", key, "+", "-", "COUNT", String(limit)])
            return .stream(Self.streamEntries(reply))
        case .json:
            let reply = try await call(database, ["JSON.GET", key])
            return .json(reply.string ?? "null")
        case .other(let name):
            return .unsupported(name)
        }
    }

    /// ZRANGE WITHSCORES: flat member, score pairs (RESP2) or [member, score] arrays (RESP3).
    static func scoredMembers(_ reply: RESPValue) -> [RedisScoredMember] {
        let items = reply.elements ?? []
        if items.first?.elements != nil {
            return items.compactMap { pair in
                guard let p = pair.elements, p.count == 2 else { return nil }
                return RedisScoredMember(member: p[0].data ?? Data(), score: p[1].double ?? 0)
            }
        }
        return (reply.pairs ?? []).map { RedisScoredMember(member: $0.0.data ?? Data(), score: $0.1.double ?? 0) }
    }

    static func streamEntries(_ reply: RESPValue) -> [RedisStreamEntry] {
        (reply.elements ?? []).compactMap { entry in
            guard let parts = entry.elements, parts.count == 2, let id = parts[0].string else { return nil }
            let fields = (parts[1].pairs ?? []).map { RedisPair(field: $0.0.data ?? Data(), value: $0.1.data ?? Data()) }
            return RedisStreamEntry(id: id, fields: fields)
        }
    }

    // MARK: - Key operations

    public func rename(database: Int, key: String, to newKey: String) async throws {
        try checkWritable()
        guard key != newKey else { return }
        let reply = try await call(database, ["RENAMENX", key, newKey])
        if reply.int == 0 { throw RedisError.keyExists(newKey) }
    }

    public func setTTL(database: Int, key: String, seconds: Int64?) async throws {
        try checkWritable()
        if let seconds, seconds > 0 {
            _ = try await call(database, ["EXPIRE", key, String(seconds)])
        } else {
            _ = try await call(database, ["PERSIST", key])
        }
    }

    public func delete(database: Int, keys: [String]) async throws {
        try checkWritable()
        guard !keys.isEmpty else { return }
        let reply = try await pipeline(database: database, [[Data("UNLINK".utf8)] + keys.map { Data($0.utf8) }])[0]
        if case .error = reply {
            _ = try await call(database, [Data("DEL".utf8)] + keys.map { Data($0.utf8) })
        }
    }

    public func exists(database: Int, key: String) async throws -> Bool {
        try await call(database, ["EXISTS", key]).int == 1
    }

    /// Whether RedisJSON (or Redis 8's built-in JSON) answers JSON.* commands.
    public func supportsJSON() async -> Bool {
        if let hasJSONModule { return hasJSONModule }
        let reply = try? await pipeline(database: nil, [["JSON.DEBUG", "HELP"].map { Data($0.utf8) }]).first
        let supported = reply.map { !(($0.string ?? "").lowercased().contains("unknown command")) } ?? false
        hasJSONModule = supported
        return supported
    }

    /// Replaces a string, keeping the key's TTL.
    public func setString(database: Int, key: String, value: Data) async throws {
        try checkWritable()
        let k = Data(key.utf8)
        let ttl = try await call(database, ["PTTL", key]).int ?? -1
        var commands: [[Data]] = [[Data("SET".utf8), k, value]]
        if ttl > 0 { commands.append([Data("PEXPIRE".utf8), k, Data(String(ttl).utf8)]) }
        try await transaction(database, commands)
    }

    public func setJSON(database: Int, key: String, json: String, path: String = "$") async throws {
        try checkWritable()
        _ = try await call(database, ["JSON.SET", key, path, json])
    }

    /// HSET; with `replacing`, the old field is removed in the same transaction (renaming a field).
    public func hashSet(database: Int, key: String, field: Data, value: Data, replacing oldField: Data? = nil) async throws {
        try checkWritable()
        let k = Data(key.utf8)
        var commands: [[Data]] = []
        if let oldField, oldField != field { commands.append([Data("HDEL".utf8), k, oldField]) }
        commands.append([Data("HSET".utf8), k, field, value])
        try await transaction(database, commands)
    }

    public func hashDelete(database: Int, key: String, fields: [Data]) async throws {
        try checkWritable()
        _ = try await call(database, [Data("HDEL".utf8), Data(key.utf8)] + fields)
    }

    public func listSet(database: Int, key: String, index: Int, value: Data) async throws {
        try checkWritable()
        _ = try await call(database, [Data("LSET".utf8), Data(key.utf8), Data(String(index).utf8), value])
    }

    public func listPush(database: Int, key: String, values: [Data], atHead: Bool = false) async throws {
        try checkWritable()
        _ = try await call(database, [Data((atHead ? "LPUSH" : "RPUSH").utf8), Data(key.utf8)] + values)
    }

    /// Removes the element at `index`: marks it with a unique placeholder, then LREM removes that placeholder.
    public func listRemove(database: Int, key: String, index: Int) async throws {
        try checkWritable()
        let k = Data(key.utf8)
        let marker = Data("__bunnygrid_deleted_\(UUID().uuidString)__".utf8)
        try await transaction(database, [
            [Data("LSET".utf8), k, Data(String(index).utf8), marker],
            [Data("LREM".utf8), k, Data("1".utf8), marker],
        ])
    }

    public func setAdd(database: Int, key: String, members: [Data], replacing old: Data? = nil) async throws {
        try checkWritable()
        let k = Data(key.utf8)
        var commands: [[Data]] = []
        if let old, !members.contains(old) { commands.append([Data("SREM".utf8), k, old]) }
        commands.append([Data("SADD".utf8), k] + members)
        try await transaction(database, commands)
    }

    public func setRemove(database: Int, key: String, members: [Data]) async throws {
        try checkWritable()
        _ = try await call(database, [Data("SREM".utf8), Data(key.utf8)] + members)
    }

    public func zsetAdd(database: Int, key: String, member: Data, score: Double, replacing old: Data? = nil) async throws {
        try checkWritable()
        let k = Data(key.utf8)
        var commands: [[Data]] = []
        if let old, old != member { commands.append([Data("ZREM".utf8), k, old]) }
        commands.append([Data("ZADD".utf8), k, Data(RESPValue.format(score).utf8), member])
        try await transaction(database, commands)
    }

    public func zsetRemove(database: Int, key: String, members: [Data]) async throws {
        try checkWritable()
        _ = try await call(database, [Data("ZREM".utf8), Data(key.utf8)] + members)
    }

    /// XADD with `id` ("*" for a generated one); returns the entry id.
    @discardableResult
    public func streamAdd(database: Int, key: String, id: String = "*", fields: [RedisPair]) async throws -> String {
        try checkWritable()
        var args: [Data] = [Data("XADD".utf8), Data(key.utf8), Data((id.isEmpty ? "*" : id).utf8)]
        for pair in fields { args += [pair.field, pair.value] }
        return try await call(database, args).string ?? ""
    }

    public func streamDelete(database: Int, key: String, ids: [String]) async throws {
        try checkWritable()
        _ = try await call(database, ["XDEL", key] + ids)
    }

    /// New Key: creates `key` of `type` with a first value, failing when it exists. `ttl` > 0 sets an expiry.
    public func createKey(database: Int, key: String, type: RedisKeyType, field: Data, value: Data, score: Double = 0, ttl: Int64? = nil) async throws {
        try checkWritable()
        if try await exists(database: database, key: key) { throw RedisError.keyExists(key) }
        let k = Data(key.utf8)
        var command: [Data]
        switch type {
        case .string: command = [Data("SET".utf8), k, value]
        case .hash: command = [Data("HSET".utf8), k, field, value]
        case .list: command = [Data("RPUSH".utf8), k, value]
        case .set: command = [Data("SADD".utf8), k, value]
        case .zset: command = [Data("ZADD".utf8), k, Data(RESPValue.format(score).utf8), value]
        case .stream: command = [Data("XADD".utf8), k, Data("*".utf8), field, value]
        case .json: command = [Data("JSON.SET".utf8), k, Data("$".utf8), value.isEmpty ? Data("{}".utf8) : value]
        case .other(let name): throw DatabaseError.unsupported("Creating \(name) keys")
        }
        var commands = [command]
        if let ttl, ttl > 0 { commands.append([Data("EXPIRE".utf8), k, Data(String(ttl).utf8)]) }
        try await transaction(database, commands)
    }

    // MARK: - Console and server

    /// Commands that switch the connection into a push mode the console can't follow.
    static let streamingCommands: Set<String> = ["SUBSCRIBE", "PSUBSCRIBE", "SSUBSCRIBE", "MONITOR", "SYNC", "PSYNC"]

    /// Runs a console line on `database`. SELECT changes the console's database (returned), as in redis-cli.
    public func runCommandLine(_ line: String, database: Int) async throws -> (reply: RESPValue, database: Int) {
        let arguments = try RedisCommandLine.parse(line)
        guard let first = arguments.first else { return (.simpleString(""), database) }
        let name = String(decoding: first, as: UTF8.self).uppercased()
        if Self.streamingCommands.contains(name) { throw RedisError.unsupportedInConsole(name) }
        if config.readOnly && !Self.isReadOnlyCommand(name) { throw DatabaseError.readOnly }
        let reply = try await command(database: database, arguments)
        if name == "SELECT", !reply.isError, arguments.count > 1, let db = Int(String(decoding: arguments[1], as: UTF8.self)) {
            selected = db
            return (reply, db)
        }
        return (reply, database)
    }

    static let readOnlyCommands: Set<String> = [
        "GET", "MGET", "STRLEN", "GETRANGE", "EXISTS", "TYPE", "TTL", "PTTL", "SCAN", "KEYS", "HGET", "HMGET", "HGETALL", "HKEYS",
        "HVALS", "HLEN", "HSCAN", "HEXISTS", "LRANGE", "LLEN", "LINDEX", "SMEMBERS", "SCARD", "SISMEMBER", "SSCAN", "ZRANGE",
        "ZRANGEBYSCORE", "ZREVRANGE", "ZCARD", "ZSCORE", "ZRANK", "ZSCAN", "ZCOUNT", "XRANGE", "XREVRANGE", "XLEN", "XINFO",
        "INFO", "PING", "ECHO", "DBSIZE", "TIME", "SELECT", "MEMORY", "OBJECT", "CLIENT", "SLOWLOG", "COMMAND", "JSON.GET",
        "JSON.TYPE", "JSON.OBJKEYS", "JSON.ARRLEN", "RANDOMKEY", "LASTSAVE", "ROLE", "HELLO", "AUTH", "DUMP",
    ]

    static func isReadOnlyCommand(_ name: String) -> Bool { readOnlyCommands.contains(name.uppercased()) }

    public func info(section: String? = nil) async throws -> String {
        try await call(nil, ["INFO"] + (section.map { [$0] } ?? [])).string ?? ""
    }

    public func clientList() async throws -> [[String: String]] {
        RedisInfo.clients(try await call(nil, ["CLIENT", "LIST"]).string ?? "")
    }

    public func slowlog(count: Int = 50) async throws -> [RedisInfo.SlowlogEntry] {
        RedisInfo.slowlog(try await call(nil, ["SLOWLOG", "GET", String(count)]))
    }

    // MARK: - DatabaseDriver

    public func serverVersion() async throws -> String {
        let info = RedisInfo.parse(try await info(section: "server"))
        let version = info.first?.entries.first { $0.key == "redis_version" }?.value ?? ""
        return "Redis \(version)".trimmingCharacters(in: .whitespaces)
    }

    public func listDatabases() async throws -> [String] {
        (0..<(try await databaseCount())).map { "db\($0)" }
    }

    public func listSchemas() async throws -> [String] { [] }
    public func listObjects(schema: String?) async throws -> [DatabaseObject] { [] }
    public func listColumns(table: String, schema: String?) async throws -> [TableColumn] { [] }
    public func listIndexes(table: String, schema: String?) async throws -> [TableIndex] { [] }

    /// A command line on the default database, its reply as rows of one "reply" column.
    public func executeStatement(_ sql: String) async throws -> QueryResult {
        let line = sql.trimmingCharacters(in: CharacterSet(charactersIn: "; \n\t"))
        let (reply, _) = try await runCommandLine(line, database: defaultDatabase)
        if case .error(let message) = reply { throw DatabaseError.queryFailed(message) }
        let rows: [[CellValue]] = (reply.elements ?? [reply]).map { [.text(RedisCommandLine.render($0))] }
        return QueryResult(statement: sql, columns: ["reply"], rows: rows)
    }

    public func executeStatement(_ sql: String, parameters: [SQLParameter]) async throws -> QueryResult {
        guard parameters.isEmpty else { throw DatabaseError.unsupported("Bound parameters") }
        return try await executeStatement(sql)
    }
}
