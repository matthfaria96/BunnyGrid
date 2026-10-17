import Foundation
import Testing
@testable import BunnyGridCore

/// Connection loss: a driver whose connection the server closed (restart, `pg_terminate_backend`, `KILL`,
/// `CLIENT KILL`) fails that call with `connectionLost` at worst, and reconnects on the next one.
@Suite struct SQLiteReconnectTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bg-reconnect-\(UUID().uuidString).sqlite")
    }

    @Test func movedFileFailsClearlyThenReopensWhenBack() async throws {
        let url = tempFile(), moved = url.appendingPathExtension("moved")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: moved) }
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: url.path))
        try await driver.connect()
        _ = try await driver.execute("CREATE TABLE t (x); INSERT INTO t VALUES (1);")

        try FileManager.default.moveItem(at: url, to: moved)
        await #expect(throws: DatabaseError.self) { _ = try await driver.executeStatement("INSERT INTO t VALUES (2)") }
        do {
            _ = try await driver.executeStatement("SELECT 1")
            Issue.record("expected connectionLost while the file is missing")
        } catch {
            #expect(error.isConnectionLost)
        }

        try FileManager.default.moveItem(at: moved, to: url)
        let rows = try await driver.executeStatement("SELECT count(*) FROM t").rows
        #expect(rows == [[.integer(1)]])
        await driver.disconnect()
    }

    @Test func replacedFileIsReopened() async throws {
        let url = tempFile(), other = tempFile()
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: other) }
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: url.path))
        try await driver.connect()
        _ = try await driver.execute("CREATE TABLE t (x); INSERT INTO t VALUES (1);")

        let writer = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: other.path))
        try await writer.connect()
        _ = try await writer.execute("CREATE TABLE t (x); INSERT INTO t VALUES (1), (2), (3);")
        await writer.disconnect()
        _ = try FileManager.default.replaceItemAt(url, withItemAt: other)

        #expect(try await driver.executeStatement("SELECT count(*) FROM t").rows == [[.integer(3)]])
        await driver.disconnect()
    }
}

/// Runs one statement after the connection was killed: the first call may fail (only with `connectionLost`),
/// the next one must work on a fresh connection.
private func expectRecovers(_ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch {
        #expect(error.isConnectionLost, "first call after the kill failed with \(error)")
    }
    try await body()
}

private let env = ProcessInfo.processInfo.environment

@Suite(.enabled(if: env["BUNNYGRID_PG_PORT"] != nil), .serialized)
struct PostgresReconnectTests {
    private func config() -> ConnectionConfig {
        var config = ConnectionConfig(kind: .postgresql, host: env["BUNNYGRID_PG_HOST"] ?? "localhost",
                                      port: Int(env["BUNNYGRID_PG_PORT"] ?? "") ?? 5432,
                                      username: env["BUNNYGRID_PG_USER"] ?? "postgres",
                                      database: env["BUNNYGRID_PG_DATABASE"] ?? "postgres")
        config.initialQueries = "SET application_name = 'bg_reconnect'"
        return config
    }

    @Test func reconnectsAfterTheBackendIsTerminated() async throws {
        let driver = PostgresDriver(config: config(), password: env["BUNNYGRID_PG_PASSWORD"])
        try await driver.connect()
        for statement in InitialQueries.statements(driver.config) { _ = try await driver.executeStatement(statement) }
        let pid = try await driver.executeStatement("SELECT pg_backend_pid()").rows.first?.first

        let killer = PostgresDriver(config: config(), password: env["BUNNYGRID_PG_PASSWORD"])
        try await killer.connect()
        _ = try await killer.executeStatement("SELECT pg_terminate_backend(\(pid?.displayString ?? "0"))")
        await killer.disconnect()
        try await Task.sleep(for: .milliseconds(200))

        try await expectRecovers { _ = try await driver.executeStatement("SELECT 1") }
        #expect(await driver.reconnectCount == 1)
        #expect(try await driver.executeStatement("SELECT pg_backend_pid()").rows.first?.first != pid)
        // The Initial Queries ran again on the new connection.
        #expect(try await driver.executeStatement("SHOW application_name").rows == [[.text("bg_reconnect")]])
        await driver.disconnect()
    }

    @Test func disconnectedDriverDoesNotReconnect() async throws {
        let driver = PostgresDriver(config: config(), password: env["BUNNYGRID_PG_PASSWORD"])
        try await driver.connect()
        await driver.disconnect()
        await #expect(throws: DatabaseError.self) { _ = try await driver.executeStatement("SELECT 1") }
    }
}

@Suite(.enabled(if: env["BUNNYGRID_MYSQL_PORT"] != nil), .serialized)
struct MySQLReconnectTests {
    private func driver() -> MySQLDriver {
        MySQLDriver(config: ConnectionConfig(kind: .mysql, host: env["BUNNYGRID_MYSQL_HOST"] ?? "127.0.0.1",
                                             port: Int(env["BUNNYGRID_MYSQL_PORT"] ?? "") ?? 3306,
                                             username: env["BUNNYGRID_MYSQL_USER"] ?? "root", database: ""),
                    password: env["BUNNYGRID_MYSQL_PASSWORD"])
    }

    @Test func reconnectsAfterKill() async throws {
        let driver = driver()
        try await driver.connect()
        let id = try await driver.executeStatement("SELECT CONNECTION_ID()").rows.first?.first?.displayString ?? "0"
        let killer = self.driver()
        try await killer.connect()
        _ = try await killer.executeStatement("KILL \(id)")
        await killer.disconnect()
        try await Task.sleep(for: .milliseconds(200))

        try await expectRecovers { _ = try await driver.executeStatement("SELECT 1") }
        #expect(await driver.reconnectCount == 1)
        #expect(try await driver.executeStatement("SELECT CONNECTION_ID()").rows.first?.first?.displayString != id)
        await driver.disconnect()
    }
}

@Suite(.enabled(if: env["BUNNYGRID_REDIS_PORT"] != nil), .serialized)
struct RedisReconnectTests {
    private func driver() -> RedisDriver {
        RedisDriver(config: ConnectionConfig(kind: .redis, host: "127.0.0.1", port: Int(env["BUNNYGRID_REDIS_PORT"] ?? ""), database: "9"),
                    secrets: ConnectionSecrets(password: env["BUNNYGRID_REDIS_PASSWORD"]))
    }

    @Test func reconnectsAfterClientKill() async throws {
        let driver = driver()
        try await driver.connect()
        guard case .integer(let id) = try await driver.call(nil, ["CLIENT", "ID"]) else { Issue.record("no client id"); return }
        let killer = self.driver()
        try await killer.connect()
        _ = try await killer.call(nil, ["CLIENT", "KILL", "ID", String(id)])
        await killer.disconnect()
        try await Task.sleep(for: .milliseconds(200))

        try await expectRecovers { _ = try await driver.call(nil, ["PING"]) }
        #expect(await driver.reconnectCount == 1)
        await driver.disconnect()
    }
}

@Suite(.enabled(if: env["BUNNYGRID_MONGO_PORT"] != nil), .serialized)
struct MongoReconnectTests {
    /// `BUNNYGRID_MONGO_RESTART` is a shell command that restarts the server (the connection then drops).
    @Test(.enabled(if: env["BUNNYGRID_MONGO_RESTART"] != nil))
    func reconnectsAfterRestart() async throws {
        let config = ConnectionConfig(kind: .mongodb, host: env["BUNNYGRID_MONGO_HOST"] ?? "127.0.0.1",
                                      port: Int(env["BUNNYGRID_MONGO_PORT"] ?? ""), username: env["BUNNYGRID_MONGO_USER"] ?? "", database: "test")
        let driver = MongoDriver(config: config, secrets: ConnectionSecrets(password: env["BUNNYGRID_MONGO_PASSWORD"]))
        try await driver.connect()
        _ = try await driver.runCommand(["ping": .int32(1)], database: "admin")
        let restart = Process()
        restart.executableURL = URL(fileURLWithPath: "/bin/sh")
        restart.arguments = ["-c", env["BUNNYGRID_MONGO_RESTART"] ?? "true"]
        try restart.run()
        restart.waitUntilExit()
        try await expectRecovers { _ = try await driver.runCommand(["ping": .int32(1)], database: "admin") }
        #expect(await driver.reconnectCount >= 1)
        await driver.disconnect()
    }
}

@Suite struct TransactionStateTests {
    @Test func followsBeginAndEnd() {
        #expect(TransactionState.after("BEGIN", wasOpen: false))
        #expect(TransactionState.after("begin transaction;", wasOpen: false))
        #expect(TransactionState.after("START TRANSACTION", wasOpen: false))
        #expect(TransactionState.after("BEGIN TRAN", wasOpen: false))
        #expect(!TransactionState.after("BEGIN TRY SELECT 1 END TRY", wasOpen: false))
        #expect(TransactionState.after("SELECT 1", wasOpen: true))
        #expect(!TransactionState.after("COMMIT", wasOpen: true))
        #expect(!TransactionState.after("rollback", wasOpen: true))
        #expect(TransactionState.after("ROLLBACK TO SAVEPOINT a", wasOpen: true))
        #expect(!TransactionState.after("END", wasOpen: true))
    }

    /// A transaction on a SQLite file that is replaced underneath fails instead of continuing on the new file.
    @Test func sqliteReplacedDuringTransactionFails() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bg-tx-\(UUID().uuidString).sqlite")
        let other = url.appendingPathExtension("new")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: other) }
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: url.path))
        try await driver.connect()
        _ = try await driver.execute("CREATE TABLE t (x); BEGIN; INSERT INTO t VALUES (1);")
        FileManager.default.createFile(atPath: other.path, contents: Data())
        _ = try FileManager.default.replaceItemAt(url, withItemAt: other)
        do {
            _ = try await driver.executeStatement("INSERT INTO t VALUES (2)")
            Issue.record("expected the lost transaction to fail")
        } catch {
            #expect(error.isConnectionLost)
        }
        #expect(await driver.inTransaction == false)
        await driver.disconnect()
    }
}

@Suite(.enabled(if: env["BUNNYGRID_PG_PORT"] != nil), .serialized)
struct PostgresLostTransactionTests {
    private func config() -> ConnectionConfig {
        ConnectionConfig(kind: .postgresql, host: env["BUNNYGRID_PG_HOST"] ?? "localhost",
                         port: Int(env["BUNNYGRID_PG_PORT"] ?? "") ?? 5432,
                         username: env["BUNNYGRID_PG_USER"] ?? "postgres",
                         database: env["BUNNYGRID_PG_DATABASE"] ?? "postgres")
    }

    /// The connection drops inside a transaction: the next statement fails with `connectionLost` instead of
    /// autocommitting on the reconnected session, and applying the (still pending) grid edits again saves them once.
    @Test func lostTransactionSavesNothingThenApplyWorks() async throws {
        let password = env["BUNNYGRID_PG_PASSWORD"]
        let driver = PostgresDriver(config: config(), password: password)
        try await driver.connect()
        let table = "bg_tx_\(UUID().uuidString.prefix(8).lowercased())"
        _ = try await driver.executeStatement("CREATE TABLE \(table) (id int PRIMARY KEY, name text)")

        _ = try await driver.executeStatement("BEGIN")
        _ = try await driver.executeStatement("INSERT INTO \(table) VALUES (1, 'a')")
        let pid = try await driver.executeStatement("SELECT pg_backend_pid()").rows.first?.first?.displayString ?? "0"
        let killer = PostgresDriver(config: config(), password: password)
        try await killer.connect()
        _ = try await killer.executeStatement("SELECT pg_terminate_backend(\(pid))")
        await killer.disconnect()
        try await Task.sleep(for: .milliseconds(200))

        do {
            _ = try await driver.executeStatement("INSERT INTO \(table) VALUES (2, 'b')")
            Issue.record("expected connectionLost inside the transaction")
        } catch {
            #expect(error.isConnectionLost)
        }
        #expect(try await driver.executeStatement("SELECT count(*) FROM \(table)").rows.first?.first?.displayString == "0")

        try await driver.applyChanges([.insert(values: [ColumnValue("id", .integer(1)), ColumnValue("name", .text("a"))])],
                                      table: table, schema: nil)
        #expect(try await driver.executeStatement("SELECT count(*) FROM \(table)").rows.first?.first?.displayString == "1")
        _ = try await driver.executeStatement("DROP TABLE \(table)")
        await driver.disconnect()
    }
}

@Suite struct StoreQuarantineTests {
    @Test func unreadableFileIsMovedAsideNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bg-quarantine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "queries.json")
        try Data("{not json".utf8).write(to: url)
        let store = JSONListStore<SavedQuery>(fileURL: url)

        let loaded = StoreQuarantine.load(url) { try store.load() }
        #expect(loaded.elements.isEmpty)
        #expect(loaded.problem?.contains("queries.unreadable-") == true)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(kept.count == 1 && kept[0].hasPrefix("queries.unreadable-"))
        #expect(try String(contentsOf: dir.appending(path: kept[0]), encoding: .utf8) == "{not json")
    }

    @Test func missingFileIsNoProblem() {
        let url = FileManager.default.temporaryDirectory.appending(path: "bg-missing-\(UUID().uuidString).json")
        let loaded = StoreQuarantine.load(url) { try JSONListStore<SavedQuery>(fileURL: url).load() }
        #expect(loaded.elements.isEmpty && loaded.problem == nil)
    }
}
