import Foundation
import Testing
@testable import BunnyGridCore

/// Runs against a real server when `BUNNYGRID_REDIS_PORT` is set (with `BUNNYGRID_REDIS_PASSWORD` when it needs one).
/// Optional: `BUNNYGRID_REDIS_TLS_PORT` + `BUNNYGRID_REDIS_TLS_CA` (and `_TLS_CERT` / `_TLS_KEY` for a client certificate),
/// `BUNNYGRID_REDIS_SOCKET` for a Unix socket. Uses db 9 and keys under "bunnygrid-test:".
private let redisTestPort = ProcessInfo.processInfo.environment["BUNNYGRID_REDIS_PORT"].flatMap(Int.init)

@Suite("Redis integration", .serialized, .enabled(if: redisTestPort != nil))
struct RedisIntegrationTests {
    static let env = ProcessInfo.processInfo.environment
    static let port = redisTestPort
    static let password = env["BUNNYGRID_REDIS_PASSWORD"]
    let db = 9

    static func config(port: Int? = RedisIntegrationTests.port, tls: TLSMode = .disable) -> ConnectionConfig {
        var config = ConnectionConfig(kind: .redis, host: "127.0.0.1", port: port, database: "9", tls: tls)
        config.name = "test"
        return config
    }

    func connected(_ config: ConnectionConfig = config(), password: String? = RedisIntegrationTests.password) async throws -> RedisDriver {
        let driver = RedisDriver(config: config, secrets: ConnectionSecrets(password: password))
        try await driver.connect()
        return driver
    }

    func clean(_ driver: RedisDriver) async throws {
        var cursor = "0"
        repeat {
            let page = try await driver.scan(database: db, cursor: cursor, pattern: "bunnygrid-test:*", type: nil, count: 500)
            try await driver.delete(database: db, keys: page.keys)
            cursor = page.cursor
        } while cursor != "0"
    }

    @Test func connectsAndReportsServer() async throws {
        let driver = try await connected()
        defer { Task { await driver.disconnect() } }
        #expect(try await driver.serverVersion().hasPrefix("Redis "))
        #expect(try await driver.listDatabases().count >= 1)
        #expect(await driver.protocolVersion == 3)
        let info = RedisInfo.parse(try await driver.info())
        #expect(info.contains { $0.name == "Memory" })
        #expect(try await driver.clientList().isEmpty == false)
        _ = try await driver.slowlog()
    }

    @Test func wrongPasswordFails() async throws {
        guard Self.password != nil else { return }
        let driver = RedisDriver(config: Self.config(), secrets: ConnectionSecrets(password: "wrong"))
        await #expect(throws: DatabaseError.self) { try await driver.connect() }
        let noPassword = RedisDriver(config: Self.config(), secrets: ConnectionSecrets())
        await #expect(throws: DatabaseError.self) { try await noPassword.connect() }
    }

    @Test func aclUserLogsIn() async throws {
        let admin = try await connected()
        defer { Task { await admin.disconnect() } }
        _ = try await admin.command(database: 0, ["ACL", "SETUSER", "bunnygrid-test", "on", ">pw123", "~*", "+@all"].map { Data($0.utf8) })
        var config = Self.config()
        config.username = "bunnygrid-test"
        let user = try await connected(config, password: "pw123")
        #expect(try await user.command(database: db, [Data("ACL".utf8), Data("WHOAMI".utf8)]).string == "bunnygrid-test")
        await user.disconnect()
        _ = try await admin.command(database: 0, ["ACL", "DELUSER", "bunnygrid-test"].map { Data($0.utf8) })
    }

    @Test func scansWithPatternAndType() async throws {
        let driver = try await connected()
        defer { Task { await driver.disconnect() } }
        try await clean(driver)
        for n in 0..<250 { _ = try await driver.command(database: db, ["SET", "bunnygrid-test:s:\(n)", "v"].map { Data($0.utf8) }) }
        try await driver.createKey(database: db, key: "bunnygrid-test:h", type: .hash, field: Data("f".utf8), value: Data("v".utf8))
        var keys = Set<String>(), cursor = "0", pages = 0
        repeat {
            let page = try await driver.scan(database: db, cursor: cursor, pattern: "bunnygrid-test:s:*", type: nil, count: 50)
            keys.formUnion(page.keys)
            cursor = page.cursor
            pages += 1
        } while cursor != "0"
        #expect(keys.count == 250)
        #expect(pages > 1)
        var hashes: [String] = []
        cursor = "0"
        repeat {
            let page = try await driver.scan(database: db, cursor: cursor, pattern: "bunnygrid-test:*", type: .hash, count: 1000)
            hashes += page.keys
            cursor = page.cursor
        } while cursor != "0"
        #expect(hashes == ["bunnygrid-test:h"])
        let types = try await driver.keyTypes(database: db, keys: ["bunnygrid-test:h", "bunnygrid-test:s:1", "bunnygrid-test:none"])
        #expect(types == ["bunnygrid-test:h": .hash, "bunnygrid-test:s:1": .string])
        #expect(try await driver.keyspace()[db]?.keys ?? 0 >= 251)
        try await clean(driver)
    }

    @Test func readsAndWritesEveryType() async throws {
        let driver = try await connected()
        defer { Task { await driver.disconnect() } }
        try await clean(driver)
        let k = "bunnygrid-test:"

        try await driver.createKey(database: db, key: k + "str", type: .string, field: Data(), value: Data([0, 1, 2, 255]), ttl: 100)
        try await driver.setString(database: db, key: k + "str", value: Data("hello".utf8))
        #expect(try await driver.readValue(database: db, key: k + "str", type: .string, limit: 10) == .string(Data("hello".utf8)))
        let info = try await driver.keyInfo(database: db, key: k + "str")
        #expect(info.type == .string && info.length == 5)
        #expect(info.ttl > 90, "setString keeps the TTL")
        #expect(info.memoryBytes != nil)
        await #expect(throws: RedisError.keyExists(k + "str")) {
            try await driver.createKey(database: db, key: k + "str", type: .string, field: Data(), value: Data())
        }

        try await driver.createKey(database: db, key: k + "hash", type: .hash, field: Data("a".utf8), value: Data("1".utf8))
        try await driver.hashSet(database: db, key: k + "hash", field: Data("b".utf8), value: Data("2".utf8))
        try await driver.hashSet(database: db, key: k + "hash", field: Data("c".utf8), value: Data("3".utf8), replacing: Data("a".utf8))
        try await driver.hashDelete(database: db, key: k + "hash", fields: [Data("b".utf8)])
        #expect(try await driver.readValue(database: db, key: k + "hash", type: .hash, limit: 100) == .hash([RedisPair("c", "3")]))

        try await driver.createKey(database: db, key: k + "list", type: .list, field: Data(), value: Data("x".utf8))
        try await driver.listPush(database: db, key: k + "list", values: [Data("y".utf8), Data("x".utf8)])
        try await driver.listPush(database: db, key: k + "list", values: [Data("head".utf8)], atHead: true)
        try await driver.listSet(database: db, key: k + "list", index: 1, value: Data("X".utf8))
        try await driver.listRemove(database: db, key: k + "list", index: 3)
        #expect(try await driver.readValue(database: db, key: k + "list", type: .list, limit: 100) == .list(["head", "X", "y"].map { Data($0.utf8) }))
        #expect(try await driver.readValue(database: db, key: k + "list", type: .list, limit: 2).count == 2)

        try await driver.createKey(database: db, key: k + "set", type: .set, field: Data(), value: Data("m1".utf8))
        try await driver.setAdd(database: db, key: k + "set", members: [Data("m2".utf8)])
        try await driver.setAdd(database: db, key: k + "set", members: [Data("m3".utf8)], replacing: Data("m1".utf8))
        try await driver.setRemove(database: db, key: k + "set", members: [Data("m2".utf8)])
        #expect(try await driver.readValue(database: db, key: k + "set", type: .set, limit: 100) == .set([Data("m3".utf8)]))

        try await driver.createKey(database: db, key: k + "zset", type: .zset, field: Data(), value: Data("a".utf8), score: 2)
        try await driver.zsetAdd(database: db, key: k + "zset", member: Data("b".utf8), score: 1.5)
        try await driver.zsetAdd(database: db, key: k + "zset", member: Data("a".utf8), score: 0.25)
        try await driver.zsetAdd(database: db, key: k + "zset", member: Data("c".utf8), score: 9, replacing: Data("b".utf8))
        #expect(try await driver.readValue(database: db, key: k + "zset", type: .zset, limit: 100)
                == .zset([RedisScoredMember(member: Data("a".utf8), score: 0.25), RedisScoredMember(member: Data("c".utf8), score: 9)]))

        try await driver.createKey(database: db, key: k + "stream", type: .stream, field: Data("f".utf8), value: Data("1".utf8))
        let id = try await driver.streamAdd(database: db, key: k + "stream", fields: [RedisPair("g", "2"), RedisPair("h", "3")])
        guard case .stream(let entries) = try await driver.readValue(database: db, key: k + "stream", type: .stream, limit: 10) else {
            Issue.record("not a stream"); return
        }
        #expect(entries.count == 2)
        #expect(entries.first?.id == id, "newest first")
        #expect(entries.first?.fields == [RedisPair("g", "2"), RedisPair("h", "3")])
        try await driver.streamDelete(database: db, key: k + "stream", ids: [id])
        #expect(try await driver.keyInfo(database: db, key: k + "stream").length == 1)

        if await driver.supportsJSON() {
            try await driver.createKey(database: db, key: k + "json", type: .json, field: Data(), value: Data(#"{"a":1}"#.utf8))
            try await driver.setJSON(database: db, key: k + "json", json: "[1,2]", path: "$.a")
            #expect(try await driver.keyInfo(database: db, key: k + "json").type == .json)
            guard case .json(let text) = try await driver.readValue(database: db, key: k + "json", type: .json, limit: 1) else {
                Issue.record("not JSON"); return
            }
            #expect(text.replacingOccurrences(of: " ", with: "") == #"{"a":[1,2]}"#)
        }

        try await driver.rename(database: db, key: k + "set", to: k + "set2")
        await #expect(throws: RedisError.keyExists(k + "hash")) { try await driver.rename(database: db, key: k + "set2", to: k + "hash") }
        try await driver.setTTL(database: db, key: k + "set2", seconds: 50)
        #expect(try await driver.keyInfo(database: db, key: k + "set2").ttl > 0)
        try await driver.setTTL(database: db, key: k + "set2", seconds: nil)
        #expect(try await driver.keyInfo(database: db, key: k + "set2").ttl == -1)
        try await driver.delete(database: db, keys: [k + "set2"])
        #expect(try await driver.keyInfo(database: db, key: k + "set2").exists == false)
        try await clean(driver)
    }

    @Test func consoleCommandsAndDatabaseSwitching() async throws {
        let driver = try await connected()
        defer { Task { await driver.disconnect() } }
        let (pong, _) = try await driver.runCommandLine("PING", database: db)
        #expect(pong == .simpleString("PONG"))
        _ = try await driver.runCommandLine(#"SET "bunnygrid-test:quoted key" 'a b'"#, database: db)
        #expect(try await driver.runCommandLine(#"GET "bunnygrid-test:quoted key""#, database: db).reply.string == "a b")
        let (_, newDB) = try await driver.runCommandLine("SELECT 3", database: db)
        #expect(newDB == 3)
        // Keyed calls still go to their own database after the console switched.
        #expect(try await driver.runCommandLine(#"EXISTS "bunnygrid-test:quoted key""#, database: db).reply.int == 1)
        #expect(try await driver.runCommandLine(#"EXISTS "bunnygrid-test:quoted key""#, database: 3).reply.int == 0)
        let (error, _) = try await driver.runCommandLine("NOSUCHCOMMAND", database: db)
        #expect(error.isError)
        await #expect(throws: RedisError.self) { try await driver.runCommandLine("MONITOR", database: db) }
        let result = try await driver.executeStatement("PING")
        #expect(result.rows.first?.first == .text("PONG"))
        try await clean(driver)
    }

    @Test func concurrentCallsKeepTheirDatabase() async throws {
        let driver = try await connected()
        defer { Task { await driver.disconnect() } }
        _ = try await driver.command(database: 9, ["SET", "bunnygrid-test:where", "nine"].map { Data($0.utf8) })
        _ = try await driver.command(database: 8, ["SET", "bunnygrid-test:where", "eight"].map { Data($0.utf8) })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 0..<40 {
                group.addTask {
                    let db = n.isMultiple(of: 2) ? 9 : 8
                    let value = try await driver.command(database: db, ["GET", "bunnygrid-test:where"].map { Data($0.utf8) }).string
                    #expect(value == (db == 9 ? "nine" : "eight"))
                }
            }
            try await group.waitForAll()
        }
        try await driver.delete(database: 8, keys: ["bunnygrid-test:where"])
        try await clean(driver)
    }

    @Test func readOnlyBlocksWrites() async throws {
        var config = Self.config()
        config.readOnly = true
        let driver = try await connected(config)
        defer { Task { await driver.disconnect() } }
        await #expect(throws: DatabaseError.self) { try await driver.runCommandLine("SET bunnygrid-test:x 1", database: db) }
        await #expect(throws: DatabaseError.self) { try await driver.delete(database: db, keys: ["bunnygrid-test:x"]) }
        #expect(try await driver.runCommandLine("GET bunnygrid-test:x", database: db).reply == .null)
    }

    @Test func connectsOverTLS() async throws {
        guard let tlsPort = Self.env["BUNNYGRID_REDIS_TLS_PORT"].flatMap(Int.init), let ca = Self.env["BUNNYGRID_REDIS_TLS_CA"] else { return }
        var config = Self.config(port: tlsPort, tls: .verifyFull)
        config.host = "localhost"
        config.ssl = SSLFiles(caCertificatePath: ca, clientCertificatePath: Self.env["BUNNYGRID_REDIS_TLS_CERT"] ?? "",
                              clientKeyPath: Self.env["BUNNYGRID_REDIS_TLS_KEY"] ?? "")
        let driver = try await connected(config)
        #expect(try await driver.runCommandLine("PING", database: 0).reply == .simpleString("PONG"))
        await driver.disconnect()

        // Without the CA the certificate can't be verified; Require skips the check.
        config.ssl = nil
        let unverified = RedisDriver(config: config, secrets: ConnectionSecrets(password: Self.password))
        await #expect(throws: (any Error).self) { try await unverified.connect() }
        config.tls = .require
        let required = try await connected(config)
        #expect(try await required.serverVersion().hasPrefix("Redis"))
        await required.disconnect()

        // Plain TCP to the TLS port fails instead of hanging.
        config.tls = .disable
        let plain = RedisDriver(config: config, secrets: ConnectionSecrets(password: Self.password))
        await #expect(throws: (any Error).self) { try await plain.connect() }
    }

    @Test func connectsOverUnixSocket() async throws {
        guard let socket = Self.env["BUNNYGRID_REDIS_SOCKET"] else { return }
        var config = Self.config()
        config.socketPath = socket
        let driver = try await connected(config)
        #expect(try await driver.runCommandLine("PING", database: 0).reply == .simpleString("PONG"))
        await driver.disconnect()
    }
}
