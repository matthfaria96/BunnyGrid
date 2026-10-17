import Foundation
import Testing
@testable import BunnyGridCore

/// The JavaScript shell against a real mongod (`BUNNYGRID_MONGO_PORT`, no auth).
@Suite("MongoDB JavaScript shell integration", .enabled(if: ProcessInfo.processInfo.environment["BUNNYGRID_MONGO_PORT"] != nil), .serialized)
struct MongoJavaScriptIntegrationTests {
    static func driver(_ db: String) -> MongoDriver {
        let port = ProcessInfo.processInfo.environment["BUNNYGRID_MONGO_PORT"].flatMap(Int.init)
        return MongoDriver(config: ConnectionConfig(kind: .mongodb, host: "127.0.0.1", port: port, database: db, tls: .disable), secrets: ConnectionSecrets())
    }

    @Test func runsVariablesLoopsAndCursors() async throws {
        let db = "bunnygrid_js_\(UInt32.random(in: 0...UInt32.max))"
        let driver = Self.driver(db)
        try await driver.connect()
        defer { Task { _ = try? await driver.runCommand(["dropDatabase": .int32(1)], database: db); await driver.disconnect() } }
        let shell = MongoJavaScriptShell(driver: driver, database: db)
        let script = """
        const names = ["ana", "bia", "caio"];
        function make(i) { return { _id: i, name: names[i], born: ISODate("2000-01-0" + (i + 1) + "T00:00:00Z"), big: NumberLong("9007199254740993") } }
        for (let i = 0; i < names.length; i++) db.people.insertOne(make(i));
        db.people.updateOne({ _id: 1 }, { $set: { tag: new ObjectId("0123456789abcdef01234567") } });
        let total = 0;
        db.people.find().sort({ _id: -1 }).forEach(d => { total += d._id; print(d.name) });
        printjson({ total, count: db.people.countDocuments({}) });
        const one = db.people.findOne({ _id: 1 });
        if (!(one.born instanceof Date) || one.tag.toHexString() !== "0123456789abcdef01234567") throw new Error("types lost");
        if (db.people.aggregate([{ $group: { _id: null, n: { $sum: 1 } } }]).toArray()[0].n !== 3) throw new Error("aggregate");
        use other
        db.getSiblingDB("\(db)").people.find({ _id: { $gte: 1 } }).limit(5)
        """
        let result = try await shell.run(script, maxDocuments: 100)
        #expect(result.database == "other")
        #expect(Array(result.printed.prefix(3)) == ["caio", "bia", "ana"])
        #expect(result.printed.last?.contains("\"total\": 3") == true)
        guard case .documents(let docs, _)? = result.outputs.last?.content else { Issue.record("no documents"); return }
        #expect(docs.map { $0["_id"] } == [.int32(1), .int32(2)])
        #expect(docs.first?["big"] == .int64(9_007_199_254_740_993))
        #expect(docs.first?["born"] == .date(946_771_200_000))

        await #expect(throws: (any Error).self) { _ = try await shell.run("db.x.insertOne(5)", maxDocuments: 10) }
        let caught = try await shell.run("try { db.x.insertOne(5); 'no' } catch (e) { 'caught' }", maxDocuments: 10)
        if case .value(let v)? = caught.outputs.last?.content { #expect(v == .string("caught")) } else { Issue.record("no value") }
    }
}
