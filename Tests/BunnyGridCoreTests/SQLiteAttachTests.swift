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
}
