import Foundation
import Testing
@testable import BunnyGridCore

@Suite("RESP codec")
struct RESPCodecTests {
    @Test func encodesCommandsAsBulkArrays() {
        let bytes = RESPCodec.encode(command: ["SET", "key", "a b"])
        #expect(String(decoding: bytes, as: UTF8.self) == "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$3\r\na b\r\n")
        #expect(String(decoding: RESPCodec.encode(command: [""]), as: UTF8.self) == "*1\r\n$0\r\n\r\n")
    }

    @Test func decodesRESP2Types() throws {
        func decode(_ text: String) throws -> RESPValue? { try RESPCodec.decode(Array(text.utf8))?.value }
        #expect(try decode("+OK\r\n") == .simpleString("OK"))
        #expect(try decode("-ERR bad\r\n") == .error("ERR bad"))
        #expect(try decode(":-42\r\n") == .integer(-42))
        #expect(try decode("$5\r\nhe\r\no\r\n") == .bulk("he\r\no"))
        #expect(try decode("$-1\r\n") == .null)
        #expect(try decode("*-1\r\n") == .null)
        #expect(try decode("*2\r\n$1\r\na\r\n*1\r\n:1\r\n") == .array([.bulk("a"), .array([.integer(1)])]))
        #expect(try decode("*0\r\n") == .array([]))
    }

    @Test func decodesRESP3Types() throws {
        func decode(_ text: String) throws -> RESPValue? { try RESPCodec.decode(Array(text.utf8))?.value }
        #expect(try decode("_\r\n") == .null)
        #expect(try decode(",3.5\r\n") == .double(3.5))
        #expect(try decode(",inf\r\n") == .double(.infinity))
        #expect(try decode("#t\r\n") == .boolean(true))
        #expect(try decode("(3492890328409238509324850943850943825024385\r\n") == .bigNumber("3492890328409238509324850943850943825024385"))
        #expect(try decode("=15\r\ntxt:Some string\r\n") == .verbatim(format: "txt", text: "Some string"))
        #expect(try decode("!9\r\nERR inner\r\n") == .error("ERR inner"))
        #expect(try decode("%1\r\n+a\r\n:1\r\n") == .map([(.simpleString("a"), .integer(1))]))
        #expect(try decode("~2\r\n:1\r\n:2\r\n") == .set([.integer(1), .integer(2)]))
        #expect(try decode(">2\r\n+message\r\n+x\r\n") == .push([.simpleString("message"), .simpleString("x")]))
        // Attributes are skipped: the reply after them is returned.
        #expect(try decode("|1\r\n+ttl\r\n:3\r\n:7\r\n") == .integer(7))
    }

    @Test func roundTripsReplies() throws {
        let value: RESPValue = .array([.bulk("x"), .map([(.bulk("k"), .double(1.25))]), .null, .boolean(false), .set([.integer(3)])])
        let bytes = RESPCodec.encode(reply: value)
        let decoded = try #require(try RESPCodec.decode(bytes))
        #expect(decoded.value == value)
        #expect(decoded.consumed == bytes.count)
    }

    @Test func waitsForPartialReplies() throws {
        #expect(try RESPCodec.decode(Array("$5\r\nhel".utf8)) == nil)
        #expect(try RESPCodec.decode(Array("*2\r\n:1\r\n".utf8)) == nil)
        #expect(try RESPCodec.decode(Array("+OK".utf8)) == nil)
        var stream = RESPStreamDecoder()
        let bytes = Array("+OK\r\n*2\r\n$3\r\nfoo\r\n:9\r\n".utf8)
        var values: [RESPValue] = []
        for byte in bytes {
            stream.append([byte])
            while let value = try stream.next() { values.append(value) }
        }
        #expect(values == [.simpleString("OK"), .array([.bulk("foo"), .integer(9)])])
        #expect(stream.bufferedByteCount == 0)
    }

    @Test func rejectsGarbage() {
        #expect(throws: RESPError.self) { try RESPCodec.decode(Array("?x\r\n".utf8)) }
        #expect(throws: RESPError.self) { try RESPCodec.decode(Array(":abc\r\n".utf8)) }
    }

    @Test func pairsReadMapsAndFlatArrays() {
        let flat: RESPValue = .array([.bulk("a"), .bulk("1"), .bulk("b"), .bulk("2")])
        #expect(flat.pairs?.map { $0.0.string! + "=" + $0.1.string! } == ["a=1", "b=2"])
        let map: RESPValue = .map([(.bulk("a"), .bulk("1"))])
        #expect(map.pairs?.count == 1)
        #expect(RESPValue.array([.bulk("odd")]).pairs == nil)
    }

    @Test func scoredMembersInBothProtocols() {
        let resp2: RESPValue = .array([.bulk("a"), .bulk("1.5"), .bulk("b"), .bulk("2")])
        let resp3: RESPValue = .array([.array([.bulk("a"), .double(1.5)]), .array([.bulk("b"), .double(2)])])
        let expected = [RedisScoredMember(member: Data("a".utf8), score: 1.5), RedisScoredMember(member: Data("b".utf8), score: 2)]
        #expect(RedisDriver.scoredMembers(resp2) == expected)
        #expect(RedisDriver.scoredMembers(resp3) == expected)
    }
}

@Suite("Redis command line")
struct RedisCommandLineTests {
    @Test func splitsOnWhitespace() throws {
        #expect(try RedisCommandLine.parseStrings("  SET  key   value ") == ["SET", "key", "value"])
        #expect(try RedisCommandLine.parseStrings("") == [])
    }

    @Test func handlesQuotes() throws {
        #expect(try RedisCommandLine.parseStrings(#"SET "a key" 'it\'s'"#) == ["SET", "a key", "it's"])
        #expect(try RedisCommandLine.parseStrings(#"SET k "line\nnext\t\"q\"""#) == ["SET", "k", "line\nnext\t\"q\""])
        #expect(try RedisCommandLine.parse(#"SET k "\x00\xff""#)[2] == Data([0, 255]))
        #expect(try RedisCommandLine.parseStrings(#"SET k """#) == ["SET", "k", ""])
        // Single quotes keep backslashes other than \'.
        #expect(try RedisCommandLine.parseStrings(#"ECHO 'a\nb'"#) == ["ECHO", #"a\nb"#])
        #expect(try RedisCommandLine.parseStrings(#"GET user:"1""#) == ["GET", "user:1"])
    }

    @Test func rejectsBadQuoting() {
        #expect(throws: RedisCommandLine.ParseError.unbalancedQuotes) { try RedisCommandLine.parse(#"SET "open"#) }
        #expect(throws: RedisCommandLine.ParseError.unbalancedQuotes) { try RedisCommandLine.parse("SET 'open") }
        #expect(throws: RedisCommandLine.ParseError.quoteNotFollowedBySpace) { try RedisCommandLine.parse(#"SET "a"b"#) }
    }

    @Test func quoteRoundTrips() throws {
        for sample in ["plain", "with space", "q\"uote", "back\\slash", "", "line\n", "it's"] {
            let quoted = RedisCommandLine.quote(Data(sample.utf8))
            #expect(try RedisCommandLine.parseStrings("ECHO " + quoted) == ["ECHO", sample])
        }
        let binary = Data([0, 1, 200])
        #expect(try RedisCommandLine.parse("ECHO " + RedisCommandLine.quote(binary))[1] == binary)
    }

    @Test func rendersLikeRedisCLI() {
        #expect(RedisCommandLine.render(.integer(3)) == "(integer) 3")
        #expect(RedisCommandLine.render(.null) == "(nil)")
        #expect(RedisCommandLine.render(.bulk("hi there")) == "\"hi there\"")
        #expect(RedisCommandLine.render(.array([])) == "(empty array)")
        #expect(RedisCommandLine.render(.array([.bulk("a"), .array([.integer(1), .bulk("b")])])) == "1) a\n2) 1) (integer) 1\n   2) b")
    }
}

@Suite("Redis key tree and INFO")
struct RedisKeyTreeTests {
    @Test func groupsKeysIntoFolders() {
        let keys = ["user:2", "user:10", "user:1", "session:abc:data", "plain", "user"].map { RedisKeyEntry(key: $0) }
        let tree = RedisKeyTree.build(keys, separator: ":")
        #expect(tree.map(\.name) == ["session", "user", "plain", "user"])
        guard case .folder(_, let path, let children, let count) = tree[1] else { Issue.record("expected folder"); return }
        #expect(path == "user:")
        #expect(count == 3)
        #expect(children.map(\.name) == ["1", "2", "10"])
        guard case .folder(_, _, let sessionChildren, let sessionCount) = tree[0],
              case .folder(_, let innerPath, let inner, _) = sessionChildren.first else { Issue.record("expected nested folder"); return }
        #expect(sessionCount == 1)
        #expect(innerPath == "session:abc:")
        #expect(inner.first?.id == "key:session:abc:data")
    }

    @Test func emptySeparatorIsFlat() {
        let tree = RedisKeyTree.build([RedisKeyEntry(key: "b:1"), RedisKeyEntry(key: "a")], separator: "")
        #expect(tree.map(\.name) == ["a", "b:1"])
    }

    @Test func multiCharacterSeparatorAndEmptySegments() {
        let tree = RedisKeyTree.build([RedisKeyEntry(key: "a::b"), RedisKeyEntry(key: "::x")], separator: "::")
        #expect(tree.map(\.id) == ["folder:::", "folder:a::"])
    }

    @Test func parsesInfoAndKeyspace() {
        let text = "# Server\r\nredis_version:8.10.2\r\nredis_mode:standalone\r\n\r\n# Keyspace\r\ndb0:keys=12,expires=1,avg_ttl=300\r\ndb3:keys=2,expires=0,avg_ttl=0\r\n"
        let sections = RedisInfo.parse(text)
        #expect(sections.map(\.name) == ["Server", "Keyspace"])
        #expect(sections[0].entries.first == RedisInfo.Entry(key: "redis_version", value: "8.10.2"))
        let keyspace = RedisInfo.keyspace(text)
        #expect(keyspace[0] == RedisKeyspace(keys: 12, expires: 1, averageTTL: 300))
        #expect(keyspace[3]?.keys == 2)
        #expect(keyspace[1] == nil)
    }

    @Test func parsesClientsAndSlowlog() {
        let clients = RedisInfo.clients("id=3 addr=127.0.0.1:5000 name= db=0 cmd=client|list\nid=4 addr=127.0.0.1:5001 db=2\n")
        #expect(clients.count == 2)
        #expect(clients[0]["cmd"] == "client|list")
        #expect(clients[1]["db"] == "2")
        let reply: RESPValue = .array([.array([.integer(7), .integer(1_700_000_000), .integer(1500), .array([.bulk("KEYS"), .bulk("*")]), .bulk("127.0.0.1:1"), .bulk("")])])
        let log = RedisInfo.slowlog(reply)
        #expect(log.first?.id == 7)
        #expect(log.first?.command == "KEYS *")
        #expect(log.first?.durationMicroseconds == 1500)
    }

    @Test func keyTypeNames() {
        #expect(RedisKeyType(typeName: "ReJSON-RL") == .json)
        #expect(RedisKeyType(typeName: "zset").displayName == "Sorted Set")
        #expect(RedisKeyType(typeName: "MBbloom--") == .other("MBbloom--"))
    }

    @Test func redisURIAndDefaultDatabase() throws {
        let parsed = try ConnectionURI.parse("rediss://alice:secret@cache.example.com:6380/3")
        #expect(parsed.config.kind == .redis)
        #expect(parsed.config.tls == .require)
        #expect(parsed.config.database == "3")
        #expect(parsed.config.username == "alice")
        #expect(parsed.password == "secret")
        #expect(try ConnectionURI.parse("redis://localhost").config.port == 6379)
        #expect(RedisDriver(config: parsed.config, secrets: ConnectionSecrets()).defaultDatabase == 3)
        #expect(ConnectionURI.string(for: parsed.config).hasPrefix("rediss://alice@cache.example.com:6380/3"))
    }
}
