import Foundation

extension CompletionCatalog {
    /// Schemas that belong to the server itself rather than the user (Options › Code Completion).
    public static func isSystemSchema(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["pg_catalog", "information_schema", "mysql", "performance_schema", "sys"].contains(n)
            || n.hasPrefix("pg_toast") || n.hasPrefix("pg_temp")
    }

    /// The catalog without system schemas, their objects and SQLite's internal sqlite_* tables.
    public func withoutSystemObjects() -> CompletionCatalog {
        CompletionCatalog(
            schemas: schemas.filter { !Self.isSystemSchema($0) },
            tables: tables.filter { !($0.schema.map(Self.isSystemSchema) ?? false) && !$0.name.lowercased().hasPrefix("sqlite_") },
            columns: columns)
    }
}
