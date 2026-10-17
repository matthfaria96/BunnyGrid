import Foundation
import Testing
@testable import BunnyGridCore

@Suite("Redis Cluster routing")
struct RedisClusterTests {
    @Test func hashSlots() {
        #expect(RedisCluster.crc16(Array("123456789".utf8)) == 0x31C3)
        #expect(RedisCluster.slot("foo") == 12182)
        #expect(RedisCluster.slot("bar") == 5061)
        #expect(RedisCluster.slot("{user1000}.following") == RedisCluster.slot("{user1000}.followers"))
        #expect(RedisCluster.slot("{user1000}.following") == RedisCluster.slot("user1000"))
        #expect(RedisCluster.slot("foo{}{bar}") == RedisCluster.slot("foo{}{bar}"))
        #expect(RedisCluster.slot("foo{{bar}}zap") == RedisCluster.slot("{bar"))
    }

    @Test func redirectsAndCursors() {
        #expect(RedisCluster.redirect("MOVED 3999 127.0.0.1:6381") == .moved(slot: 3999, node: .init(host: "127.0.0.1", port: 6381)))
        #expect(RedisCluster.redirect("ASK 3999 [::1]:6381") == .ask(slot: 3999, node: .init(host: "::1", port: 6381)))
        #expect(RedisCluster.redirect("ERR wrong") == nil)
        #expect(RedisCluster.scanCursor("0") == (0, "0"))
        #expect(RedisCluster.scanCursor("2:1536") == (2, "1536"))
    }

    @Test func routingKeys() {
        func key(_ words: String...) -> String? { RedisCluster.routingKey(words.map { Data($0.utf8) }).map { String(decoding: $0, as: UTF8.self) } }
        #expect(key("GET", "a") == "a")
        #expect(key("INFO") == nil)
        #expect(key("EVAL", "return 1", "1", "k") == "k")
        #expect(key("EVAL", "return 1", "0") == nil)
        #expect(key("XREAD", "COUNT", "2", "STREAMS", "s1", "0") == "s1")
        #expect(key("OBJECT", "ENCODING", "k") == "k")
    }

    @Test func slotsReply() {
        let reply = RESPValue.array([
            .array([.integer(5461), .integer(10922), .array([.bulkString(Data("".utf8)), .integer(7102), .bulkString(Data("id".utf8))])]),
            .array([.integer(0), .integer(5460), .array([.bulkString(Data("10.0.0.1".utf8)), .integer(7101)])]),
        ])
        let ranges = RedisCluster.slotRanges(reply, defaultHost: "seed")
        #expect(ranges.map(\.lower) == [0, 5461])
        #expect(ranges[1].master == .init(host: "seed", port: 7102))
        #expect(RedisSentinel.masterAddress(.array([.bulkString(Data("10.0.0.5".utf8)), .bulkString(Data("6380".utf8))])) == .init(host: "10.0.0.5", port: 6380))
    }
}

/// Against throwaway servers: `BUNNYGRID_REDIS_CLUSTER_PORT` (any node of a 3-master cluster) and
/// `BUNNYGRID_REDIS_SENTINEL_PORT` (a sentinel monitoring `mymaster`).
@Suite("Redis Cluster and Sentinel integration", .serialized)
struct RedisClusterIntegrationTests {
    static let clusterPort = ProcessInfo.processInfo.environment["BUNNYGRID_REDIS_CLUSTER_PORT"].flatMap(Int.init)
    static let sentinelPort = ProcessInfo.processInfo.environment["BUNNYGRID_REDIS_SENTINEL_PORT"].flatMap(Int.init)

    @Test(.enabled(if: clusterPort != nil)) func clusterRoutesScansAndRedirects() async throws {
        let driver = RedisDriver(config: ConnectionConfig(kind: .redis, host: "127.0.0.1", port: Self.clusterPort), secrets: ConnectionSecrets())
        try await driver.connect()
        #expect(await driver.isCluster)
        #expect(await driver.clusterMasters.count == 3)
        let keys = (0..<60).map { "bunnygrid-cluster:\($0)" }
        for key in keys { try await driver.setString(database: 0, key: key, value: Data(key.utf8)) }
        for key in keys.prefix(10) {
            let (reply, _) = try await driver.runCommandLine("GET \(key)", database: 0)
            #expect(reply.string == key)
        }
        var cursor = "0", found = Set<String>()
        repeat {
            let page = try await driver.scan(database: 0, cursor: cursor, pattern: "bunnygrid-cluster:*", type: nil, count: 100)
            found.formUnion(page.keys)
            cursor = page.cursor
        } while cursor != "0"
        #expect(found == Set(keys))
        let total = try await driver.keyspace()[0]?.keys ?? 0
        #expect(total >= keys.count)
        // Streaming: SUBSCRIBE on its own connection, PUBLISH from the routed one.
        let stream = try driver.stream("SUBSCRIBE bunnygrid-news", database: 0)
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        _ = try await driver.runCommandLine("PUBLISH bunnygrid-news hello", database: 0)
        let message = try await iterator.next()
        #expect(message.map { RedisCommandLine.render($0) }?.contains("hello") == true)
        try await driver.delete(database: 0, keys: keys)
        await driver.disconnect()
    }

    @Test(.enabled(if: sentinelPort != nil)) func sentinelFindsTheMaster() async throws {
        var config = ConnectionConfig(kind: .redis, host: "127.0.0.1", port: Self.sentinelPort)
        config.redis = RedisOptions(sentinelMaster: "mymaster")
        let driver = RedisDriver(config: config, secrets: ConnectionSecrets())
        try await driver.connect()
        #expect(await driver.sentinelMasterNode != nil)
        let role = try await driver.runCommandLine("ROLE", database: 0).reply
        #expect(RedisCommandLine.render(role).contains("master"))
        await driver.disconnect()

        config.redis = RedisOptions(sentinelMaster: "nobody")
        await #expect(throws: (any Error).self) { try await RedisDriver(config: config, secrets: ConnectionSecrets()).connect() }
    }
}
