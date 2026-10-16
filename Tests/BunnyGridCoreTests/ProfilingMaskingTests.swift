import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct DataProfilerTests {
    @Test func profilesColumnsOnSQLite() async throws {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite))
        try await driver.connect()
        _ = try await driver.execute("""
            CREATE TABLE t (id INTEGER PRIMARY KEY, city TEXT, total REAL, data BLOB);
            INSERT INTO t (city, total) VALUES ('Lisboa', 10), ('Lisboa', 20), ('Porto', 30), (NULL, NULL);
            """)
        let columns = try await driver.listColumns(table: "t", schema: nil)
        let profiles = await DataProfiler.profile(driver: driver, table: "t", schema: nil, columns: columns)
        let city = try #require(profiles.first { $0.name == "city" })
        #expect(city.total == 4)
        #expect(city.nonNull == 3)
        #expect(city.nullCount == 1)
        #expect(city.distinct == 2)
        #expect(city.minimum == "Lisboa" && city.maximum == "Porto")
        #expect(city.topValues.first == ColumnProfile.TopValue(value: "Lisboa", count: 2))
        let total = try #require(profiles.first { $0.name == "total" })
        #expect(total.average == "20")
        let data = try #require(profiles.first { $0.name == "data" })
        #expect(data.note != nil && data.distinct == nil)
    }

    @Test func sqliteTableStatisticsCountRows() async throws {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite))
        try await driver.connect()
        _ = try await driver.execute("CREATE TABLE a (x); INSERT INTO a VALUES (1), (2); CREATE TABLE b (y)")
        let stats = try await driver.tableStatistics(schema: nil)
        #expect(stats["a"]?.rows == 2)
        #expect(stats["b"]?.rows == 0)
    }
}

@Suite struct MaskRuleTests {
    @Test func masksValues() {
        #expect(MaskRule.full.apply(to: .text("secret")) == .text("******"))
        #expect(MaskRule.partial.apply(to: .text("Mariana")) == .text("M*****a"))
        #expect(MaskRule.email.apply(to: .text("ana.silva@example.com")) == .text("a***@example.com"))
        #expect(MaskRule.lastFour.apply(to: .text("4111111111111111")) == .text("********1111"))
        #expect(MaskRule.lastFour.apply(to: .integer(12)) == .text("**"))
        #expect(MaskRule.full.apply(to: .null) == .null)
        #expect(MaskRule.none.apply(to: .text("x")) == .text("x"))
    }

    @Test func profilesRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "bg-profiles-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let profile = TableProfile(connectionID: UUID(), database: "main", schema: nil, table: "t", name: "Paid only",
                                   filter: "status = 'paid'", sortColumn: "total", sortDescending: true,
                                   hiddenColumns: ["notes"], masks: ["email": .email])
        let store = JSONListStore<TableProfile>(fileURL: url)
        try store.save([profile])
        #expect(try store.load() == [profile])
    }
}
