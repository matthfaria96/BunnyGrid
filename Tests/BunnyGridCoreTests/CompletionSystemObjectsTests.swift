import BunnyGridCore
import Testing

struct CompletionSystemObjectsTests {
    @Test func dropsSystemSchemasAndTables() {
        let catalog = CompletionCatalog(
            schemas: ["public", "pg_catalog", "information_schema", "pg_toast"],
            tables: [DatabaseObject(schema: "public", name: "film", kind: .table),
                     DatabaseObject(schema: "pg_catalog", name: "pg_class", kind: .table),
                     DatabaseObject(schema: nil, name: "sqlite_sequence", kind: .table)])
        let user = catalog.withoutSystemObjects()
        #expect(user.schemas == ["public"])
        #expect(user.tables.map(\.name) == ["film"])
    }
}
