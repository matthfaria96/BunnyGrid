import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct RowChangeSQLTests {
    let pg = SQLDialect(kind: .postgresql)
    let mysql = SQLDialect(kind: .mysql)
    let sqlite = SQLDialect(kind: .sqlite)

    @Test func update() {
        let change = RowChange.update(key: [ColumnValue("id", .integer(7))], values: [ColumnValue("name", .text("O'Hara")), ColumnValue("score", .null)])
        #expect(pg.sql(for: change, table: "users", schema: "public")
            == #"UPDATE "public"."users" SET "name" = 'O''Hara', "score" = NULL WHERE "id" = 7"#)
    }

    @Test func compositeKeyWithNull() {
        let change = RowChange.delete(key: [ColumnValue("a", .integer(1)), ColumnValue("b", .null)])
        #expect(mysql.sql(for: change, table: "t", schema: "shop") == "DELETE FROM `shop`.`t` WHERE `a` = 1 AND `b` IS NULL")
    }

    @Test func insert() {
        let change = RowChange.insert(values: [ColumnValue("name", .text("x")), ColumnValue("flag", .bool(true))])
        #expect(sqlite.sql(for: change, table: "t", schema: nil) == #"INSERT INTO "t" ("name", "flag") VALUES ('x', 1)"#)
        #expect(pg.sql(for: change, table: "t", schema: nil) == #"INSERT INTO "t" ("name", "flag") VALUES ('x', TRUE)"#)
    }

    @Test func insertWithAllDefaults() {
        #expect(pg.sql(for: .insert(values: []), table: "t", schema: nil) == #"INSERT INTO "t" DEFAULT VALUES"#)
        #expect(mysql.sql(for: .insert(values: []), table: "t", schema: nil) == "INSERT INTO `t` () VALUES ()")
    }

    @Test func blobLiterals() {
        let blob = CellValue.blob(Data([0x0a, 0xff]))
        #expect(sqlite.literal(blob) == "X'0aff'")
        #expect(pg.literal(blob) == "decode('0aff', 'hex')")
    }
}

@Suite struct ApplyChangesTests {
    private func makeDriver() async throws -> SQLiteDriver {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite))
        try await driver.connect()
        _ = try await driver.execute("""
            CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, qty INTEGER DEFAULT 0);
            INSERT INTO items (name, qty) VALUES ('a', 1), ('b', 2), ('c', 3);
            """)
        return driver
    }

    private func names(_ driver: SQLiteDriver) async throws -> [CellValue] {
        try await driver.executeStatement("SELECT name FROM items ORDER BY id").rows.map { $0[0] }
    }

    @Test func commitsAllChanges() async throws {
        let driver = try await makeDriver()
        try await driver.applyChanges([
            .update(key: [ColumnValue("id", .integer(1))], values: [ColumnValue("name", .text("A"))]),
            .delete(key: [ColumnValue("id", .integer(2))]),
            .insert(values: [ColumnValue("name", .text("d"))]),
        ], table: "items", schema: nil)
        #expect(try await names(driver) == [.text("A"), .text("c"), .text("d")])
        let qty = try await driver.executeStatement("SELECT qty FROM items WHERE name = 'd'").rows
        #expect(qty == [[.integer(0)]], "omitted columns keep their DEFAULT")
    }

    @Test func rollsBackWhenAStatementFails() async throws {
        let driver = try await makeDriver()
        await #expect(throws: DatabaseError.self) {
            try await driver.applyChanges([
                .update(key: [ColumnValue("id", .integer(1))], values: [ColumnValue("name", .text("A"))]),
                .update(key: [ColumnValue("id", .integer(2))], values: [ColumnValue("name", .null)]),
            ], table: "items", schema: nil)
        }
        #expect(try await names(driver) == [.text("a"), .text("b"), .text("c")])
    }

    @Test func rollsBackWhenTheRowIsGone() async throws {
        let driver = try await makeDriver()
        await #expect(throws: DatabaseError.self) {
            try await driver.applyChanges([
                .delete(key: [ColumnValue("id", .integer(1))]),
                .update(key: [ColumnValue("id", .integer(99))], values: [ColumnValue("name", .text("x"))]),
            ], table: "items", schema: nil)
        }
        #expect(try await names(driver).count == 3)
    }

    @Test func refusesOnReadOnlyConnections() async throws {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, readOnly: true))
        try await driver.connect()
        await #expect(throws: DatabaseError.self) {
            try await driver.applyChanges([.insert(values: [])], table: "items", schema: nil)
        }
    }
}
