import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct BackupTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "bunnygrid-backup-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func seededDatabase(in dir: URL, name: String = "app.sqlite") async throws -> (ConnectionConfig, SQLiteDriver) {
        let config = ConnectionConfig(name: "App", kind: .sqlite, filePath: dir.appending(path: name).path)
        let driver = SQLiteDriver(config: config)
        try await driver.connect()
        _ = try await driver.execute("""
            CREATE TABLE customers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, note TEXT);
            CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id), total REAL, data BLOB);
            CREATE INDEX orders_customer ON orders(customer_id);
            CREATE VIEW big_orders AS SELECT * FROM orders WHERE total > 100;
            INSERT INTO customers (name, note) VALUES ('Ana', 'it''s'), ('Bia', NULL), ('Caio', 'línea
            dos');
            INSERT INTO orders VALUES (1, 1, 150.5, X'00FF10'), (2, 2, 20, NULL), (3, 1, 300, NULL);
            """)
        return (config, driver)
    }

    @Test func archiveFormatRoundTrips() throws {
        let manifest = BackupManifest(connectionID: UUID(), connectionName: "X", engine: .postgresql, database: "db", schema: "public", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                                      comment: "before migration", objects: [BackupObject(schema: "public", name: "t", kind: .table)])
        let payload = Data(String(repeating: "INSERT INTO t VALUES (1);\n", count: 500).utf8)
        let data = try BackupArchive.encode(manifest: manifest, payload: payload)
        #expect(data.prefix(8) == Data("BGBACKUP".utf8))
        #expect(data.count < payload.count / 5, "the payload is compressed")
        let decoded = try BackupArchive.decode(data)
        #expect(decoded.manifest == manifest)
        #expect(decoded.payload == payload)
        #expect(throws: BackupArchive.ArchiveError.self) { try BackupArchive.decode(Data("not a backup at all".utf8)) }
        // The payload is plain raw DEFLATE.
        let (_, offset) = try BackupArchive.header(data)
        #expect(try (Data(data.dropFirst(offset)) as NSData).decompressed(using: .zlib) as Data == payload)
    }

    @Test func sqlBackupRestoresSameAndOtherDatabase() async throws {
        let dir = try scratch()
        let (config, driver) = try await seededDatabase(in: dir)
        let store = BackupStore(directory: dir.appending(path: "backups"))
        let entry = try await BackupEngine.create(from: driver, connection: config, database: "main", schema: nil,
                                                  options: BackupOptions(comment: "first"), store: store)
        #expect(entry.manifest.objects.map(\.name).sorted() == ["big_orders", "customers", "orders"])
        #expect(entry.manifest.rowCount == 6)
        #expect(entry.fileURL.path.hasPrefix(store.folder(connectionID: config.id, database: "main", schema: nil).path))
        #expect(store.list(connectionID: config.id, database: "main", schema: nil).map(\.id) == [entry.id])
        #expect(store.list(connectionID: config.id).count == 1)

        // Damage the data, then restore over it.
        _ = try await driver.execute("DELETE FROM orders; UPDATE customers SET name = 'gone'; DROP VIEW big_orders;")
        let report = try await BackupEngine.restore(entry, store: store, into: driver)
        #expect(report.errors.isEmpty, "\(report.errors)")
        #expect(try await driver.countRows(table: "orders", schema: nil) == 3)
        #expect(try await driver.execute("SELECT name, note FROM customers ORDER BY id").first?.rows
                == [[.text("Ana"), .text("it's")], [.text("Bia"), .null], [.text("Caio"), .text("línea\ndos")]])
        #expect(try await driver.execute("SELECT data FROM orders WHERE id = 1").first?.rows == [[.blob(Data([0x00, 0xFF, 0x10]))]])
        #expect(try await driver.countRows(table: "big_orders", schema: nil) == 2)
        #expect(try await driver.listIndexes(table: "orders", schema: nil).contains { $0.name == "orders_customer" })

        // Into another, empty database.
        let other = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: dir.appending(path: "copy.sqlite").path))
        try await other.connect()
        let copied = try await BackupEngine.restore(entry, store: store, into: other)
        #expect(copied.errors.isEmpty)
        #expect(try await other.countRows(table: "customers", schema: nil) == 3)

        // Without DROP, existing tables make their CREATE fail; continuing on errors still runs the rest.
        let keep = try await BackupEngine.restore(entry, store: store, into: other, options: RestoreOptions(dropExisting: false, continueOnError: true))
        #expect(!keep.errors.isEmpty)
        #expect(keep.errors.allSatisfy { !$0.statement.uppercased().contains("DROP ") })
        let stop = try await BackupEngine.restore(entry, store: store, into: other, options: RestoreOptions(dropExisting: false, continueOnError: false))
        #expect(stop.stopped && stop.errors.count == 1)

        // Extract to .sql and edit the comment.
        let sql = try await BackupEngine.extractSQL(entry, store: store)
        #expect(sql.contains("-- BunnyGrid backup of App"))
        #expect(sql.contains("CREATE TABLE"))
        #expect(sql.contains("Comment: first"))
        let renamed = try store.setComment("renamed", of: entry)
        #expect(store.list(connectionID: config.id, database: "main", schema: nil).first?.manifest.comment == "renamed")
        #expect(try store.payload(of: renamed) == (try store.payload(of: entry)))
        try store.delete(renamed)
        #expect(store.list(connectionID: config.id).isEmpty)
        await driver.disconnect()
        await other.disconnect()
    }

    @Test func chosenObjectsAndStructureOnly() async throws {
        let dir = try scratch()
        let (config, driver) = try await seededDatabase(in: dir)
        let store = BackupStore(directory: dir.appending(path: "backups"))
        let entry = try await BackupEngine.create(from: driver, connection: config, database: "main", schema: nil,
                                                  options: BackupOptions(objects: [BackupObject(schema: nil, name: "customers", kind: .table)],
                                                                         includeData: false), store: store)
        #expect(entry.manifest.objects.map(\.name) == ["customers"])
        #expect(entry.manifest.rowCount == nil)
        let sql = try await BackupEngine.extractSQL(entry, store: store)
        #expect(sql.contains("customers"))
        #expect(!sql.contains("INSERT"))
        #expect(!sql.contains("orders"))
        await driver.disconnect()
    }

    @Test func sqliteFileCopyRoundTrip() async throws {
        let dir = try scratch()
        let (config, driver) = try await seededDatabase(in: dir)
        let store = BackupStore(directory: dir.appending(path: "backups"))
        let entry = try await BackupEngine.create(from: driver, connection: config, database: "main", schema: nil,
                                                  options: BackupOptions(method: .sqliteFile), store: store)
        #expect(entry.manifest.method == .sqliteFile)
        _ = try await driver.execute("DROP VIEW big_orders; DROP TABLE orders; INSERT INTO customers (name) VALUES ('new');")
        // Restored under the open connection, page by page.
        _ = try await BackupEngine.restore(entry, store: store, into: driver)
        #expect(try await driver.countRows(table: "orders", schema: nil) == 3)
        #expect(try await driver.countRows(table: "customers", schema: nil) == 3)
        let sql = try await BackupEngine.extractSQL(entry, store: store)
        #expect(sql.contains("INSERT INTO \"orders\""))
        // A file copy only goes into SQLite.
        let pg = PostgresDriver(config: ConnectionConfig(kind: .postgresql), password: nil)
        await #expect(throws: BackupError.self) { try await BackupEngine.restore(entry, store: store, into: pg) }
        await driver.disconnect()
    }

    @Test func dropFilterSkipsOnlyGeneratedDrops() {
        let script = "-- Table: t\n\nDROP TABLE IF EXISTS \"t\";\n\nCREATE TABLE t (a int);\n\nDROP VIEW IF EXISTS v;\n\nINSERT INTO t VALUES ('DROP TABLE IF EXISTS x');"
        let kept = BackupEngine.restoreStatements(script, options: RestoreOptions(dropExisting: false))
        #expect(kept.count == 2)
        #expect(kept.allSatisfy { !$0.hasPrefix("DROP") && !$0.contains("-- Table") })
        #expect(BackupEngine.restoreStatements(script, options: RestoreOptions()).count == 4)
    }
}
