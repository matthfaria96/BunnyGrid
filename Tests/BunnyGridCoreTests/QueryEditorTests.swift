import Foundation
import Testing
@testable import BunnyGridCore

/// Run Current Statement, EXPLAIN per dialect, plan trees, row caps and SQLite interrupt.
@Suite struct QueryEditorTests {
    // MARK: - Statement under the cursor

    private let script = "SELECT 1;\nSELECT 2;\n\n  SELECT 3"

    private func offset(of needle: String, in text: String) -> Int {
        (text as NSString).range(of: needle).location
    }

    @Test func statementRangesAreUTF16Offsets() {
        let text = "SELECT '😀';  UPDATE t SET a = 1 ;"
        let statements = SQLSplitter.statements(in: text)
        #expect(statements.map(\.sql) == ["SELECT '😀'", "UPDATE t SET a = 1"])
        let ns = text as NSString
        #expect(ns.substring(with: NSRange(statements[0].range)) == "SELECT '😀'")
        #expect(ns.substring(with: NSRange(statements[1].range)) == "UPDATE t SET a = 1")
        #expect(statements[0].end == offset(of: ";", in: text) + 1)
        #expect(statements[1].end == ns.length)
    }

    @Test func picksStatementContainingCursor() {
        #expect(SQLSplitter.statement(at: 0, in: script)?.sql == "SELECT 1")
        #expect(SQLSplitter.statement(at: 3, in: script)?.sql == "SELECT 1")
        #expect(SQLSplitter.statement(at: offset(of: "2", in: script), in: script)?.sql == "SELECT 2")
        #expect(SQLSplitter.statement(at: (script as NSString).length, in: script)?.sql == "SELECT 3")
    }

    @Test func cursorJustAfterSemicolonStaysOnThatStatement() {
        let end = offset(of: ";", in: script) + 1
        #expect(SQLSplitter.statement(at: end, in: script)?.sql == "SELECT 1")
    }

    @Test func cursorBeforeStatementOnSameLinePicksIt() {
        // Inside the indentation of "  SELECT 3".
        let indent = offset(of: "  SELECT 3", in: script) + 1
        #expect(SQLSplitter.statement(at: indent, in: script)?.sql == "SELECT 3")
    }

    @Test func cursorOnBlankLinePicksPreviousStatement() {
        let blank = offset(of: "\n\n", in: script) + 1
        #expect(SQLSplitter.statement(at: blank, in: script)?.sql == "SELECT 2")
    }

    @Test func cursorBeforeFirstStatementPicksIt() {
        let text = "-- notes\n\nSELECT 1;"
        #expect(SQLSplitter.statement(at: 0, in: text)?.sql == "-- notes\n\nSELECT 1")
        #expect(SQLSplitter.statement(at: 0, in: "\n\nSELECT 9")?.sql == "SELECT 9")
        #expect(SQLSplitter.statement(at: 0, in: "   ") == nil)
    }

    @Test func semicolonsInsideStringsDontSplitCurrentStatement() {
        let text = "SELECT 'a;b' AS x;\nSELECT 2"
        #expect(SQLSplitter.statement(at: offset(of: "b'", in: text), in: text)?.sql == "SELECT 'a;b' AS x")
    }

    @Test func readOnlyStatements() {
        #expect(SQLSplitter.isReadOnly("  select * from t"))
        #expect(SQLSplitter.isReadOnly("WITH x AS (SELECT 1) SELECT * FROM x"))
        #expect(SQLSplitter.isReadOnly("EXPLAIN SELECT 1"))
        #expect(!SQLSplitter.isReadOnly("DELETE FROM t"))
        #expect(!SQLSplitter.isReadOnly("INSERT INTO t VALUES (1) RETURNING *"))
    }

    // MARK: - EXPLAIN

    @Test func explainSQLPerDialect() {
        #expect(SQLDialect(kind: .sqlite).explain("SELECT * FROM t;") == "EXPLAIN QUERY PLAN SELECT * FROM t")
        #expect(SQLDialect(kind: .postgresql).explain(" SELECT 1 ") == "EXPLAIN (FORMAT JSON) SELECT 1")
        #expect(SQLDialect(kind: .mysql).explain("SELECT 1;;") == "EXPLAIN FORMAT=JSON SELECT 1")
        #expect(SQLDialect(kind: .mariadb).explain("UPDATE t SET a = 1") == "EXPLAIN FORMAT=JSON UPDATE t SET a = 1")
        // Typed by hand: kept as is.
        #expect(SQLDialect(kind: .postgresql).explain("explain analyze SELECT 1") == "explain analyze SELECT 1")
    }

    @Test func parsesSQLitePlanRows() {
        let result = QueryResult(statement: "EXPLAIN QUERY PLAN …", columns: ["id", "parent", "notused", "detail"], rows: [
            [.integer(2), .integer(0), .integer(0), .text("SCAN o")],
            [.integer(5), .integer(0), .integer(0), .text("SEARCH c USING INTEGER PRIMARY KEY (rowid=?)")],
            [.integer(9), .integer(0), .integer(0), .text("CORRELATED SCALAR SUBQUERY 1")],
            [.integer(12), .integer(9), .integer(0), .text("SCAN i")],
        ])
        let plan = QueryPlan.parse(result, kind: .sqlite)
        #expect(plan?.map(\.title) == ["SCAN o", "SEARCH c USING INTEGER PRIMARY KEY (rowid=?)", "CORRELATED SCALAR SUBQUERY 1"])
        #expect(plan?[2].children.map(\.title) == ["SCAN i"])
        #expect(plan?.flatMap { $0.flattened() }.map(\.depth) == [0, 0, 0, 1])
        // Not a plan: no tree.
        #expect(QueryPlan.parse(QueryResult(statement: "", columns: ["a"], rows: []), kind: .sqlite) == nil)
    }

    @Test func parsesPostgresJSONPlan() throws {
        let json = """
        [{"Plan": {"Node Type": "Hash Join", "Parallel Aware": false, "Join Type": "Left", "Startup Cost": 1.07, "Total Cost": 35.5,
          "Plan Rows": 10, "Plan Width": 40, "Hash Cond": "(o.customer_id = c.id)",
          "Plans": [
            {"Node Type": "Seq Scan", "Parent Relationship": "Outer", "Relation Name": "orders", "Schema": "public", "Alias": "o",
             "Startup Cost": 0.00, "Total Cost": 22.7, "Plan Rows": 1270, "Plan Width": 20},
            {"Node Type": "Hash", "Startup Cost": 1.03, "Total Cost": 1.03, "Plan Rows": 3, "Plan Width": 24,
             "Plans": [{"Node Type": "Index Scan", "Relation Name": "customers", "Alias": "customers", "Index Name": "customers_pkey",
                        "Startup Cost": 0.15, "Total Cost": 8.17, "Plan Rows": 1, "Plan Width": 24, "Index Cond": "(id = 1)"}]}
          ]}}]
        """
        let result = QueryResult(statement: "EXPLAIN (FORMAT JSON) …", columns: ["QUERY PLAN"], rows: [[.text(json)]])
        let root = try #require(QueryPlan.parse(result, kind: .postgresql)?.first)
        #expect(root.title == "Hash Join (Left)")
        #expect(root.details.first == .init("cost", "1.07..35.50"))
        #expect(root.details.contains(.init("rows", "10")))
        #expect(root.details.contains(.init("Hash Cond", "(o.customer_id = c.id)")))
        #expect(!root.details.contains { $0.key == "Parallel Aware" })
        #expect(root.children.map(\.title) == ["Seq Scan on public.orders o", "Hash"])
        #expect(root.children[1].children.first?.title == "Index Scan on customers using customers_pkey")
        #expect(root.children[1].children.first?.details.contains(.init("Index Cond", "(id = 1)")) == true)
        #expect(root.flattened().count == 4)
    }

    @Test func parsesMySQLJSONPlan() throws {
        let json = """
        {"query_block": {"select_id": 1, "cost_info": {"query_cost": "4.75"},
          "ordering_operation": {"using_filesort": true,
            "nested_loop": [
              {"table": {"table_name": "o", "access_type": "ALL", "rows_examined_per_scan": 10, "filtered": "100.00",
                         "possible_keys": ["customer_id"], "cost_info": {"read_cost": "1.00", "eval_cost": "1.00"}}},
              {"table": {"table_name": "c", "access_type": "eq_ref", "key": "PRIMARY", "rows_examined_per_scan": 1}}
            ]}}}
        """
        let result = QueryResult(statement: "EXPLAIN FORMAT=JSON …", columns: ["EXPLAIN"], rows: [[.text(json)]])
        let root = try #require(QueryPlan.parse(result, kind: .mysql)?.first)
        #expect(root.title == "Query Block #1")
        #expect(root.details.contains(.init("query_cost", "4.75")))
        let ordering = try #require(root.children.first)
        #expect(ordering.title == "Ordering Operation")
        #expect(ordering.details.contains(.init("using_filesort", "true")))
        #expect(ordering.children.map(\.title) == ["Full Table Scan on o", "Unique Key Lookup on c using PRIMARY"])
        #expect(ordering.children[0].details.contains(.init("possible_keys", "customer_id")))
        #expect(ordering.children[0].details.contains(.init("read_cost", "1.00")))
        #expect(QueryPlan.parse(QueryResult(statement: "", columns: ["EXPLAIN"], rows: [[.text("not json")]]), kind: .mariadb) == nil)
    }

    @Test func sqliteExplainProducesPlanTree() async throws {
        let driver = try await makeSQLite()
        _ = try await driver.execute("""
            CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, total REAL);
            """)
        let sql = driver.dialect.explain("SELECT * FROM orders o JOIN customers c ON c.id = o.customer_id ORDER BY o.total;")
        let result = try await driver.executeTimed(sql)
        let plan = try #require(QueryPlan.parse(result, kind: .sqlite))
        let titles = plan.flatMap { $0.flattened() }.map(\.node.title)
        #expect(titles.contains { $0.hasPrefix("SCAN o") })
        #expect(titles.contains { $0.hasPrefix("SEARCH c") })
        #expect(titles.contains { $0.contains("TEMP B-TREE") })
        await driver.disconnect()
    }

    // MARK: - Row cap

    private func makeSQLite() async throws -> SQLiteDriver {
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: ""))
        try await driver.connect()
        return driver
    }

    @Test func cappedResultStopsAtMaxRows() async throws {
        let driver = try await makeSQLite()
        let series = "WITH RECURSIVE s(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM s WHERE x < 2500) SELECT x FROM s"
        let capped = try await driver.executeTimed(series, maxRows: 1_000)
        #expect(capped.rows.count == 1_000)
        #expect(capped.isTruncated)
        #expect(capped.rows.last == [.integer(1_000)])
        let exact = try await driver.executeStatement("SELECT 1 UNION ALL SELECT 2", maxRows: 2)
        #expect(exact.rows.count == 2)
        #expect(!exact.isTruncated)
        let all = try await driver.executeTimed(series)
        #expect(all.rows.count == 2_500)
        #expect(!all.isTruncated)
        await driver.disconnect()
    }

    @Test func cappedWriteStillRunsToTheEnd() async throws {
        let driver = try await makeSQLite()
        _ = try await driver.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
        let inserted = try await driver.executeStatement("INSERT INTO t (v) VALUES ('a'), ('b'), ('c'), ('d') RETURNING id", maxRows: 2)
        #expect(inserted.rows.count == 2)
        #expect(inserted.isTruncated)
        #expect(try await driver.countRows(table: "t", schema: nil) == 4)
        await driver.disconnect()
    }

    @Test func cappingAResultMarksItTruncated() {
        let result = QueryResult(statement: "", columns: ["a"], rows: [[.integer(1)], [.integer(2)], [.integer(3)]])
        #expect(QueryResult.capped(result, maxRows: 2).rows.count == 2)
        #expect(QueryResult.capped(result, maxRows: 2).isTruncated)
        #expect(!QueryResult.capped(result, maxRows: 3).isTruncated)
        #expect(QueryResult.capped(result, maxRows: nil).rows.count == 3)
    }

    // MARK: - Cancel

    @Test(.timeLimit(.minutes(1)))
    func sqliteInterruptStopsRunningQuery() async throws {
        let driver = try await makeSQLite()
        // Billions of steps: only an interrupt ends this within the time limit.
        let endless = "WITH RECURSIVE s(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM s WHERE x < 5000000000) SELECT count(*) FROM s"
        let running = Task { try await driver.executeStatement(endless) }
        // The interrupt only reaches a statement that already started, so repeat it for a moment.
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            try await driver.cancelCurrentQuery()
        }
        guard case .failure(let error) = await running.result else {
            Issue.record("the query finished instead of being interrupted")
            return
        }
        #expect(error.localizedDescription.lowercased().contains("interrupt"))
        // The connection keeps working afterwards.
        #expect(try await driver.executeStatement("SELECT 42").rows == [[.integer(42)]])
        await driver.disconnect()
    }

    @Test func interruptWhenIdleIsHarmless() async throws {
        let driver = try await makeSQLite()
        try await driver.cancelCurrentQuery()
        #expect(try await driver.executeStatement("SELECT 1").rows == [[.integer(1)]])
        await driver.disconnect()
        // And after disconnecting.
        try await driver.cancelCurrentQuery()
    }
}
