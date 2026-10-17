import Foundation
import Testing
@testable import BunnyGridCore

@Suite("Mongo SASLprep and JavaScript preprocessing")
struct MongoSASLPrepTests {
    @Test func rfc4013Examples() throws {
        #expect(try MongoSCRAM.saslPrep("I\u{AD}X") == "IX")
        #expect(try MongoSCRAM.saslPrep("user") == "user")
        #expect(try MongoSCRAM.saslPrep("USER") == "USER")
        #expect(try MongoSCRAM.saslPrep("\u{AA}") == "a")
        #expect(try MongoSCRAM.saslPrep("\u{2168}") == "IX")
        #expect(try MongoSCRAM.saslPrep("a\u{A0}b") == "a b")
        #expect(throws: (any Error).self) { try MongoSCRAM.saslPrep("\u{07}") }
        #expect(throws: (any Error).self) { try MongoSCRAM.saslPrep("\u{0627}\u{31}") }
        #expect(try MongoSCRAM.saslPrep("\u{0627}\u{31}\u{0628}") == "\u{0627}\u{31}\u{0628}")
    }

    @Test func preprocessUseAndShow() {
        #expect(MongoJavaScriptShell.preprocess("use test;\n  show collections\nlet use = 1") == "use(\"test\");\nshow(\"collections\");\nlet use = 1")
    }

    @Test func pureJavaScriptNeedsNoServer() async throws {
        let driver = MongoDriver(config: ConnectionConfig(kind: .mongodb, host: "127.0.0.1", port: 1), secrets: ConnectionSecrets())
        let shell = MongoJavaScriptShell(driver: driver, database: "test", timeLimit: .milliseconds(300))
        let result = try await shell.run("""
        function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2) }
        let out = [];
        for (let i = 0; i < 10; i++) out.push(fib(i));
        print("sum", out.reduce((a, b) => a + b, 0));
        ({ last: out[9], id: ObjectId("0123456789abcdef01234567"), n: NumberLong(5), d: NumberDecimal("1.5"), u: UUID("0123456789abcdef0123456789abcdef") })
        """, maxDocuments: 10)
        #expect(result.printed == ["sum 88"])
        guard case .value(.document(let doc))? = result.outputs.last?.content else { Issue.record("no value"); return }
        #expect(doc["last"] == .int32(34))
        #expect(doc["id"] == .objectId(ObjectId("0123456789abcdef01234567")!))
        #expect(doc["n"] == .int64(5))
        #expect(doc["d"] == .decimal128(BSONDecimal128("1.5")!))
        #expect(doc["u"] == .binary(BSONBinary(uuid: UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!)))

        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: (any Error).self) { _ = try await shell.run("while (true) {}", maxDocuments: 10) }
        #expect(clock.now - start < .seconds(5))
        await #expect(throws: (any Error).self) { _ = try await shell.run("let x = ;", maxDocuments: 10) }
        let task = Task { try await shell.run("for (;;) {}", maxDocuments: 10) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
    }
}
