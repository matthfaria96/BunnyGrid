import Foundation
import Testing
@testable import BunnyGridCore

/// Runs against a real mongod when `BUNNYGRID_MONGO_PORT` is set (host `BUNNYGRID_MONGO_HOST`, default 127.0.0.1).
/// With `BUNNYGRID_MONGO_USER` / `BUNNYGRID_MONGO_PASSWORD` (a user in `admin`), connections authenticate with SCRAM,
/// and a wrong-password case runs. Each test uses its own database and drops it.
private enum MongoEnv {
    static let port = ProcessInfo.processInfo.environment["BUNNYGRID_MONGO_PORT"].flatMap(Int.init)
    static let host = ProcessInfo.processInfo.environment["BUNNYGRID_MONGO_HOST"] ?? "127.0.0.1"
    static let user = ProcessInfo.processInfo.environment["BUNNYGRID_MONGO_USER"] ?? ""
    static let password = ProcessInfo.processInfo.environment["BUNNYGRID_MONGO_PASSWORD"]
    static var enabled: Bool { port != nil }

    static func driver(database: String, password: String? = MongoEnv.password) -> MongoDriver {
        var config = ConnectionConfig(kind: .mongodb, host: host, port: port, username: user, database: database, tls: .disable)
        config.mongo = MongoOptions(authSource: user.isEmpty ? "" : "admin")
        return MongoDriver(config: config, secrets: ConnectionSecrets(password: password))
    }

    static func withDatabase(_ body: (MongoDriver, String) async throws -> Void) async throws {
        let name = "bunnygrid_test_\(UInt32.random(in: 0...UInt32.max))"
        let driver = driver(database: name)
        try await driver.connect()
        do {
            try await body(driver, name)
        } catch {
            _ = try? await driver.runCommand(["dropDatabase": .int32(1)], database: name)
            await driver.disconnect()
            throw error
        }
        _ = try? await driver.runCommand(["dropDatabase": .int32(1)], database: name)
        await driver.disconnect()
    }
}

@Suite("MongoDB integration", .enabled(if: MongoEnv.enabled), .serialized)
struct MongoIntegrationTests {
    @Test func connectsAndLists() async throws {
        try await MongoEnv.withDatabase { driver, db in
            #expect(try await driver.serverVersion().hasPrefix("MongoDB "))
            try await driver.insert([["a": .int32(1)]], database: db, collection: "people")
            _ = try await driver.runCommand(["create": .string("people_view"), "viewOn": .string("people"), "pipeline": .array([])], database: db)
            #expect(try await driver.listDatabases().contains(db))
            let objects = try await driver.listObjects(schema: db)
            #expect(objects.contains(DatabaseObject(schema: nil, name: "people", kind: .table)))
            #expect(objects.contains(DatabaseObject(schema: nil, name: "people_view", kind: .view)))
            #expect(objects.contains(DatabaseObject(schema: DocumentCatalog.indexSchemaPrefix + "people", name: "_id_", kind: .table)))
        }
    }

    @Test func crudAndPaging() async throws {
        try await MongoEnv.withDatabase { driver, db in
            let docs: [BSONDocument] = (1...25).map { ["n": .int32(Int32($0)), "even": .bool($0 % 2 == 0), "tags": .array([.string("t\($0)")])] }
            let ids = try await driver.insert(docs, database: db, collection: "c")
            #expect(ids.count == 25)
            #expect(try await driver.count(filter: ["even": .bool(true)], database: db, collection: "c") == 12)
            // Paging over several getMore batches.
            let page = try await driver.findCapped(DocumentQuery(filter: [:], sort: ["n": .int32(-1)], skip: 5, limit: 7), database: db, collection: "c")
            #expect(page.documents.map { $0["n"] } == (14...20).reversed().map { .int32(Int32($0)) })
            let small = try await driver.findCapped(DocumentQuery(projection: ["n": .int32(1), "_id": .int32(0)]), database: db, collection: "c")
            #expect(small.documents.count == 25)
            #expect(small.documents[0].keys == ["n"])
            let update = try await driver.update(filter: ["even": .bool(false)], update: .document(["$set": .document(["odd": .bool(true)])]),
                                                 many: true, upsert: false, database: db, collection: "c")
            #expect(update.matched == 13 && update.modified == 13)
            #expect(try await driver.delete(filter: ["odd": .bool(true)], many: true, database: db, collection: "c") == 13)
            let columns = try await driver.listColumns(table: "c", schema: db)
            #expect(columns.first?.name == "_id" && columns.first?.isPrimaryKey == true)
            let stats = try await driver.tableStatistics(schema: db)
            #expect(stats["c"]?.rows == 12)
        }
    }

    @Test func shellCommands() async throws {
        try await MongoEnv.withDatabase { driver, db in
            var shell = MongoShellExecutor(driver: driver, database: db)
            let outputs = try await shell.runScript("""
            db.orders.insertMany([{ cust: "a", amount: 5, at: ISODate("2024-01-01T00:00:00Z") }, { cust: "a", amount: 7 }, { cust: "b", amount: NumberLong(1) }])
            db.orders.createIndex({ cust: 1 }, { name: "cust_1" })
            db.orders.find({ cust: "a" }).sort({ amount: -1 }).limit(1)
            db.orders.aggregate([{ $group: { _id: "$cust", total: { $sum: "$amount" } } }, { $sort: { _id: 1 } }])
            db.orders.countDocuments({ amount: { $gt: 2 } })
            db.orders.updateOne({ cust: "b" }, { $inc: { amount: 1 } })
            db.orders.find({ cust: "a" }).explain()
            db.orders.distinct("cust")
            db.orders.deleteMany({ cust: "a" })
            show collections
            """, maxDocuments: 100)
            #expect(outputs.count == 10)
            #expect(outputs[1].content.valueString == "\"cust_1\"")
            #expect(outputs[2].documents.first?["amount"] == .int32(7))
            #expect(outputs[3].documents.map { $0["total"] } == [.int32(12), .int64(1)])
            #expect(outputs[4].content.valueString == "NumberLong(2)")
            #expect(outputs[5].documents.first?["modifiedCount"] == .int32(1))
            let plan = try #require(outputs[6].documents.first.map(MongoExplain.plan))
            #expect(plan.first?.flattened().contains { $0.node.title == "IXSCAN" } == true)
            #expect(outputs[7].content.valueString == "[\"a\", \"b\"]")
            #expect(outputs[8].documents.first?["deletedCount"] == .int32(2))
            #expect(outputs[9].documents.map { $0["name"] } == [.string("orders")])
            // executeStatement (DatabaseDriver) flattens documents into rows.
            let result = try await driver.executeStatement("db.orders.find({})")
            #expect(result.columns.contains("cust") && result.rows.count == 1)
            #expect(try await driver.objectDDL(name: "orders", kind: .table, schema: db).contains("createIndex({ \"cust\": 1 }"))
        }
    }

    @Test func cancelKillsTheOperation() async throws {
        try await MongoEnv.withDatabase { driver, db in
            try await driver.insert([["x": .int32(1)]], database: db, collection: "slow")
            let running = Task {
                try await driver.find(DocumentQuery(filter: ["$where": .string("sleep(5000) || true")]), database: db, collection: "slow")
            }
            try await Task.sleep(for: .milliseconds(700))
            try await driver.cancelCurrentQuery()
            let clock = ContinuousClock(), start = clock.now
            await #expect(throws: (any Error).self) { try await running.value }
            #expect(clock.now - start < .seconds(4))
        }
    }

    /// `BUNNYGRID_MONGO_SHA1_USER` / `_PASSWORD`: an `admin` user created with `mechanisms: ["SCRAM-SHA-1"]`.
    @Test func scramSHA1User() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["BUNNYGRID_MONGO_SHA1_USER"] else { return }
        var config = ConnectionConfig(kind: .mongodb, host: MongoEnv.host, port: MongoEnv.port, username: user, database: "admin", tls: .disable)
        config.mongo = MongoOptions(authMechanism: "SCRAM-SHA-1")
        let driver = MongoDriver(config: config, secrets: ConnectionSecrets(password: env["BUNNYGRID_MONGO_SHA1_PASSWORD"]))
        try await driver.connect()
        #expect(try await driver.runCommand(["ping": .int32(1)], database: "admin").isOK)
        await driver.disconnect()
    }

    @Test func wrongPasswordFails() async throws {
        guard !MongoEnv.user.isEmpty else { return }
        let driver = MongoEnv.driver(database: "admin", password: "definitely-wrong")
        await #expect(throws: DatabaseError.self) { try await driver.connect() }
    }
}

extension MongoShellOutput.Content {
    var valueString: String? {
        if case .value(let value) = self { BSONFormat.scalarShell(value) } else { nil }
    }
}
