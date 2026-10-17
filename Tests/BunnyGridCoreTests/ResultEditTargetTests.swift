import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct ResultProfilingTests {
    @Test func profilesRowsInMemory() {
        let rows: [[CellValue]] = [[.integer(3), .text("b"), .null, .blob(Data([1]))],
                                   [.integer(1), .text("a"), .text("2024-01-02"), .null],
                                   [.double(2.5), .text("b"), .text("2023-12-31"), .null]]
        let profiles = DataProfiler.profile(columns: ["n", "s", "d", "raw"], types: ["", "", "date", ""], rows: rows)
        #expect(profiles.map(\.name) == ["n", "s", "d", "raw"])
        #expect(profiles[0].total == 3 && profiles[0].nonNull == 3 && profiles[0].distinct == 3)
        #expect(profiles[0].minimum == "1" && profiles[0].maximum == "3" && profiles[0].average == (13.0 / 6).formatted(.number.precision(.fractionLength(0...4))))
        #expect(profiles[1].topValues == [ColumnProfile.TopValue(value: "b", count: 2), ColumnProfile.TopValue(value: "a", count: 1)])
        #expect(profiles[1].average == nil)
        #expect(profiles[2].nonNull == 2 && profiles[2].minimum == "2023-12-31" && profiles[2].maximum == "2024-01-02")
        #expect(profiles[3].note != nil && profiles[3].distinct == nil)
    }
}

@Suite struct ResultEditTargetTests {
    private func target(_ sql: String) -> ResultEditTarget? { try? ResultEditTarget.detect(sql).get() }
    private func refusal(_ sql: String) -> ResultEditTarget.Refusal? {
        if case .failure(let refusal) = ResultEditTarget.detect(sql) { return refusal }
        return nil
    }

    @Test func plainSelects() {
        #expect(target("SELECT * FROM customers") == ResultEditTarget(table: "customers", schema: nil, items: [.star]))
        #expect(target("select c.* from public.customers c where c.id > 3 order by name limit 10;")
                == ResultEditTarget(table: "customers", schema: "public", items: [.star]))
        #expect(target(#"SELECT "id", t.name, name AS name, upper(name), email AS mail, 1 FROM "my schema"."t" AS t"#)
                == ResultEditTarget(table: "t", schema: "my schema", items: [.column("id"), .column("name"), .column("name"), .other, .other, .other]))
        #expect(target("SELECT TOP 10 [id], [v] FROM [dbo].[t]") == ResultEditTarget(table: "t", schema: "dbo", items: [.column("id"), .column("v")]))
        #expect(target("SELECT id FROM db.dbo.t") == ResultEditTarget(table: "t", schema: "dbo", items: [.column("id")]))
        #expect(target("-- note\nSELECT id /* x, y */ FROM `shop`.`orders` WHERE id IN (SELECT id FROM other JOIN x ON 1=1)")
                == ResultEditTarget(table: "orders", schema: "shop", items: [.column("id")]))
        #expect(target("SELECT o.id FROM orders x") == ResultEditTarget(table: "orders", schema: nil, items: [.other]), "unknown qualifier")
    }

    @Test func refusesWhatIsNotOneTable() {
        #expect(refusal("UPDATE t SET a = 1") == .notSelect)
        #expect(refusal("WITH x AS (SELECT 1) SELECT * FROM x") == .notSelect)
        #expect(refusal("SELECT 1") == .notSingleTable)
        #expect(refusal("SELECT * FROM a JOIN b ON a.id = b.id") == .notSingleTable)
        #expect(refusal("SELECT * FROM a LEFT OUTER JOIN b USING (id)") == .notSingleTable)
        #expect(refusal("SELECT * FROM a, b") == .notSingleTable)
        #expect(refusal("SELECT * FROM (SELECT * FROM a) s") == .notSingleTable)
        #expect(refusal("SELECT * FROM generate_series(1, 3)") == .notSingleTable)
        #expect(refusal("SELECT id FROM a UNION SELECT id FROM b") == .notSingleTable)
        #expect(refusal("SELECT DISTINCT name FROM a") == .grouped)
        #expect(refusal("SELECT name, count(*) FROM a GROUP BY name") == .grouped)
        #expect(refusal("SELECT max(id) FROM a") == .grouped)
    }

    @Test func mapsResultColumnsToTableColumns() throws {
        let table = ["id", "name", "email"]
        let star = try #require(target("SELECT * FROM t"))
        #expect(star.sourceColumns(resultColumns: table, tableColumns: table) == ["id", "name", "email"])
        #expect(star.sourceColumns(resultColumns: ["id"], tableColumns: table) == nil, "column count doesn't line up")
        let mixed = try #require(target("SELECT rowid, *, upper(name) FROM t"))
        #expect(mixed.sourceColumns(resultColumns: ["rowid", "id", "name", "email", "upper(name)"], tableColumns: table)
                == [nil, "id", "name", "email", nil])
        let cased = try #require(target("SELECT ID, Name FROM t"))
        #expect(cased.sourceColumns(resultColumns: ["id", "name"], tableColumns: table) == ["id", "name"])
        let duplicate = try #require(target("SELECT id, id FROM t"))
        #expect(duplicate.sourceColumns(resultColumns: ["id", "id:1"], tableColumns: table) == ["id", nil])
    }
}
