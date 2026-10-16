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
