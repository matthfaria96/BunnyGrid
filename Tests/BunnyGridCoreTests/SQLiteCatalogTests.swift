import Foundation
import Testing
@testable import BunnyGridCore

/// The bulk catalog reads and the row estimates that keep the model and the Objects list fast on big files.
@Suite struct SQLiteCatalogTests {
    private func makeDriver() async throws -> SQLiteDriver {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: ""))
        try await driver.connect()
        _ = try await driver.execute("""
            CREATE TABLE customers (id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE, name TEXT DEFAULT 'x');
            CREATE TABLE regions (code TEXT, country TEXT, PRIMARY KEY (code, country)) WITHOUT ROWID;
            CREATE TABLE orders (
                id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id) ON DELETE CASCADE,
                region TEXT, country TEXT, total REAL,
                FOREIGN KEY (region, country) REFERENCES regions(code, country));
            CREATE INDEX orders_customer ON orders(customer_id, total);
            CREATE INDEX orders_expr ON orders(total * 2);
            CREATE VIEW big_orders AS SELECT * FROM orders WHERE total > 100;
            INSERT INTO customers (email) VALUES ('a@x'), ('b@x'), ('c@x');
            INSERT INTO regions VALUES ('n', 'br'), ('s', 'br');
            INSERT INTO orders (customer_id, total) VALUES (1, 10), (2, 200);
            """)
        return driver
    }

    @Test func describesEveryTableLikeThePerTableCalls() async throws {
        let driver = try await makeDriver()
        let bulk = try await driver.describeTables(schema: nil)
        #expect(bulk.map(\.object.name) == ["customers", "orders", "regions"])
        for table in bulk {
            #expect(table.columns == (try await driver.listColumns(table: table.object.name, schema: nil)))
            #expect(table.foreignKeys == (try await driver.listForeignKeys(table: table.object.name, schema: nil)))
            #expect(table.indexes == (try await driver.listIndexes(table: table.object.name, schema: nil)))
        }
        let orders = try #require(bulk.first { $0.object.name == "orders" })
        #expect(orders.foreignKeys.count == 2)
        #expect(orders.foreignKeys.contains { $0.columns == ["region", "country"] && $0.referencedColumns == ["code", "country"] })
        #expect(orders.indexes.contains { $0.name == "orders_customer" && $0.columns == ["customer_id", "total"] })
    }

    @Test func reverseEngineersFromTheBulkRead() async throws {
        let driver = try await makeDriver()
        let model = try await ERModel.reverseEngineer(driver: driver, schema: nil)
        #expect(model.tables.map(\.name).sorted() == ["customers", "orders", "regions"])
        #expect(model.relationships.count == 2)
    }

    @Test func bigFilesGetEstimatedRowCounts() async throws {
        let driver = try await makeDriver()
        // Small files are counted exactly.
        let exact = try await driver.tableStatistics(schema: nil)
        #expect(exact["customers"]?.rows == 3)
        #expect(exact["customers"]?.rowsAreEstimated == nil)
        // Above the limit: max(rowid) for rowid tables, nothing for WITHOUT ROWID without statistics.
        _ = try await driver.executeStatement("DELETE FROM customers WHERE id = 2")
        var estimated = try await driver.tableStatistics(schema: nil, exactCountLimit: 0)
        #expect(estimated["customers"]?.rows == 3)
        #expect(estimated["customers"]?.rowsAreEstimated == true)
        #expect(estimated["orders"]?.rows == 2)
        #expect(estimated["regions"]?.rows == nil)
        #expect(estimated["big_orders"]?.rows == nil)
        // After ANALYZE, sqlite_stat1 wins.
        _ = try await driver.executeStatement("ANALYZE")
        estimated = try await driver.tableStatistics(schema: nil, exactCountLimit: 0)
        #expect(estimated["customers"]?.rows == 2)
        #expect(estimated["regions"]?.rows == 2)
        #expect(estimated["regions"]?.rowsAreEstimated == true)
        // The one-table statistics stay exact.
        #expect(try await driver.tableStatistics(schema: nil, table: "customers")?.rows == 2)
    }
}
