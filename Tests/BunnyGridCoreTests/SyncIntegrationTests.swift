import Foundation
import Testing
@testable import BunnyGridCore

/// Data Transfer and synchronization against PostgreSQL (`BUNNYGRID_PG_PORT`, same variables as PostgresIntegrationTests)
/// and MySQL / MariaDB (`BUNNYGRID_MYSQL_PORT`, same variables as MySQLIntegrationTests).
private enum Servers {
    static let env = ProcessInfo.processInfo.environment
    static let pg = env["BUNNYGRID_PG_PORT"] != nil
    static let mysql = env["BUNNYGRID_MYSQL_PORT"] != nil

    static func postgres() async throws -> PostgresDriver {
        let driver = PostgresDriver(config: ConnectionConfig(kind: .postgresql, host: env["BUNNYGRID_PG_HOST"] ?? "localhost",
                                                             port: Int(env["BUNNYGRID_PG_PORT"] ?? "") ?? 5432,
                                                             username: env["BUNNYGRID_PG_USER"] ?? "postgres",
                                                             database: env["BUNNYGRID_PG_DATABASE"] ?? "postgres"),
                                    password: env["BUNNYGRID_PG_PASSWORD"])
        try await driver.connect()
        return driver
    }

    static func mysql(database: String = "") async throws -> MySQLDriver {
        let kind: DatabaseKind = env["BUNNYGRID_MYSQL_KIND"]?.lowercased() == "mariadb" ? .mariadb : .mysql
        let driver = MySQLDriver(config: ConnectionConfig(kind: kind, host: env["BUNNYGRID_MYSQL_HOST"] ?? "127.0.0.1",
                                                          port: Int(env["BUNNYGRID_MYSQL_PORT"] ?? "") ?? 3306,
                                                          username: env["BUNNYGRID_MYSQL_USER"] ?? "root", database: database, tls: .disable),
                                 password: env["BUNNYGRID_MYSQL_PASSWORD"].flatMap { $0.isEmpty ? nil : $0 })
        try await driver.connect()
        return driver
    }
}

@Suite(.enabled(if: Servers.pg, "set BUNNYGRID_PG_PORT to run against PostgreSQL"), .serialized)
struct PostgresSyncTests {
    private func withSchema(_ body: (PostgresDriver, String) async throws -> Void) async throws {
        let driver = try await Servers.postgres()
        let schema = "bg_sync_\(UUID().uuidString.prefix(8).lowercased())"
        _ = try await driver.executeStatement("CREATE SCHEMA \(schema)")
        do { try await body(driver, schema) } catch {
            _ = try? await driver.executeStatement("DROP SCHEMA \(schema) CASCADE")
            await driver.disconnect()
            throw error
        }
        _ = try? await driver.executeStatement("DROP SCHEMA \(schema) CASCADE")
        await driver.disconnect()
    }

    @Test func sqliteToPostgresAndBack() async throws {
        try await withSchema { pg, schema in
            let source = try await syncSQLite("src")
            try await syncRun(source, syncSampleSchema)
            let summary = try await DataTransfer(source: source, sourceSchema: nil, tables: ["customers", "orders"],
                                                 destination: .database(pg, schema: schema)).run()
            #expect(summary.rows == 5 && summary.errors == 0)
            #expect(try await pg.countRows(table: "orders", schema: schema) == 2)
            // The serial sequence was moved past the copied ids.
            _ = try await pg.executeStatement("INSERT INTO \(schema).customers (name) VALUES ('New')")
            let id = try await pg.executeStatement("SELECT max(id) FROM \(schema).customers").rows.first?.first
            #expect(id == .integer(4))
            let active = try await pg.executeStatement("SELECT active FROM \(schema).customers WHERE id = 1").rows.first?.first
            #expect(active == .bool(true))
            #expect(try await pg.listForeignKeys(table: "orders", schema: schema).count == 1)

            let back = try await syncSQLite("back")
            let again = try await DataTransfer(source: pg, sourceSchema: schema, tables: ["customers", "orders"],
                                               destination: .database(back, schema: nil)).run()
            #expect(again.rows == 6 && again.errors == 0)
            #expect(try await back.countRows(table: "customers", schema: nil) == 4)
        }
    }

    @Test func structureSyncSQLiteToPostgres() async throws {
        try await withSchema { pg, schema in
            let source = try await syncSQLite("src")
            try await syncRun(source, syncSampleSchema)
            _ = try await pg.executeStatement("CREATE TABLE \(schema).customers (id int4 PRIMARY KEY, name text, extra int)")
            _ = try await pg.executeStatement("CREATE TABLE \(schema).gone (x int)")
            let sourceSnapshot = try await SchemaSnapshot.read(from: source, schema: nil)
            let comparison = StructureSync.compare(source: sourceSnapshot, target: try await SchemaSnapshot.read(from: pg, schema: schema))
            #expect(comparison.differences.contains { $0.name == "customers" && $0.action == .alter })
            try await StructureSync.deploy(try comparison.deployScript(), on: pg)
            let after = StructureSync.compare(source: sourceSnapshot, target: try await SchemaSnapshot.read(from: pg, schema: schema))
            #expect(after.differences.isEmpty, "\(after.differences)")
        }
    }

    @Test func structureAndDataSyncPostgresToPostgres() async throws {
        try await withSchema { pg, a in
            try await withSchema { _, b in
                try await syncRun(pg, """
                    CREATE TABLE \(a).items (id serial PRIMARY KEY, name varchar(40) NOT NULL DEFAULT 'x', price numeric(10,2), at timestamp);
                    CREATE INDEX items_name ON \(a).items (name);
                    CREATE VIEW \(a).cheap AS SELECT id, name FROM \(a).items WHERE price < 10;
                    INSERT INTO \(a).items (name, price, at) VALUES ('a', 1.5, '2026-01-01 10:00:00'), ('b', 20, NULL);
                    """)
                let source = try await SchemaSnapshot.read(from: pg, schema: a)
                let script = try StructureSync.compare(source: source, target: try await SchemaSnapshot.read(from: pg, schema: b)).deployScript()
                try await StructureSync.deploy(script, on: pg)
                let after = StructureSync.compare(source: source, target: try await SchemaSnapshot.read(from: pg, schema: b))
                #expect(after.differences.isEmpty, "\(after.differences)")
                _ = try await pg.executeStatement("INSERT INTO \(b).items (id, name, price) VALUES (2, 'old', 3), (5, 'gone', 1)")
                let data = try await DataSync.compare(source: pg, sourceSchema: a, sourceTable: "items", target: pg, targetSchema: b, targetTable: "items")
                #expect(data.count(.insert) == 1 && data.count(.update) == 1 && data.count(.delete) == 1)
                try await DataSync.apply([(data, nil)], to: pg, schema: b)
                let synced = try await DataSync.compare(source: pg, sourceSchema: a, sourceTable: "items", target: pg, targetSchema: b, targetTable: "items")
                #expect(synced.differences.isEmpty)
            }
        }
    }
}

@Suite(.enabled(if: Servers.mysql, "set BUNNYGRID_MYSQL_PORT to run against MySQL/MariaDB"), .serialized)
struct MySQLSyncTests {
    @Test func sqliteToMySQLTransferAndSync() async throws {
        let admin = try await Servers.mysql()
        let db = "bg_sync_\(UUID().uuidString.prefix(8).lowercased())"
        _ = try await admin.executeStatement("CREATE DATABASE \(db)")
        do {
            let my = try await Servers.mysql(database: db)
            let source = try await syncSQLite("src")
            try await syncRun(source, syncSampleSchema)
            let summary = try await DataTransfer(source: source, sourceSchema: nil, tables: ["customers", "orders"],
                                                 destination: .database(my, schema: db)).run()
            #expect(summary.rows == 5 && summary.errors == 0)
            let snapshot = try await SchemaSnapshot.read(from: source, schema: nil)
            let after = StructureSync.compare(source: snapshot, target: try await SchemaSnapshot.read(from: my, schema: db))
            #expect(after.differences.filter { $0.kind == .table }.isEmpty, "\(after.differences)")
            _ = try await my.executeStatement("UPDATE customers SET name = 'X' WHERE id = 2")
            let data = try await DataSync.compare(source: source, sourceSchema: nil, sourceTable: "customers",
                                                  target: my, targetSchema: db, targetTable: "customers")
            #expect(data.count(.update) == 1)
            try await DataSync.apply([(data, nil)], to: my, schema: db)
            await my.disconnect()
        } catch {
            _ = try? await admin.executeStatement("DROP DATABASE \(db)")
            await admin.disconnect()
            throw error
        }
        _ = try? await admin.executeStatement("DROP DATABASE \(db)")
        await admin.disconnect()
    }
}
