import Foundation
import SQLite3

/// SQLite driver on the system `libsqlite3`. All access goes through the actor,
/// so the raw handle is never touched from two threads at once.
public actor SQLiteDriver: DatabaseDriver {
    public nonisolated let config: ConnectionConfig
    private var db: OpaquePointer?
    /// The handle again, for `sqlite3_interrupt` from outside the actor while a statement runs on it.
    private nonisolated let interruptHandle = InterruptHandle()

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
        openedPath = path == ":memory:" ? nil : path
        fileIdentity = openedPath.flatMap(Self.identity)
        interruptHandle.set(handle)
        // The connection's Databases tab: every connection (editor, transaction) sees the same files.
        for database in config.attachedDatabases ?? [] where !database.alias.isEmpty && !database.path.isEmpty {
            do {
                try await attach(path: database.path, as: database.alias)
            } catch {
                await disconnect()
                throw DatabaseError.connectionFailed("Could not attach \(database.path) as \(database.alias): \(error.localizedDescription)")
            }
        }
    }

    /// The file the handle was opened on and its device/inode then, to notice it being moved, deleted or replaced.
    private var openedPath: String?
    private var fileIdentity: FileIdentity?
    struct FileIdentity: Equatable { var device: UInt64; var inode: UInt64 }

    static func identity(_ path: String) -> FileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    /// The open handle, checked against the file on disk first: writing through a handle whose file was moved
    /// or replaced would go to the wrong file (and its journal to the old path). A replaced file is reopened;
    /// a missing one fails with `connectionLost` until it is back.
    private func liveHandle() async throws -> OpaquePointer {
        if db == nil, let lostPath {
            guard Self.identity(lostPath) != nil else {
                throw DatabaseError.connectionLost("the database file was moved or deleted: \(lostPath)")
            }
            try await connect()
            self.lostPath = nil
        }
        guard let db else { throw DatabaseError.notConnected }
        guard let openedPath, let fileIdentity else { return db }
        let current = Self.identity(openedPath)
        if current == fileIdentity { return db }
        await disconnect()
        guard current != nil else {
            lostPath = openedPath
            throw DatabaseError.connectionLost("the database file was moved or deleted: \(openedPath)")
        }
        try await connect()
        if inTransaction {
            inTransaction = false
            throw DatabaseError.connectionLost("the database file was replaced during a transaction; nothing in it was saved")
        }
        guard let db = self.db else { throw DatabaseError.notConnected }
        return db
    }
    /// Set while the file is missing: the next call reopens it once it is back.
    private var lostPath: String?
    /// An open transaction on the handle (see `TransactionState`).
    public private(set) var inTransaction = false

    public func disconnect() async {
        interruptHandle.set(nil)
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    /// Statements run synchronously inside the actor, so the interrupt can't wait for it: it goes
    /// straight to the handle (`sqlite3_interrupt` is safe from any thread while the connection is open).
    public nonisolated func cancelCurrentQuery() async throws {
        interruptHandle.interrupt()
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

    /// Attaches another database file under `alias` (Navicat's "Attach Database…"); it then shows up in
    /// `listDatabases()` and its objects are listed with `alias` as their schema.
    public func attach(path: String, as alias: String) async throws {
        let file = (path as NSString).expandingTildeInPath
        _ = try await executeStatement("ATTACH DATABASE \(dialect.quoteLiteral(file)) AS \(dialect.quoteIdentifier(alias))")
    }

    public func detach(_ alias: String) async throws {
        _ = try await executeStatement("DETACH DATABASE \(dialect.quoteIdentifier(alias))")
    }

    /// `main.sqlite_master`, or the attached database's catalog.
    private func master(_ schema: String?) -> String {
        guard let schema, !schema.isEmpty, schema != "main" else { return "sqlite_master" }
        return dialect.quoteIdentifier(schema) + ".sqlite_master"
    }

    private func attachedSchema(_ schema: String?) -> String? {
        guard let schema, !schema.isEmpty, schema != "main" else { return nil }
        return schema
    }

    public func listObjects(schema: String?) async throws -> [DatabaseObject] {
        let result = try await executeStatement("""
            SELECT name, type FROM \(master(schema))
            WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%'
            ORDER BY type, name
            """)
        let owner = attachedSchema(schema)
        return result.rows.compactMap { row in
            guard case .text(let name) = row[0], case .text(let type) = row[1] else { return nil }
            return DatabaseObject(schema: owner, name: name, kind: type == "view" ? .view : .table)
        }
    }

    public func listColumns(table: String, schema: String?) async throws -> [TableColumn] {
        let prefix = attachedSchema(schema).map { dialect.quoteIdentifier($0) + "." } ?? ""
        let result = try await executeStatement("PRAGMA \(prefix)table_info(\(dialect.quoteIdentifier(table)))")
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
            SELECT sql FROM \(master(schema)) WHERE tbl_name = \(dialect.quoteLiteral(name)) AND sql IS NOT NULL
            ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'view' THEN 0 ELSE 1 END, name
            """)
        let statements = result.rows.compactMap { row -> String? in
            guard let value = row.first, !value.isNull else { return nil }
            return value.displayString.hasSuffix(";") ? value.displayString : value.displayString + ";"
        }
        return statements.joined(separator: "\n\n")
    }

    /// Files above this size get estimated row counts in the Objects list instead of a COUNT(*) per table
    /// (counting a 1M-row table in an 800 MB file reads most of it: seconds on a cold cache).
    public static let exactRowCountByteLimit = 64 << 20

    /// Root page, indexes and triggers per table and view, from sqlite_master, plus row counts: exact (COUNT(*)
    /// on a second connection) for files up to `exactRowCountByteLimit`; on bigger files, estimates marked
    /// `rowsAreEstimated` from `sqlite_stat1` (written by ANALYZE) or else the largest rowid, both instant.
    /// The exact count of one table stays available from `tableStatistics(schema:table:)` and `countRows`.
    public func tableStatistics(schema: String?) async throws -> [String: TableStatistics] {
        try await tableStatistics(schema: schema, exactCountLimit: Self.exactRowCountByteLimit)
    }

    func tableStatistics(schema: String?, exactCountLimit: Int) async throws -> [String: TableStatistics] {
        let result = try await executeStatement("""
            SELECT o.name, o.rootpage,
                   (SELECT COUNT(*) FROM \(master(schema)) i WHERE i.type = 'index' AND i.tbl_name = o.name),
                   (SELECT COUNT(*) FROM \(master(schema)) t WHERE t.type = 'trigger' AND t.tbl_name = o.name)
              FROM \(master(schema)) o WHERE o.type IN ('table', 'view')
            """)
        var stats: [String: TableStatistics] = [:]
        for row in result.rows where row.count == 4 {
            func int(_ value: CellValue) -> Int? { if case .integer(let v) = value { Int(v) } else { nil } }
            var entry = TableStatistics()
            entry.rootPage = int(row[1]).flatMap { $0 > 0 ? $0 : nil }
            entry.hasIndexes = (int(row[2]) ?? 0) > 0
            entry.hasTriggers = (int(row[3]) ?? 0) > 0
            stats[row[0].displayString] = entry
        }
        let tables = try await listObjects(schema: schema).filter { $0.kind == .table }
        if try await databaseBytes(schema: schema) > exactCountLimit {
            for (name, rows) in try await estimatedRowCounts(tables.map(\.name), schema: schema) {
                stats[name, default: TableStatistics()].rows = rows
                stats[name]?.rowsAreEstimated = true
            }
            return stats
        }
        if let counts = await countRowsElsewhere(tables.map(\.name), schema: schema) {
            for (name, count) in counts { stats[name, default: TableStatistics()].rows = count }
            return stats
        }
        for object in tables {
            let count = try? await executeStatement("SELECT COUNT(*) FROM \(dialect.qualifiedName(table: object.name, schema: object.schema))").rows.first?.first
            if case .integer(let n) = count { stats[object.name, default: TableStatistics()].rows = Int(n) }
        }
        return stats
    }

    /// page_count × page_size of the main file or an attached schema.
    private func databaseBytes(schema: String?) async throws -> Int {
        let prefix = attachedSchema(schema).map { dialect.quoteIdentifier($0) + "." } ?? ""
        func value(_ pragma: String) async throws -> Int {
            if case .integer(let n) = try await executeStatement("PRAGMA \(prefix)\(pragma)").rows.first?.first { return Int(n) }
            return 0
        }
        return try await value("page_count") * value("page_size")
    }

    /// Row estimates without scanning: the first number of each `sqlite_stat1` entry (rows in the table or index,
    /// as of the last ANALYZE), else `max(rowid)` (exact for tables that are only appended to). WITHOUT ROWID
    /// tables with no statistics get none.
    func estimatedRowCounts(_ tables: [String], schema: String?) async throws -> [String: Int] {
        var estimates: [String: Int] = [:]
        let prefix = attachedSchema(schema).map { dialect.quoteIdentifier($0) + "." } ?? ""
        let hasStat1 = try await executeStatement("SELECT 1 FROM \(master(schema)) WHERE type = 'table' AND name = 'sqlite_stat1'").rows.isEmpty == false
        if hasStat1, let rows = try? await executeStatement("SELECT tbl, stat FROM \(prefix)sqlite_stat1").rows {
            for row in rows where row.count == 2 {
                guard let first = row[1].displayString.split(separator: " ").first, let count = Int(first) else { continue }
                estimates[row[0].displayString] = max(estimates[row[0].displayString] ?? 0, count)
            }
        }
        for table in tables where estimates[table] == nil {
            if case .integer(let n) = try? await executeStatement("SELECT max(rowid) FROM \(dialect.qualifiedName(table: table, schema: attachedSchema(schema)))").rows.first?.first {
                estimates[table] = Int(n)
            } else if (try? await executeStatement("SELECT 1 FROM \(dialect.qualifiedName(table: table, schema: attachedSchema(schema))) LIMIT 1").rows.isEmpty) == true {
                estimates[table] = 0
            }
        }
        return estimates.filter { tables.contains($0.key) }
    }

    /// Exact row counts read on a second, read-only connection away from the actor. Counting a large table
    /// (or thousands of small ones) takes a while; while it is awaited the actor is free, so opening a table
    /// or running a query doesn't wait behind it. nil for in-memory databases and attached schemas.
    private func countRowsElsewhere(_ tables: [String], schema: String?) async -> [String: Int]? {
        guard !config.filePath.isEmpty, attachedSchema(schema) == nil, db != nil else { return nil }
        let path = (config.filePath as NSString).expandingTildeInPath
        let statements = tables.map { ($0, "SELECT COUNT(*) FROM \(dialect.quoteIdentifier($0))") }
        return await Task.detached(priority: .utility) { () -> [String: Int]? in
            var handle: OpaquePointer?
            guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let handle else {
                sqlite3_close(handle)
                return nil
            }
            defer { sqlite3_close_v2(handle) }
            sqlite3_busy_timeout(handle, 2_000)
            var counts: [String: Int] = [:]
            for (table, sql) in statements {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { continue }
                if sqlite3_step(statement) == SQLITE_ROW { counts[table] = Int(sqlite3_column_int64(statement, 0)) }
                sqlite3_finalize(statement)
            }
            return counts
        }.value
    }

    /// One table's entry without counting the rows of every other table (the full version runs a
    /// COUNT(*) per table: thousands of statements on a large schema, holding the connection meanwhile).
    public func tableStatistics(schema: String?, table: String) async throws -> TableStatistics? {
        let name = dialect.quoteLiteral(table)
        let result = try await executeStatement("""
            SELECT o.type, o.rootpage,
                   (SELECT COUNT(*) FROM \(master(schema)) i WHERE i.type = 'index' AND i.tbl_name = o.name),
                   (SELECT COUNT(*) FROM \(master(schema)) t WHERE t.type = 'trigger' AND t.tbl_name = o.name)
              FROM \(master(schema)) o WHERE o.type IN ('table', 'view') AND o.name = \(name)
            """)
        guard let row = result.rows.first, row.count == 4 else { return nil }
        func int(_ value: CellValue) -> Int? { if case .integer(let v) = value { Int(v) } else { nil } }
        var entry = TableStatistics()
        entry.rootPage = int(row[1]).flatMap { $0 > 0 ? $0 : nil }
        entry.hasIndexes = (int(row[2]) ?? 0) > 0
        entry.hasTriggers = (int(row[3]) ?? 0) > 0
        guard row[0].displayString == "table" else { return entry }
        if let counts = await countRowsElsewhere([table], schema: schema) {
            entry.rows = counts[table]
        } else if case .integer(let n) = try? await executeStatement("SELECT COUNT(*) FROM \(dialect.qualifiedName(table: table, schema: schema))").rows.first?.first {
            entry.rows = Int(n)
        }
        return entry
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

    /// Every table's columns, foreign keys and indexes in four statements (the pragma table-valued functions
    /// joined with sqlite_master), instead of three or more PRAGMAs per table.
    public func describeTables(schema: String?) async throws -> [TableDescription] {
        let objects = try await listObjects(schema: schema).filter { $0.kind == .table }
        guard !objects.isEmpty else { return [] }
        let owner = dialect.quoteLiteral(attachedSchema(schema) ?? "main")
        let tables = "SELECT name FROM \(master(schema)) WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        // cid, name, type, notnull, dflt_value, pk
        let columnRows = try await executeStatement("""
            SELECT m.name, p.cid, p.name, p.type, p."notnull", p.dflt_value, p.pk
              FROM (\(tables)) m JOIN pragma_table_info(m.name, \(owner)) p ORDER BY m.name, p.cid
            """).rows
        // id, seq, table, from, to, on_update, on_delete
        let keyRows = try await executeStatement("""
            SELECT m.name, f.id, f.seq, f."table", f."from", f."to", f.on_update, f.on_delete
              FROM (\(tables)) m JOIN pragma_foreign_key_list(m.name, \(owner)) f ORDER BY m.name, f.id, f.seq
            """).rows
        let indexRows = try await executeStatement("""
            SELECT m.name, l.seq, l.name, l."unique", l.origin, i.seqno, i.name
              FROM (\(tables)) m JOIN pragma_index_list(m.name, \(owner)) l
              LEFT JOIN pragma_index_info(l.name, \(owner)) i ORDER BY m.name, l.seq, i.seqno
            """).rows
        var columns: [String: [TableColumn]] = [:]
        for row in columnRows where row.count == 7 {
            columns[row[0].displayString, default: []].append(TableColumn(
                name: row[2].displayString,
                dataType: row[3].displayString,
                nullable: row[4] == .integer(0),
                defaultValue: row[5].isNull ? nil : row[5].displayString,
                isPrimaryKey: row[6] != .integer(0),
                ordinal: Int(row[1].displayString) ?? 0))
        }
        var keys: [String: [TableForeignKey]] = [:]
        var lastKey: (table: String, id: CellValue)?
        for row in keyRows where row.count == 8 {
            let table = row[0].displayString
            if lastKey?.table != table || lastKey?.id != row[1] {
                keys[table, default: []].append(TableForeignKey(name: "", columns: [], referencedTable: row[3].displayString, referencedColumns: [],
                                                                onDelete: row[7].displayString, onUpdate: row[6].displayString))
                lastKey = (table, row[1])
            }
            keys[table]![keys[table]!.count - 1].columns.append(row[4].displayString)
            keys[table]![keys[table]!.count - 1].referencedColumns.append(row[5].isNull ? "" : row[5].displayString)
        }
        var indexes: [String: [TableIndex]] = [:]
        var lastIndex: (table: String, name: String)?
        for row in indexRows where row.count == 7 {
            let table = row[0].displayString, name = row[2].displayString
            if lastIndex?.table != table || lastIndex?.name != name {
                indexes[table, default: []].append(TableIndex(name: name, columns: [], unique: row[3] == .integer(1), primary: row[4] == .text("pk")))
                lastIndex = (table, name)
            }
            if !row[5].isNull { indexes[table]![indexes[table]!.count - 1].columns.append(row[6].displayString) }
        }
        return objects.map { object in
            TableDescription(object: object, columns: columns[object.name] ?? [], foreignKeys: keys[object.name] ?? [],
                             indexes: indexes[object.name] ?? [])
        }
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



    public func executeStatement(_ sql: String) async throws -> QueryResult {
        try await executeStatement(sql, maxRows: nil)
    }

    public func executeStatement(_ sql: String, maxRows: Int?) async throws -> QueryResult {
        let db = try await liveHandle()
        inTransaction = TransactionState.after(sql, wasOpen: inTransaction)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let columnCount = Int(sqlite3_column_count(stmt))
        let columns = (0..<columnCount).map { String(cString: sqlite3_column_name(stmt, Int32($0))) }
        var rows: [[CellValue]] = []
        var truncated = false
        let readOnly = sqlite3_stmt_readonly(stmt) != 0

        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            if let maxRows, rows.count >= max(maxRows, 0) {
                truncated = true
                // One step past the cap tells that more rows exist, and a query stops there. A statement that
                // writes (… RETURNING) still runs to the end; only its extra rows are dropped.
                if readOnly { break } else { continue }
            }
            rows.append((0..<columnCount).map { Self.value(stmt, Int32($0)) })
        }

        let affected = columnCount == 0 ? Int(sqlite3_changes(db)) : nil
        return QueryResult(statement: sql, columns: columns, rows: rows, affectedRows: affected, isTruncated: truncated)
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

    // MARK: - Bound parameters

    /// `?` placeholders bound with sqlite3_bind_*: integers, reals and blobs keep their storage class;
    /// dates and other text go in as TEXT (SQLite has no date type) and column affinity applies as usual.
    public func executeStatement(_ sql: String, parameters: [SQLParameter]) async throws -> QueryResult {
        guard !parameters.isEmpty else { return try await executeStatement(sql) }
        let db = try await liveHandle()
        inTransaction = TransactionState.after(sql, wasOpen: inTransaction)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32 = switch parameter {
            case .null: sqlite3_bind_null(stmt, index)
            case .integer(let v): sqlite3_bind_int64(stmt, index, v)
            case .double(let v): sqlite3_bind_double(stmt, index, v)
            case .bool(let v): sqlite3_bind_int64(stmt, index, v ? 1 : 0)
            case .text(let v), .typed(let v, _), .untyped(let v): sqlite3_bind_text(stmt, index, v, -1, transient)
            case .blob(let data) where data.isEmpty:
                // A NULL pointer would bind NULL; an empty blob is a zero-length blob.
                sqlite3_bind_zeroblob(stmt, index, 0)
            case .blob(let data):
                data.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32($0.count), transient) }
            }
            guard rc == SQLITE_OK else { throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db))) }
        }

        let columnCount = Int(sqlite3_column_count(stmt))
        let columns = (0..<columnCount).map { String(cString: sqlite3_column_name(stmt, Int32($0))) }
        var rows: [[CellValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw DatabaseError.queryFailed(String(cString: sqlite3_errmsg(db))) }
            rows.append((0..<columnCount).map { Self.value(stmt, Int32($0)) })
        }
        let affected = columnCount == 0 ? Int(sqlite3_changes(db)) : nil
        return QueryResult(statement: sql, columns: columns, rows: rows, affectedRows: affected)
    }
}

/// The open handle behind a lock, so `sqlite3_interrupt` from another thread never races `sqlite3_close`.
private final class InterruptHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?

    func set(_ handle: OpaquePointer?) {
        lock.withLock { self.handle = handle }
    }

    func interrupt() {
        lock.withLock {
            if let handle { sqlite3_interrupt(handle) }
        }
    }
}
