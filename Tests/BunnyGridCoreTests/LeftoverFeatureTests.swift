import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct PostgresTimestampTextTests {
    @Test func keepsMicrosecondsWithoutTrailingZeros() {
        // 2024-05-01 10:20:30.123456 UTC, in microseconds since 2000-01-01.
        let base: Int64 = 767_874_030 * 1_000_000
        #expect(PostgresDriver.timestampText(microseconds: base + 123_456, timeZone: nil) == "2024-05-01 10:20:30.123456")
        #expect(PostgresDriver.timestampText(microseconds: base + 500_000, timeZone: nil) == "2024-05-01 10:20:30.5")
        #expect(PostgresDriver.timestampText(microseconds: base, timeZone: nil) == "2024-05-01 10:20:30")
        #expect(PostgresDriver.timestampText(microseconds: -1, timeZone: nil) == "1999-12-31 23:59:59.999999")
        #expect(PostgresDriver.timestampText(microseconds: .max, timeZone: nil) == "infinity")
        #expect(PostgresDriver.timestampText(microseconds: .min, timeZone: nil) == "-infinity")
    }

    @Test func zonedTextHasOffset() {
        let base: Int64 = 767_874_030 * 1_000_000
        let saoPaulo = TimeZone(identifier: "America/Sao_Paulo")!
        #expect(PostgresDriver.timestampText(microseconds: base + 10, timeZone: saoPaulo) == "2024-05-01 07:20:30.00001-03:00")
        #expect(PostgresDriver.timestampText(microseconds: base, timeZone: TimeZone(identifier: "Asia/Kolkata")!) == "2024-05-01 15:50:30+05:30")
    }
}

@Suite struct DesignerLeftoversTests {
    @Test func parsesUniqueConflicts() {
        let sql = #"""
            CREATE TABLE t (id INTEGER PRIMARY KEY ON CONFLICT REPLACE, "e mail" TEXT UNIQUE ON CONFLICT IGNORE, code TEXT UNIQUE,
              a INT, b INT, note TEXT DEFAULT 'UNIQUE ON CONFLICT FAIL', CONSTRAINT ab UNIQUE ("a", b) ON CONFLICT replace, UNIQUE (code, a))
            """#
        #expect(SQLiteTableOptions.uniqueConflicts(in: sql) == [["e mail"]: "IGNORE", ["a", "b"]: "REPLACE"])
        #expect(SQLiteTableRebuild.unsupportedFeatures(in: sql).isEmpty, "unique ON CONFLICT is modeled now")
        let indexes = [IndexDesign(originalName: "sqlite_autoindex_t_1", name: "sqlite_autoindex_t_1", columns: ["e mail"], unique: true),
                       IndexDesign(originalName: "sqlite_autoindex_t_3", name: "sqlite_autoindex_t_3", columns: ["a", "b"], unique: true),
                       IndexDesign(originalName: "i", name: "i", columns: ["a"])]
        let applied = SQLiteTableOptions.applyingUniqueConflicts(from: sql, to: indexes)
        #expect(applied.map(\.onConflict) == ["IGNORE", "REPLACE", nil])
        var changed = applied
        #expect(!SQLiteTableOptions.uniqueConflictsChanged(original: applied, design: changed))
        changed[0].onConflict = nil
        #expect(SQLiteTableOptions.uniqueConflictsChanged(original: applied, design: changed))
        #expect(SQLiteTableOptions.uniqueConflictsChanged(original: applied, design: applied + [IndexDesign(name: "n", columns: ["a"], unique: true, onConflict: "FAIL")]))
        #expect(!SQLiteTableOptions.uniqueConflictsChanged(original: applied, design: applied + [IndexDesign(name: "n", columns: ["a"], unique: true)]))
    }

    @Test func sqliteUniqueConflictCreateAndRebuild() async throws {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite))
        try await driver.connect()
        let d = driver.dialect
        let columns = [ColumnDesign(name: "id", type: "INTEGER", nullable: false, isPrimaryKey: true), ColumnDesign(name: "email", type: "TEXT")]
        let create = try d.createTable(name: "u", schema: nil, columns: columns, sqliteOptions: SQLiteTableOptions(autoincrement: true),
                                       uniqueConstraints: [IndexDesign(name: "x", columns: ["email"], unique: true, onConflict: "IGNORE")])
        #expect(create.contains(#"UNIQUE ("email") ON CONFLICT IGNORE"#))
        try await driver.applyDesign([create] + d.setAutoIncrement(table: "u", schema: nil, next: 100))
        _ = try await driver.execute("INSERT INTO u (email) VALUES ('a'); INSERT INTO u (email) VALUES ('a')")
        #expect(try await driver.executeStatement("SELECT id, email FROM u").rows == [[.integer(100), .text("a")]], "IGNORE skipped the duplicate")
        // The ignored insert still used up id 101.
        #expect(await driver.autoIncrementNext(table: "u", schema: nil) == 102)

        // Rebuild with REPLACE instead of IGNORE (and a type change).
        let stored = try await driver.storedTableSQL("u")
        let original = try await driver.listColumns(table: "u", schema: nil)
        let indexes = try await driver.listIndexes(table: "u", schema: nil)
        var designs = SQLiteTableOptions.applyingUniqueConflicts(from: stored, to: indexes.map(IndexDesign.init))
        #expect(designs.compactMap(\.onConflict) == ["IGNORE"])
        designs = designs.map { index in
            var index = index
            if index.onConflict != nil { index.onConflict = "REPLACE" }
            return index
        }
        var design = original.map(ColumnDesign.init)
        design[1].type = "VARCHAR(80)"
        let rebuild = SQLiteTableRebuild(table: "u", originalSQL: stored, originalColumns: original, columns: design, originalIndexes: indexes,
                                         indexes: designs, foreignKeys: [], triggers: [], checkForeignKeys: false)
        try await driver.applyDesign(try rebuild.statements() + d.setAutoIncrement(table: "u", schema: nil, next: 500))
        #expect(try await driver.storedTableSQL("u")?.contains("ON CONFLICT REPLACE") == true)
        _ = try await driver.execute("INSERT INTO u (email) VALUES ('a')")
        #expect(try await driver.executeStatement("SELECT id, email FROM u").rows == [[.integer(500), .text("a")]], "REPLACE swapped the row, counter kept")
    }

    @Test func postgresCommentAndCollation() throws {
        let pg = SQLDialect(kind: .postgresql)
        let before = [TableColumn(name: "name", dataType: "text", nullable: true, ordinal: 1, comment: "old"),
                      TableColumn(name: "code", dataType: "varchar(5)", nullable: true, ordinal: 2)]
        var design = before.map(ColumnDesign.init)
        #expect(try pg.alterTable(name: "t", schema: "s", original: before, design: design).isEmpty)
        design[0].comment = "it's new"
        design[1].collation = "C"
        design.append(ColumnDesign(name: "extra", type: "text", comment: "added", collation: "POSIX"))
        let statements = try pg.alterTable(name: "t", schema: "s", original: before, design: design)
        #expect(statements == [
            #"ALTER TABLE "s"."t" ALTER COLUMN "code" TYPE varchar(5) COLLATE "C""#,
            #"ALTER TABLE "s"."t" ADD COLUMN "extra" text COLLATE "POSIX""#,
            #"COMMENT ON COLUMN "s"."t"."name" IS 'it''s new'"#,
            #"COMMENT ON COLUMN "s"."t"."extra" IS 'added'"#,
        ])
        design[0].comment = ""
        #expect(try pg.alterTable(name: "t", schema: "s", original: before, design: Array(design.prefix(2)))
            .contains(#"COMMENT ON COLUMN "s"."t"."name" IS NULL"#))
        #expect(pg.columnCommentStatements(table: "n", schema: nil, columns: [ColumnDesign(name: "a", type: "int", comment: "x")])
            == [#"COMMENT ON COLUMN "n"."a" IS 'x'"#])
    }

    @Test func mysqlCommentCollationAndAutoIncrement() throws {
        let my = SQLDialect(kind: .mysql)
        let before = [TableColumn(name: "id", dataType: "int", nullable: false, isPrimaryKey: true, ordinal: 1, extra: "AUTO_INCREMENT", comment: "the key"),
                      TableColumn(name: "name", dataType: "varchar(20)", nullable: true, ordinal: 2, collation: "utf8mb4_0900_ai_ci")]
        var design = before.map(ColumnDesign.init)
        #expect(try my.alterTable(name: "t", schema: "db", original: before, design: design).isEmpty)
        design[0].comment = "id's"
        design[1].collation = "utf8mb4_bin"
        #expect(try my.alterTable(name: "t", schema: "db", original: before, design: design) == [
            "ALTER TABLE `db`.`t` MODIFY COLUMN `id` int NOT NULL AUTO_INCREMENT COMMENT 'id''s'",
            "ALTER TABLE `db`.`t` MODIFY COLUMN `name` varchar(20) COLLATE utf8mb4_bin",
        ])
        #expect(my.setAutoIncrement(table: "t", schema: "db", next: 42) == ["ALTER TABLE `db`.`t` AUTO_INCREMENT = 42"])
        #expect(SQLDialect.autoIncrement(inCreateTable: "CREATE TABLE `t` (\n `id` int NOT NULL AUTO_INCREMENT\n) ENGINE=InnoDB AUTO_INCREMENT=17 DEFAULT CHARSET=utf8mb4") == 17)
        #expect(SQLDialect.autoIncrement(inCreateTable: "CREATE TABLE `t` (\n `id` int NOT NULL AUTO_INCREMENT\n) ENGINE=InnoDB") == nil)
        #expect(SQLDialect(kind: .postgresql).setAutoIncrement(table: "t", schema: nil, next: 3).isEmpty)
    }
}
