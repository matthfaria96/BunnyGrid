import BunnyGridCore
import Testing

struct SQLiteTableOptionsTests {
    let sqlite = SQLDialect(kind: .sqlite)
    let id = ColumnDesign(name: "id", type: "INTEGER", nullable: false, isPrimaryKey: true)
    let name = ColumnDesign(name: "name", type: "TEXT")

    @Test func parsesStoredSQL() {
        let options = SQLiteTableOptions(sql: "CREATE TABLE t (id INTEGER PRIMARY KEY ON CONFLICT REPLACE AUTOINCREMENT, n TEXT)")
        #expect(options == SQLiteTableOptions(withoutRowID: false, autoincrement: true, primaryKeyOnConflict: "REPLACE"))
        let table = SQLiteTableOptions(sql: "CREATE TABLE \"t\" (a TEXT, b TEXT, PRIMARY KEY (a, b) ON CONFLICT IGNORE) WITHOUT ROWID")
        #expect(table == SQLiteTableOptions(withoutRowID: true, autoincrement: false, primaryKeyOnConflict: "IGNORE"))
        #expect(SQLiteTableOptions(sql: "CREATE TABLE t ('without rowid' TEXT)") == SQLiteTableOptions())
    }

    @Test func createTableWritesOptions() throws {
        let auto = try sqlite.createTable(name: "t", schema: nil, columns: [id, name],
                                          sqliteOptions: SQLiteTableOptions(autoincrement: true, primaryKeyOnConflict: "REPLACE"))
        #expect(auto.contains("\"id\" INTEGER PRIMARY KEY ON CONFLICT REPLACE AUTOINCREMENT"))
        #expect(!auto.contains("PRIMARY KEY (\"id\")"))
        let noRowID = try sqlite.createTable(name: "t", schema: nil, columns: [id, name], sqliteOptions: SQLiteTableOptions(withoutRowID: true))
        #expect(noRowID.hasSuffix(") WITHOUT ROWID"))
        #expect(noRowID.contains("PRIMARY KEY (\"id\")"))
        #expect(throws: TableDesignError.self) {
            try sqlite.createTable(name: "t", schema: nil, columns: [name], sqliteOptions: SQLiteTableOptions(withoutRowID: true))
        }
    }

    @Test func rebuildKeepsAndChangesOptions() async throws {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite))
        try await driver.connect()
        _ = try await driver.executeStatement("CREATE TABLE t (id INTEGER PRIMARY KEY ON CONFLICT REPLACE, name TEXT)")
        _ = try await driver.executeStatement("INSERT INTO t VALUES (1, 'a'), (2, 'b')")
        let original = try await driver.listColumns(table: "t", schema: nil)
        let stored = try await driver.storedTableSQL("t")
        var design = original.map(ColumnDesign.init)
        design[1].type = "VARCHAR(20)"
        // Kept: the stored ON CONFLICT survives a type change.
        let keep = SQLiteTableRebuild(table: "t", originalSQL: stored, originalColumns: original, columns: design, originalIndexes: [],
                                      indexes: [], foreignKeys: [], triggers: [], checkForeignKeys: false)
        try await driver.applyDesign(try keep.statements())
        #expect(try await driver.storedTableSQL("t")?.contains("ON CONFLICT REPLACE") == true)
        // Changed: WITHOUT ROWID on, ON CONFLICT off.
        let current = try await driver.listColumns(table: "t", schema: nil)
        let change = SQLiteTableRebuild(table: "t", originalSQL: try await driver.storedTableSQL("t"), originalColumns: current,
                                        columns: current.map(ColumnDesign.init), originalIndexes: [], indexes: [], foreignKeys: [],
                                        triggers: [], checkForeignKeys: false, options: SQLiteTableOptions(withoutRowID: true))
        try await driver.applyDesign(try change.statements())
        let sql = try await driver.storedTableSQL("t") ?? ""
        #expect(sql.contains("WITHOUT ROWID"))
        #expect(!sql.contains("ON CONFLICT"))
        #expect(try await driver.countRows(table: "t", schema: nil) == 2)
    }
}
