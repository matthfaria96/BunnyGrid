import Foundation
import SQLite3

/// SQLite driver on the system `libsqlite3`. All access goes through the actor,
/// so the raw handle is never touched from two threads at once.
public actor SQLiteDriver: DatabaseDriver {
    public nonisolated let config: ConnectionConfig
    private var db: OpaquePointer?

    public init(config: ConnectionConfig) {
        self.config = config
    }

    public func connect() async throws {
        guard db == nil else { return }
        let path = config.filePath.isEmpty ? ":memory:" : (config.filePath as NSString).expandingTildeInPath
        let flags = config.readOnly
            ? SQLITE_OPEN_READONLY
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "error \(rc)"
            sqlite3_close(handle)
            throw DatabaseError.connectionFailed(message)
        }
        sqlite3_busy_timeout(handle, 5_000)
        db = handle
    }

    public func disconnect() async {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    public func serverVersion() async throws -> String {
        "SQLite " + String(cString: sqlite3_libversion())
    }

    public func listDatabases() async throws -> [String] {
        try await executeStatement("PRAGMA database_list").rows.compactMap { row in
            row.count > 1 ? row[1].displayString : nil
        }
    }

    public func listSchemas() async throws -> [String] { [] }

    public func listObjects(schema: String?) async throws -> [DatabaseObject] {
        let result = try await executeStatement("""
            SELECT name, type FROM sqlite_master
            WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%'
            ORDER BY type, name
            """)
        return result.rows.compactMap { row in
            guard case .text(let name) = row[0], case .text(let type) = row[1] else { return nil }
            return DatabaseObject(schema: nil, name: name, kind: type == "view" ? .view : .table)
        }
    }

    public func listColumns(table: String, schema: String?) async throws -> [TableColumn] {
        let result = try await executeStatement("PRAGMA table_info(\(dialect.quoteIdentifier(table)))")
        // cid, name, type, notnull, dflt_value, pk
        return result.rows.map { row in
            TableColumn(
                name: row[1].displayString,
                dataType: row[2].displayString,
                nullable: row[3] == .integer(0),
                defaultValue: row[4].isNull ? nil : row[4].displayString,
                isPrimaryKey: row[5] != .integer(0),
                ordinal: Int(row[0].displayString) ?? 0
            )
        }
    }

    /// SQLite keeps each object's original CREATE statement in sqlite_master.
    public func objectDDL(name: String, kind: DatabaseObjectKind, schema: String?) async throws -> String {
        let result = try await executeStatement("""
            SELECT sql FROM sqlite_master WHERE tbl_name = \(dialect.quoteLiteral(name)) AND sql IS NOT NULL
            ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'view' THEN 0 ELSE 1 END, name
            """)
        let statements = result.rows.compactMap { row -> String? in
            guard let value = row.first, !value.isNull else { return nil }
            return value.displayString.hasSuffix(";") ? value.displayString : value.displayString + ";"
        }
        return statements.joined(separator: "\n\n")
    }

    public func listForeignKeys(table: String, schema: String?) async throws -> [TableForeignKey] {
        // id, seq, table, from, to, on_update, on_delete, match
        let result = try await executeStatement("PRAGMA foreign_key_list(\(dialect.quoteIdentifier(table)))")
        var keys: [Int: TableForeignKey] = [:]
        var order: [Int] = []
        for row in result.rows where row.count >= 7 {
            guard case .integer(let raw) = row[0] else { continue }
            let id = Int(raw)
            if keys[id] == nil {
                order.append(id)
                keys[id] = TableForeignKey(name: "", columns: [], referencedTable: row[2].displayString, referencedColumns: [],
                                           onDelete: row[6].displayString, onUpdate: row[5].displayString)
            }
            keys[id]?.columns.append(row[3].displayString)
            keys[id]?.referencedColumns.append(row[4].isNull ? "" : row[4].displayString)
        }
        return order.compactMap { keys[$0] }
    }

    public func listTriggers(table: String, schema: String?) async throws -> [TableTrigger] {
        let result = try await executeStatement("""
            SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND tbl_name = \(dialect.quoteLiteral(table)) ORDER BY name
            """)
        return result.rows.map { row in
            let sql = row[1].displayString
            let upper = sql.uppercased()
            let timing = upper.contains(" INSTEAD OF ") ? "INSTEAD OF" : (upper.contains(" BEFORE ") ? "BEFORE" : "AFTER")
            let events = ["INSERT", "UPDATE", "DELETE"].filter { upper.contains(" \($0)") }
            return TableTrigger(name: row[0].displayString, timing: timing, events: events, definition: sql)
        }
    }

    public func listIndexes(table: String, schema: String?) async throws -> [TableIndex] {
        let list = try await executeStatement("PRAGMA index_list(\(dialect.quoteIdentifier(table)))")
        // seq, name, unique, origin, partial
        var indexes: [TableIndex] = []
        for row in list.rows {
            let name = row[1].displayString
            let info = try await executeStatement("PRAGMA index_info(\(dialect.quoteIdentifier(name)))")
            indexes.append(TableIndex(
                name: name,
                columns: info.rows.map { $0[2].displayString },
                unique: row[2] == .integer(1),
                primary: row.count > 3 && row[3] == .text("pk")
            ))
        }
        return indexes
    }

    /// SQLite keeps no row estimates; exact counts are cheap for the small files it usually holds.
    public func tableStatistics(schema: String?) async throws -> [String: TableStatistics] {
        var stats: [String: TableStatistics] = [:]
        for object in try await listObjects(schema: nil) where object.kind == .table {
            let count = try? await executeStatement("SELECT COUNT(*) FROM \(dialect.quoteIdentifier(object.name))").rows.first?.first
            if case .integer(let n) = count { stats[object.name] = TableStatistics(rows: Int(n)) }
        }
        return stats
    }

    public func executeStatement(_ sql: String) async throws -> QueryResult {
        guard let db else { throw DatabaseError.notConnected }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let columnCount = Int(sqlite3_column_count(stmt))
        let columns = (0..<columnCount).map { String(cString: sqlite3_column_name(stmt, Int32($0))) }
        var rows: [[CellValue]] = []

        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            rows.append((0..<columnCount).map { Self.value(stmt, Int32($0)) })
        }

        let affected = columnCount == 0 ? Int(sqlite3_changes(db)) : nil
        return QueryResult(statement: sql, columns: columns, rows: rows, affectedRows: affected)
    }

    private static func value(_ stmt: OpaquePointer, _ index: Int32) -> CellValue {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_NULL:
            return .null
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(stmt, index))
        case SQLITE_FLOAT:
            return .double(sqlite3_column_double(stmt, index))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(stmt, index))
            guard count > 0, let bytes = sqlite3_column_blob(stmt, index) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default:
            guard let text = sqlite3_column_text(stmt, index) else { return .null }
            return .text(String(cString: text))
        }
    }
}
