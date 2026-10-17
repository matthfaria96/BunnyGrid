import Foundation
import Testing
@testable import BunnyGridCore

func syncSQLite(_ name: String) async throws -> SQLiteDriver {
    let dir = FileManager.default.temporaryDirectory.appending(path: "bg-sync-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let driver = SQLiteDriver(config: ConnectionConfig(name: name, kind: .sqlite, filePath: dir.appending(path: "\(name).sqlite").path))
    try await driver.connect()
    return driver
}

func syncRun(_ driver: any DatabaseDriver, _ script: String) async throws {
    for statement in SQLSplitter.split(script) { _ = try await driver.executeStatement(statement) }
}

let syncSampleSchema = """
    CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email VARCHAR(80) UNIQUE, active BOOLEAN DEFAULT 1, balance NUMERIC(10,2));
    CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id), total REAL, created DATETIME DEFAULT CURRENT_TIMESTAMP);
    CREATE INDEX orders_customer ON orders (customer_id);
    CREATE VIEW big_orders AS SELECT * FROM orders WHERE total > 100;
    INSERT INTO customers VALUES (1, 'Ana', 'ana@x.com', 1, 10.5), (2, 'Bo', NULL, 0, NULL), (3, 'Cy', 'cy@x.com', 1, 3);
    INSERT INTO orders VALUES (1, 1, 150.0, '2026-01-02 10:00:00'), (2, 3, 20.5, '2026-01-03 11:00:00');
    """

@Suite struct SyncTests {
    @Test func sqliteToSQLiteTransfer() async throws {
        let source = try await syncSQLite("src"), target = try await syncSQLite("dst")
        try await syncRun(source, syncSampleSchema)
        let summary = try await DataTransfer(source: source, sourceSchema: nil, tables: ["orders", "customers"],
                                             destination: .database(target, schema: nil),
                                             options: DataTransferOptions(rowsPerBatch: 2)).run()
        #expect(summary.rows == 5 && summary.errors == 0)
        #expect(try await target.countRows(table: "customers", schema: nil) == 3)
        let keys = try await target.listForeignKeys(table: "orders", schema: nil)
        #expect(keys.first?.referencedTable == "customers")
        #expect(try await target.listIndexes(table: "orders", schema: nil).contains { $0.name == "orders_customer" })
        // Again with drop first: same rows, no duplicates.
        _ = try await DataTransfer(source: source, sourceSchema: nil, tables: ["customers", "orders"],
                                   destination: .database(target, schema: nil), options: DataTransferOptions(dropTargetTables: true)).run()
        #expect(try await target.countRows(table: "orders", schema: nil) == 2)
    }

    @Test func transferToScript() async throws {
        let source = try await syncSQLite("src")
        try await syncRun(source, syncSampleSchema)
        let buffer = ScriptBuffer()
        _ = try await DataTransfer(source: source, sourceSchema: nil, tables: ["customers", "orders"],
                                   destination: .script(kind: .postgresql, schema: "public", write: { await buffer.append($0) })).run()
        let text = await buffer.text
        #expect(text.contains("CREATE TABLE \"public\".\"customers\""))
        #expect(text.contains("\"id\" serial"))
        #expect(text.contains("FOREIGN KEY"))
        #expect(text.contains("TRUE"))
        #expect(text.contains("setval"))
    }

    @Test func typeMappingPerEnginePair() {
        #expect(SchemaMapper.columnType("INTEGER", from: .sqlite, to: .postgresql) == "integer")
        #expect(SchemaMapper.columnType("FLOAT", from: .sqlite, to: .postgresql) == "double precision")
        #expect(SchemaMapper.columnType("DATETIME", from: .sqlite, to: .mysql) == "datetime")
        #expect(SchemaMapper.columnType("TEXT", from: .sqlite, to: .mysql, isKey: true) == "varchar(255)")
        #expect(SchemaMapper.columnType("int4", from: .postgresql, to: .sqlite) == "INTEGER")
        #expect(SchemaMapper.columnType("bytea", from: .postgresql, to: .mysql) == "longblob")
        #expect(SchemaMapper.columnType("_int4", from: .postgresql, to: .mysql) == "text")
        #expect(SchemaMapper.columnType("money", from: .postgresql, to: .mysql) == "decimal(38,10)")
        #expect(SchemaMapper.columnType("uuid", from: .postgresql, to: .mysql) == "char(36)")
        #expect(SchemaMapper.columnType("tinyint(1)", from: .mysql, to: .postgresql) == "boolean")
        #expect(SchemaMapper.columnType("int(11) unsigned", from: .mysql, to: .sqlite) == "INTEGER")
        #expect(SchemaMapper.columnType("longtext", from: .mysql, to: .postgresql) == "text")
        #expect(SchemaMapper.columnType("varchar(40)", from: .mysql, to: .mariadb) == "varchar(40)")
        #expect(SchemaMapper.columnDefault("'a'::character varying", type: "varchar", from: .postgresql, to: .sqlite) == "'a'")
        #expect(SchemaMapper.columnDefault("n/a", type: "varchar(10)", from: .mysql, to: .postgresql) == "'n/a'")
        #expect(SchemaMapper.columnDefault("1", type: "BOOLEAN", from: .sqlite, to: .postgresql) == "TRUE")
        #expect(SchemaMapper.canonicalType("int4", kind: .postgresql) == SchemaMapper.canonicalType("serial", kind: .postgresql))
        #expect(SchemaMapper.canonicalType("timestamp(6)", kind: .postgresql) == SchemaMapper.canonicalType("timestamp", kind: .postgresql))
    }

    @Test func structureSyncMakesTargetEqual() async throws {
        let source = try await syncSQLite("src"), target = try await syncSQLite("dst")
        try await syncRun(source, syncSampleSchema)
        try await syncRun(target, """
            CREATE TABLE customers (id INTEGER PRIMARY KEY, name VARCHAR(10), legacy TEXT);
            CREATE TABLE obsolete (x INTEGER);
            CREATE VIEW big_orders AS SELECT 1;
            INSERT INTO customers VALUES (7, 'Old', 'z');
            """)
        let comparison = StructureSync.compare(source: try await SchemaSnapshot.read(from: source, schema: nil),
                                               target: try await SchemaSnapshot.read(from: target, schema: nil))
        #expect(Set(comparison.differences.map(\.id)) == ["table:customers", "table:orders", "table:obsolete", "view:big_orders"])
        try await StructureSync.deploy(try comparison.deployScript(), on: target)
        let again = StructureSync.compare(source: try await SchemaSnapshot.read(from: source, schema: nil),
                                          target: try await SchemaSnapshot.read(from: target, schema: nil))
        #expect(again.differences.isEmpty, "\(again.differences)")
        #expect(try await target.countRows(table: "customers", schema: nil) == 1)
    }

    @Test func dataSyncRoundTrip() async throws {
        let source = try await syncSQLite("src"), target = try await syncSQLite("dst")
        try await syncRun(source, syncSampleSchema)
        try await syncRun(target, """
            CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email VARCHAR(80), active BOOLEAN, balance NUMERIC(10,2));
            INSERT INTO customers VALUES (1, 'Ana', 'ana@x.com', 'true', '10.50'), (2, 'Bob', NULL, 0, NULL), (9, 'Gone', NULL, 1, NULL);
            """)
        let comparison = try await DataSync.compare(source: source, sourceSchema: nil, sourceTable: "customers",
                                                    target: target, targetSchema: nil, targetTable: "customers")
        #expect(comparison.identicalRows == 1)
        #expect(comparison.count(.insert) == 1 && comparison.count(.update) == 1 && comparison.count(.delete) == 1)
        #expect(comparison.script(kind: .sqlite, schema: nil).contains("DELETE FROM"))
        #expect(try await DataSync.apply([(comparison, nil)], to: target, schema: nil, batchSize: 1) == 3)
        let after = try await DataSync.compare(source: source, sourceSchema: nil, sourceTable: "customers",
                                               target: target, targetSchema: nil, targetTable: "customers")
        #expect(after.differences.isEmpty && after.identicalRows == 3)
    }
}

actor ScriptBuffer {
    var text = ""
    func append(_ s: String) { text += s }
}
