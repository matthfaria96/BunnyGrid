import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct SQLiteAttachTests {
    @Test func attachListsTheDatabaseAndItsObjects() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bg-attach-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        let other = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: file.path))
        try await other.connect()
        _ = try await other.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT); INSERT INTO notes (body) VALUES ('a'), ('b');")
        await other.disconnect()

        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: ""))
        try await driver.connect()
        try await driver.attach(path: file.path, as: "extra")
        #expect(try await driver.listDatabases().contains("extra"))
        let objects = try await driver.listObjects(schema: "extra")
        #expect(objects.map(\.name) == ["notes"])
        #expect(objects.first?.schema == "extra")
        #expect(try await driver.listObjects(schema: nil).isEmpty)
        #expect(try await driver.listColumns(table: "notes", schema: "extra").map(\.name) == ["id", "body"])
        #expect(try await driver.tableStatistics(schema: "extra")["notes"]?.rows == 2)
        try await driver.detach("extra")
        #expect(try await !driver.listDatabases().contains("extra"))
    }

    @Test func rebuildStaysInTheAttachedDatabase() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bg-rebuild-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: ""))
        try await driver.connect()
        _ = try await driver.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)")
        try await driver.attach(path: file.path, as: "extra")
        _ = try await driver.execute("""
            CREATE TABLE extra.notes (id INTEGER PRIMARY KEY, body TEXT);
            CREATE INDEX extra.notes_body ON notes (body);
            INSERT INTO extra.notes (body) VALUES ('a');
            """)

        let original = try await driver.listColumns(table: "notes", schema: "extra")
        var rebuild = SQLiteTableRebuild(
            table: "notes", originalSQL: try await driver.storedTableSQL("notes", schema: "extra"), originalColumns: original,
            columns: original.map(ColumnDesign.init) + [ColumnDesign(name: "added", type: "TEXT")],
            originalIndexes: try await driver.listIndexes(table: "notes", schema: "extra"),
            indexes: [IndexDesign(name: "notes_body", columns: ["body"])], foreignKeys: [],
            triggers: ["CREATE TRIGGER notes_ai AFTER INSERT ON notes BEGIN SELECT 1; END"], checkForeignKeys: true)
        rebuild.schema = "extra"
        try await driver.applyDesign(try rebuild.statements())

        #expect(try await driver.listColumns(table: "notes", schema: "extra").map(\.name) == ["id", "body", "added"])
        #expect(try await driver.listColumns(table: "notes", schema: nil).map(\.name) == ["id", "body"])
        let count = try await driver.executeStatement("SELECT COUNT(*) FROM extra.notes").rows.first?.first
        #expect(count == .integer(1))
        let triggers = try await driver.executeStatement("SELECT COUNT(*) FROM extra.sqlite_master WHERE type = 'trigger'").rows.first?.first
        #expect(triggers == .integer(1))
    }

    @Test func indexStatementsQualifyTheIndexForAnAttachedDatabase() throws {
        let d = SQLDialect(kind: .sqlite)
        #expect(try d.createIndex(IndexDesign(name: "i", columns: ["a"]), table: "t", schema: "extra") == #"CREATE INDEX "extra"."i" ON "t" ("a")"#)
        #expect(try d.createIndex(IndexDesign(name: "i", columns: ["a"]), table: "t", schema: nil) == #"CREATE INDEX "i" ON "t" ("a")"#)
        #expect(d.dropIndex(named: "i", table: "t", schema: "extra") == #"DROP INDEX "extra"."i""#)
    }
}
