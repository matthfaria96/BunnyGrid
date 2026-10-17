import Foundation

/// The designer's Auto Increment value: the next id a table hands out (Navicat's Options tab).
/// SQLite keeps the last id of AUTOINCREMENT tables in `sqlite_sequence`; MySQL keeps the next one as the table's AUTO_INCREMENT.
extension SQLDialect {
    /// Statements that make `next` the table's next generated id; empty where the engine has no such counter here.
    public func setAutoIncrement(table: String, schema: String?, next: Int64) -> [String] {
        switch kind {
        case .sqlite:
            let attached = schema.flatMap { $0.isEmpty || $0 == "main" ? nil : $0 }
            let sequence = attached.map { quoteIdentifier($0) + ".sqlite_sequence" } ?? "sqlite_sequence"
            let name = quoteLiteral(table)
            let last = next - 1
            return [
                "UPDATE \(sequence) SET seq = \(last) WHERE name = \(name)",
                "INSERT INTO \(sequence) (name, seq) SELECT \(name), \(last) WHERE NOT EXISTS (SELECT 1 FROM \(sequence) WHERE name = \(name))",
            ]
        case .mysql, .mariadb:
            return ["ALTER TABLE \(qualifiedName(table: table, schema: schema)) AUTO_INCREMENT = \(next)"]
        default:
            return []
        }
    }

    /// Whether the designer offers an Auto Increment value for this engine.
    public var supportsAutoIncrementValue: Bool {
        kind == .sqlite || kind == .mysql || kind == .mariadb
    }

    /// `AUTO_INCREMENT=n` from SHOW CREATE TABLE (which, unlike information_schema in MySQL 8, is never cached).
    static func autoIncrement(inCreateTable ddl: String) -> Int64? {
        ddl.firstMatch(of: /\)[^)]*\bAUTO_INCREMENT=(\d+)/).flatMap { Int64($0.output.1) }
    }
}

extension DatabaseDriver {
    /// The table's next auto-increment id: SQLite's `sqlite_sequence` + 1 (nil when the table has no entry yet, or isn't
    /// AUTOINCREMENT), MySQL's AUTO_INCREMENT (nil for a table without an auto-increment column).
    public func autoIncrementNext(table: String, schema: String?) async -> Int64? {
        let d = dialect
        switch d.kind {
        case .sqlite:
            let attached = schema.flatMap { $0.isEmpty || $0 == "main" ? nil : $0 }
            let sequence = attached.map { d.quoteIdentifier($0) + ".sqlite_sequence" } ?? "sqlite_sequence"
            guard let result = try? await executeStatement("SELECT seq FROM \(sequence) WHERE name = \(d.quoteLiteral(table))"),
                  let value = result.rows.first?.first else { return nil }
            switch value {
            case .integer(let n): return n + 1
            case .text(let s): return Int64(s).map { $0 + 1 }
            default: return nil
            }
        case .mysql, .mariadb:
            guard let result = try? await executeStatement("SHOW CREATE TABLE \(d.qualifiedName(table: table, schema: schema))"),
                  let row = result.rows.first, row.count > 1 else { return nil }
            return SQLDialect.autoIncrement(inCreateTable: row[1].displayString)
        default:
            return nil
        }
    }
}

extension SQLiteTableOptions {
    /// Whether a unique's ON CONFLICT changed (or a new unique has one), which only a table rebuild can apply.
    public static func uniqueConflictsChanged(original: [IndexDesign], design: [IndexDesign]) -> Bool {
        let before = Dictionary(original.compactMap { index in index.originalName.map { ($0, index.onConflict) } }, uniquingKeysWith: { first, _ in first })
        return design.contains { index in
            guard index.unique else { return false }
            guard let name = index.originalName, let old = before[name] else { return index.onConflict != nil }
            return old != index.onConflict
        }
    }
}
