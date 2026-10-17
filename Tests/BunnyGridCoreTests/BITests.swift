import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct BITests {
    private let spec = BIAggregateSpec(
        dimensions: [BIDimension(field: "placed_at", bucket: .month), BIDimension(field: "status")],
        measures: [BIMeasure(field: "total", aggregation: .sum), BIMeasure(field: "customer_id", aggregation: .countDistinct)],
        filters: [BIFilter(field: "status", op: .isIn, values: ["paid", "shipped"]), BIFilter(field: "total", op: .greater, values: ["10"], numeric: true)],
        sort: BISort(key: .measure(0), ascending: false),
        limit: 20)

    @Test func aggregationSQLPerDialect() {
        let sqlite = BIQueryBuilder.sql(spec, source: "SELECT * FROM \"orders\"", dialect: SQLDialect(kind: .sqlite))
        #expect(sqlite == """
            SELECT strftime('%Y-%m-01', "placed_at") AS "d0", "status" AS "d1", SUM("total") AS "m0", COUNT(DISTINCT "customer_id") AS "m1" \
            FROM (SELECT * FROM "orders") AS bi_src WHERE "status" IN ('paid', 'shipped') AND "total" > 10 \
            GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 20
            """)
        let pg = BIQueryBuilder.sql(spec, source: "SELECT * FROM \"orders\"", dialect: SQLDialect(kind: .postgresql))
        #expect(pg.hasPrefix("SELECT to_char(date_trunc('month', CAST(\"placed_at\" AS timestamp)), 'YYYY-MM-DD') AS \"d0\""))
        #expect(pg.contains("GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 20"))
        let mysql = BIQueryBuilder.sql(spec, source: "SELECT * FROM `orders`", dialect: SQLDialect(kind: .mysql))
        #expect(mysql.hasPrefix("SELECT DATE_FORMAT(`placed_at`, '%Y-%m-01') AS `d0`, `status` AS `d1`, SUM(`total`) AS `m0`"))
        #expect(mysql.contains("WHERE `status` IN ('paid', 'shipped') AND `total` > 10"))
    }

    @Test func dateBucketsPerDialect() {
        let sqlite = SQLDialect(kind: .sqlite), pg = SQLDialect(kind: .postgresql), my = SQLDialect(kind: .mariadb)
        #expect(sqlite.dateBucket("d", .year) == "strftime('%Y-01-01', d)")
        #expect(sqlite.dateBucket("d", .quarter).contains("/ 3) * 3 + 1"))
        #expect(pg.dateBucket("d", .week) == "to_char(date_trunc('week', CAST(d AS timestamp)), 'YYYY-MM-DD')")
        #expect(my.dateBucket("d", .quarter) == "CONCAT(YEAR(d), '-', LPAD((QUARTER(d) - 1) * 3 + 1, 2, '0'), '-01')")
        #expect(pg.aggregate(BIMeasure(field: "x", aggregation: .avg)) == "AVG(CAST(\"x\" AS double precision))")
        #expect(sqlite.aggregate(BIMeasure(field: nil, aggregation: .sum)) == "COUNT(*)")
    }

    @Test func filterConditions() {
        let d = SQLDialect(kind: .postgresql)
        #expect(BIQueryBuilder.condition(BIFilter(field: "n", op: .notIn, values: ["a"]), d) == "(\"n\" IS NULL OR \"n\" NOT IN ('a'))")
        #expect(BIQueryBuilder.condition(BIFilter(field: "n", op: .contains, values: ["o'k"]), d) == "CAST(\"n\" AS text) ILIKE '%o''k%'")
        #expect(BIQueryBuilder.condition(BIFilter(field: "d", op: .between, values: ["2025-01-01", "2025-12-31"]), d)
                == "\"d\" BETWEEN '2025-01-01' AND '2025-12-31'")
    }

    private var rows: QueryResult {
        QueryResult(statement: "", columns: ["placed_at", "status", "total", "customer_id"], rows: [
            [.text("2025-01-03"), .text("paid"), .double(10), .integer(1)],
            [.text("2025-01-20 10:00:00"), .text("paid"), .double(30), .integer(2)],
            [.text("2025-02-01"), .text("shipped"), .double(5), .integer(1)],
            [.text("2025-02-14"), .text("paid"), .double(100), .integer(1)],
            [.text("2025-02-15"), .text("pending"), .double(1000), .integer(3)],
            [.null, .text("paid"), .null, .integer(3)],
        ])
    }

    @Test func inMemoryAggregation() {
        let spec = BIAggregateSpec(
            dimensions: [BIDimension(field: "placed_at", bucket: .month)],
            measures: [BIMeasure(field: "total", aggregation: .sum), BIMeasure(field: "customer_id", aggregation: .countDistinct),
                       BIMeasure(field: "total", aggregation: .avg), BIMeasure(field: nil, aggregation: .count)],
            filters: [BIFilter(field: "status", op: .notIn, values: ["pending"])],
            sort: BISort(key: .dimension(0), ascending: true))
        let result = BIAggregator.aggregate(rows, spec: spec)
        #expect(result.rows.map(\.keys) == [["(Null)"], ["2025-01-01"], ["2025-02-01"]])
        #expect(result.rows[1].values == [40, 2, 20, 2])
        #expect(result.rows[2].values == [105, 1, 52.5, 2])
        #expect(result.rows[0].values == [nil, 1, nil, 1])
    }

    @Test func inMemorySortLimitAndNumericFilter() {
        let spec = BIAggregateSpec(dimensions: [BIDimension(field: "status")], measures: [BIMeasure(field: "total", aggregation: .max)],
                                   filters: [BIFilter(field: "total", op: .greaterOrEqual, values: ["10"], numeric: true)],
                                   sort: BISort(key: .measure(0), ascending: false), limit: 1)
        let result = BIAggregator.aggregate(rows, spec: spec)
        #expect(result.rows == [BIResult.Row(keys: ["pending"], values: [1000])])
        let total = BIAggregator.aggregate(rows, spec: BIAggregateSpec(measures: [BIMeasure(field: "total", aggregation: .min)]))
        #expect(total.rows == [BIResult.Row(keys: [], values: [5])])
    }

    @Test func weekBucketStartsMonday() {
        #expect(BIValue.bucket(.text("2026-10-18"), .week) == "2026-10-12") // Sunday
        #expect(BIValue.bucket(.text("2026-10-12"), .week) == "2026-10-12")
        #expect(BIValue.bucket(.text("2026-11-30"), .quarter) == "2026-10-01")
    }

    @Test func fieldInference() {
        let fields = BIFieldInference.fields(rows)
        #expect(fields.map(\.type) == [.date, .text, .number, .number])
        #expect(fields.map(\.role) == [.dimension, .dimension, .measure, .dimension])
    }

    @Test func pushdownMatchesInMemoryOnSQLite() async throws {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: ""))
        try await driver.connect()
        _ = try await driver.execute("""
            CREATE TABLE orders (placed_at TEXT, status TEXT, total REAL, customer_id INTEGER);
            INSERT INTO orders VALUES ('2025-01-03','paid',10,1), ('2025-01-20 10:00:00','paid',30,2), ('2025-02-01','shipped',5,1),
              ('2025-02-14','paid',100,1), ('2025-02-15','pending',1000,3), (NULL,'paid',NULL,3), ('2025-10-18','paid',1,4);
            """)
        let source = BIDataSource(name: "orders", connectionID: UUID(), database: "main", table: "orders")
        for bucket in BIDateBucket.allCases {
            let spec = BIAggregateSpec(dimensions: [BIDimension(field: "placed_at", bucket: bucket)],
                                       measures: [BIMeasure(field: "total", aggregation: .sum), BIMeasure(field: nil, aggregation: .count)],
                                       sort: BISort(key: .dimension(0), ascending: true))
            let pushed = try await BIEngine.run(spec, source: source, driver: driver)
            #expect(pushed.statement != nil)
            let all = try await driver.executeStatement("SELECT * FROM orders")
            let memory = BIAggregator.aggregate(all, spec: spec)
            #expect(pushed.rows.filter { $0.keys != ["(Null)"] } == memory.rows.filter { $0.keys != ["(Null)"] }, "bucket \(bucket)")
        }
        let fields = try await BIEngine.fields(for: source, driver: driver)
        #expect(fields.first?.type == .date)
        #expect(try await BIEngine.distinctValues(field: "status", source: source, driver: driver).first == "paid")
    }

    @Test func dashboardSlotsAndStore() throws {
        let chart = UUID()
        var board = BIDashboard(name: "D", items: [BIDashboardItem(chartID: chart, x: 0, y: 0, width: 6, height: 4)])
        #expect(board.nextSlot(width: 6, height: 4) == (6, 0))
        board.items.append(BIDashboardItem(chartID: chart, x: 6, y: 0, width: 6, height: 4))
        #expect(board.nextSlot(width: 4, height: 3) == (0, 4))

        let url = FileManager.default.temporaryDirectory.appending(path: "bi-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = BIWorkspaceStore(fileURL: url)
        let workspace = BIWorkspace(name: "W", charts: [BIChart(name: "C", sourceID: nil, type: .donut)], dashboards: [board])
        try store.upsert(workspace)
        #expect(store.load() == [workspace])
        try store.delete(workspace.id)
        #expect(store.load().isEmpty)
    }

    @Test func chartSpecCapsPoints() {
        let chart = BIChart(name: "P", sourceID: nil, type: .pie, dimensions: [BIDimension(field: "status")], topN: 100)
        let spec = chart.spec(extraFilters: [BIFilter(field: "status", op: .isIn, values: [])])
        #expect(spec.limit == 12)
        #expect(spec.filters.isEmpty)
        #expect(spec.measures == [BIMeasure(field: nil, aggregation: .count)])
        #expect(spec.sort == BISort(key: .measure(0), ascending: false))
    }
}
