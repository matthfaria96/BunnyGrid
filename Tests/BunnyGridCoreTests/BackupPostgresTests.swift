import Foundation
import Testing
@testable import BunnyGridCore

/// Backup and restore against a real PostgreSQL server (`BUNNYGRID_PG_PORT`, same variables as PostgresIntegrationTests).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BUNNYGRID_PG_PORT"] != nil, "set BUNNYGRID_PG_PORT"), .serialized)
struct BackupPostgresTests {
    private let env = ProcessInfo.processInfo.environment

    private func config(database: String? = nil) -> ConnectionConfig {
        ConnectionConfig(name: "PG", kind: .postgresql, host: env["BUNNYGRID_PG_HOST"] ?? "localhost",
                         port: Int(env["BUNNYGRID_PG_PORT"] ?? "") ?? 5432, username: env["BUNNYGRID_PG_USER"] ?? "postgres",
                         database: database ?? env["BUNNYGRID_PG_DATABASE"] ?? "postgres")
    }

    private func connect(_ config: ConnectionConfig) async throws -> PostgresDriver {
        let driver = PostgresDriver(config: config, password: env["BUNNYGRID_PG_PASSWORD"])
        try await driver.connect()
        return driver
    }

    @Test func backupRestoreSchemaIntoSameAndOtherDatabase() async throws {
        let base = config()
        let driver = try await connect(base)
        let schema = "bgb_\(UUID().uuidString.prefix(8).lowercased())"
        let otherDB = "bgb_restore_\(UUID().uuidString.prefix(8).lowercased())"
        _ = try await driver.execute("""
            CREATE SCHEMA \(schema);
            CREATE TABLE \(schema).customers (id serial PRIMARY KEY, name text NOT NULL, born date);
            CREATE TABLE \(schema).orders (id serial PRIMARY KEY, customer_id int REFERENCES \(schema).customers(id), total numeric(8,2));
            CREATE VIEW \(schema).totals AS SELECT customer_id, sum(total) AS total FROM \(schema).orders GROUP BY customer_id;
            INSERT INTO \(schema).customers (name, born) VALUES ('Ana', '1990-01-02'), ('Bia', NULL);
            INSERT INTO \(schema).orders (customer_id, total) VALUES (1, 10.5), (1, 4), (2, 99.99);
            """)
        let dir = FileManager.default.temporaryDirectory.appending(path: "bunnygrid-pgbackup-\(UUID().uuidString.prefix(8))")
        let store = BackupStore(directory: dir)
        do {
            let entry = try await BackupEngine.create(from: driver, connection: base, database: base.database, schema: schema,
                                                      options: BackupOptions(comment: "pg"), store: store)
            #expect(entry.manifest.schema == schema)
            #expect(entry.manifest.objects.count == 3)
            #expect(entry.manifest.rowCount == 5)

            _ = try await driver.execute("DELETE FROM \(schema).orders; DROP VIEW \(schema).totals;")
            let report = try await BackupEngine.restore(entry, store: store, into: driver, options: RestoreOptions(useTransaction: true))
            #expect(report.errors.isEmpty, "\(report.errors)")
            #expect(try await driver.countRows(table: "orders", schema: schema) == 3)
            #expect(try await driver.countRows(table: "totals", schema: schema) == 2)
            // The serial keeps counting after the restored rows.
            let next = try await driver.execute("INSERT INTO \(schema).orders (customer_id, total) VALUES (2, 1) RETURNING id").first?.rows
            #expect(next == [[.integer(4)]])

            _ = try await driver.executeStatement("CREATE DATABASE \(otherDB)")
            let other = try await connect(config(database: otherDB))
            let copied = try await BackupEngine.restore(entry, store: store, into: other)
            #expect(copied.errors.isEmpty, "\(copied.errors)")
            #expect(try await other.countRows(table: "customers", schema: schema) == 2)
            await other.disconnect()
        } catch {
            Issue.record(error)
        }
        _ = try? await driver.executeStatement("DROP SCHEMA \(schema) CASCADE")
        _ = try? await driver.executeStatement("DROP DATABASE IF EXISTS \(otherDB)")
        await driver.disconnect()
    }
}
