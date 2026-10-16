import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct CSVParserTests {
    @Test func parsesQuotedFieldsAndNewlines() {
        let csv = "id,name,note\r\n1,\"Silva, Ana\",\"said \"\"hi\"\"\"\r\n2,Bia,\"two\nlines\"\n"
        #expect(CSVParser.parse(csv) == [
            ["id", "name", "note"],
            ["1", "Silva, Ana", "said \"hi\""],
            ["2", "Bia", "two\nlines"],
        ])
    }

    @Test func keepsEmptyFieldsAndLastLineWithoutNewline() {
        #expect(CSVParser.parse("a,,c\n,,") == [["a", "", "c"], ["", "", ""]])
    }

    @Test func detectsDelimiter() {
        #expect(CSVParser.detectDelimiter("a;b;c\n1;2;3") == ";")
        #expect(CSVParser.detectDelimiter("a\tb\n1\t2") == "\t")
        #expect(CSVParser.detectDelimiter("a,b\n1,2") == ",")
    }
}

@Suite struct TableDesignTests {
    let pg = SQLDialect(kind: .postgresql)
    let mysql = SQLDialect(kind: .mysql)
    let sqlite = SQLDialect(kind: .sqlite)

    private let original = [
        TableColumn(name: "id", dataType: "int4", nullable: false, isPrimaryKey: true, ordinal: 1),
        TableColumn(name: "name", dataType: "varchar(45)", nullable: true, ordinal: 2),
        TableColumn(name: "legacy", dataType: "text", nullable: true, ordinal: 3),
    ]

    @Test func createsTableWithPrimaryKey() throws {
        let sql = try pg.createTable(name: "people", schema: "public", columns: [
            ColumnDesign(name: "id", type: "serial", nullable: false, isPrimaryKey: true),
            ColumnDesign(name: "email", type: "varchar(255)", nullable: false, defaultValue: "''"),
        ])
        #expect(sql == """
            CREATE TABLE "public"."people" (
              "id" serial NOT NULL,
              "email" varchar(255) NOT NULL DEFAULT '',
              PRIMARY KEY ("id")
            )
            """)
    }

    @Test func rejectsInvalidDesigns() {
        #expect(throws: TableDesignError.self) { try pg.createTable(name: "", schema: nil, columns: [ColumnDesign(name: "a", type: "int")]) }
        #expect(throws: TableDesignError.self) { try pg.createTable(name: "t", schema: nil, columns: [ColumnDesign(name: "a", type: "")]) }
        #expect(throws: TableDesignError.self) {
            try pg.createTable(name: "t", schema: nil, columns: [ColumnDesign(name: "a", type: "int"), ColumnDesign(name: "A", type: "int")])
        }
    }

    @Test func alterPostgres() throws {
        var design = original.map(ColumnDesign.init)
        design.removeLast()                                  // drop legacy
        design[1].name = "full_name"                          // rename
        design[1].type = "varchar(100)"                       // retype
        design[1].nullable = false
        design.append(ColumnDesign(name: "active", type: "bool", defaultValue: "true"))
        let statements = try pg.alterTable(name: "people", schema: "public", original: original, design: design)
        #expect(statements == [
            #"ALTER TABLE "public"."people" DROP COLUMN "legacy""#,
            #"ALTER TABLE "public"."people" RENAME COLUMN "name" TO "full_name""#,
            #"ALTER TABLE "public"."people" ALTER COLUMN "full_name" TYPE varchar(100)"#,
            #"ALTER TABLE "public"."people" ALTER COLUMN "full_name" SET NOT NULL"#,
            #"ALTER TABLE "public"."people" ADD COLUMN "active" bool DEFAULT true"#,
        ])
    }

    @Test func alterMySQLUsesModify() throws {
        var design = original.map(ColumnDesign.init)
        design[1].defaultValue = "'x'"
        #expect(try mysql.alterTable(name: "people", schema: "shop", original: original, design: design) == [
            "ALTER TABLE `shop`.`people` MODIFY COLUMN `name` varchar(45) DEFAULT 'x'",
        ])
    }

    @Test func sqliteRefusesTypeChangesButAllowsRenameAndAdd() throws {
        var design = original.map(ColumnDesign.init)
        design[1].name = "nm"
        design.append(ColumnDesign(name: "n", type: "INTEGER"))
        #expect(try sqlite.alterTable(name: "t", schema: nil, original: original, design: design).count == 2)
        design[1].type = "TEXT"
        #expect(throws: TableDesignError.self) { try sqlite.alterTable(name: "t", schema: nil, original: original, design: design) }
    }

    @Test func primaryKeyChangesAreRefused() {
        var design = original.map(ColumnDesign.init)
        design[1].isPrimaryKey = true
        #expect(throws: TableDesignError.self) { try pg.alterTable(name: "t", schema: nil, original: original, design: design) }
    }

    @Test func noChangesMeansNoStatements() throws {
        #expect(try pg.alterTable(name: "t", schema: nil, original: original, design: original.map(ColumnDesign.init)).isEmpty)
    }

    @Test func designAppliesToRealSQLite() async throws {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite))
        try await driver.connect()
        _ = try await driver.executeStatement(try sqlite.createTable(name: "t", schema: nil, columns: [
            ColumnDesign(name: "id", type: "INTEGER", nullable: false, isPrimaryKey: true),
            ColumnDesign(name: "a", type: "TEXT"),
        ]))
        let before = try await driver.listColumns(table: "t", schema: nil)
        var design = before.map(ColumnDesign.init)
        design[1].name = "b"
        design.append(ColumnDesign(name: "c", type: "REAL", nullable: false, defaultValue: "0"))
        for statement in try sqlite.alterTable(name: "t", schema: nil, original: before, design: design) {
            _ = try await driver.executeStatement(statement)
        }
        #expect(try await driver.listColumns(table: "t", schema: nil).map(\.name) == ["id", "b", "c"])
    }
}

@Suite struct JSONListStoreTests {
    @Test func roundTripsSavedQueries() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "bg-queries-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JSONListStore<SavedQuery>(fileURL: url)
        let query = SavedQuery(connectionID: UUID(), database: "main", name: "Top customers", sql: "SELECT 1")
        try store.save([query])
        let loaded = try store.load()
        // ISO 8601 keeps whole seconds; compare everything else exactly.
        #expect(loaded.map(\.id) == [query.id])
        #expect(loaded.first?.sql == "SELECT 1")
        #expect(loaded.first?.name == "Top customers")
    }
}
