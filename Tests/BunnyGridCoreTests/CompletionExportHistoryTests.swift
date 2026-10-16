import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct SQLCompletionTests {
    let catalog = CompletionCatalog(
        schemas: ["public", "sales"],
        tables: [
            DatabaseObject(schema: "public", name: "users", kind: .table),
            DatabaseObject(schema: "sales", name: "orders", kind: .table),
            DatabaseObject(schema: "public", name: "fn", kind: .routine),
        ],
        columns: ["users": ["id", "name", "email"], "orders": ["id", "user_id", "total"]]
    )

    @Test func findsTablesAndAliases() {
        let refs = SQLCompletion.tableReferences(in: """
            SELECT * FROM public.users u JOIN "sales"."orders" AS o ON o.user_id = u.id WHERE u.id > 1
            """)
        #expect(refs == [
            .init(schema: "public", table: "users", alias: "u"),
            .init(schema: "sales", table: "orders", alias: "o"),
        ])
    }

    @Test func keywordsAreNotAliases() {
        let refs = SQLCompletion.tableReferences(in: "SELECT * FROM users WHERE id = 1")
        #expect(refs == [.init(schema: nil, table: "users", alias: nil)])
    }

    @Test func completesColumnsAfterAlias() {
        let sql = "SELECT o. FROM orders o"
        #expect(SQLCompletion.suggestions(prefix: "", qualifier: "o", sql: sql, catalog: catalog) == ["id", "user_id", "total"])
        #expect(SQLCompletion.suggestions(prefix: "us", qualifier: "o", sql: sql, catalog: catalog) == ["user_id"])
    }

    @Test func completesTablesAfterSchema() {
        #expect(SQLCompletion.suggestions(prefix: "", qualifier: "sales", sql: "SELECT * FROM sales.", catalog: catalog) == ["orders"])
    }

    @Test func unqualifiedListsColumnsThenTablesThenKeywords() {
        let results = SQLCompletion.suggestions(prefix: "e", qualifier: nil, sql: "SELECT e FROM users", catalog: catalog)
        #expect(results.first == "email")
        #expect(results.contains("END"))
        #expect(!results.contains("fn"))
        let ordered = SQLCompletion.suggestions(prefix: "or", qualifier: nil, sql: "SELECT 1", catalog: catalog)
        #expect(ordered == ["orders", "OR", "ORDER"])
    }
}

@Suite struct ResultExporterTests {
    let columns = ["id", "note", "blob"]
    let rows: [[CellValue]] = [
        [.integer(1), .text("plain"), .null],
        [.integer(2), .text("a, \"quoted\"\nline"), .blob(Data([1, 255]))],
    ]

    @Test func csvQuotesAndEscapes() {
        #expect(ResultExporter.csv(columns: columns, rows: rows)
            == "id,note,blob\r\n1,plain,\r\n2,\"a, \"\"quoted\"\"\nline\",01ff\r\n")
    }

    @Test func jsonUsesNativeTypes() throws {
        let data = try ResultExporter.json(columns: columns, rows: rows)
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(decoded.count == 2)
        #expect(decoded[0]["id"] as? Int == 1)
        #expect(decoded[0]["blob"] is NSNull)
        #expect(decoded[1]["blob"] as? String == "Af8=")
    }
}

@Suite struct QueryHistoryStoreTests {
    @Test func dedupesAndCaps() {
        let store = QueryHistoryStore(fileURL: URL(fileURLWithPath: "/dev/null"), limit: 3)
        let connection = UUID()
        var entries: [QueryHistoryEntry] = []
        for sql in ["SELECT 1", "SELECT 2", "SELECT 1 ", "SELECT 3", "SELECT 4"] {
            entries = store.adding(QueryHistoryEntry(connectionID: connection, sql: sql, durationMilliseconds: 1), to: entries)
        }
        #expect(entries.map(\.sql) == ["SELECT 4", "SELECT 3", "SELECT 1 "])
    }

    @Test func roundTripsThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "bg-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = QueryHistoryStore(fileURL: url)
        let entry = QueryHistoryEntry(connectionID: UUID(), sql: "SELECT 1", durationMilliseconds: 2.5, rowCount: 1)
        try store.save([entry])
        let loaded = try store.load()
        #expect(loaded.map(\.sql) == ["SELECT 1"])
        #expect(loaded.first?.rowCount == 1)
    }
}
