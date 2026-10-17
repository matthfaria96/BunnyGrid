import Foundation

public enum DatabaseError: LocalizedError, Sendable {
    case notConnected
    case connectionFailed(String)
    case queryFailed(String)
    case unsupported(String)
    case readOnly

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to the database."
        case .connectionFailed(let message): "Connection failed: \(message)"
        case .queryFailed(let message): message
        case .unsupported(let what): "\(what) is not supported by this database."
        case .readOnly: "This connection is read-only."
        }
    }
}

/// The contract every engine implements. Shaped after Beekeeper Studio's
/// `BasicDatabaseClient`, trimmed to what the browser, grid and editor need today.
public protocol DatabaseDriver: AnyObject, Sendable {
    var config: ConnectionConfig { get }

    func connect() async throws
    func disconnect() async

    func serverVersion() async throws -> String
    func listDatabases() async throws -> [String]
    /// Schemas inside the current database. Empty for engines without schemas.
    func listSchemas() async throws -> [String]
    func listObjects(schema: String?) async throws -> [DatabaseObject]
    func listColumns(table: String, schema: String?) async throws -> [TableColumn]
    func listIndexes(table: String, schema: String?) async throws -> [TableIndex]

    /// Runs exactly one statement.
    func executeStatement(_ sql: String) async throws -> QueryResult

    /// Runs one statement with typed values bound to its placeholders (`SQLDialect.placeholder(_:)`).
    func executeStatement(_ sql: String, parameters: [SQLParameter]) async throws -> QueryResult

    /// Runs exactly one statement, reading at most `maxRows` rows of its result (all of them when nil).
    /// When more rows exist the result is marked `isTruncated`, and the driver stops reading instead of
    /// keeping the whole result in memory.
    func executeStatement(_ sql: String, maxRows: Int?) async throws -> QueryResult

    /// Asks the server to stop the statement running on this driver's connection, from outside it:
    /// `pg_cancel_backend` / `KILL QUERY` on a second connection, `sqlite3_interrupt` on SQLite.
    /// The running statement then fails with the engine's "cancelled" error. A no-op when nothing runs.
    func cancelCurrentQuery() async throws

    /// Row estimates, sizes and comments for the Objects tab, keyed by table name.
    func tableStatistics(schema: String?) async throws -> [String: TableStatistics]
    /// The statistics of one table (the Info pane, the designer). Defaults to filtering `tableStatistics(schema:)`;
    /// engines where that means scanning every table answer for just this one.
    func tableStatistics(schema: String?, table: String) async throws -> TableStatistics?
    func objectDDL(name: String, kind: DatabaseObjectKind, schema: String?) async throws -> String
    func listForeignKeys(table: String, schema: String?) async throws -> [TableForeignKey]
    func listTriggers(table: String, schema: String?) async throws -> [TableTrigger]
    /// Columns, foreign keys and indexes of every table in a schema (reverse engineering a model). The default
    /// asks table by table; engines that can read the whole catalog in a few statements override it.
    func describeTables(schema: String?) async throws -> [TableDescription]
}

/// One table's shape as the catalog describes it.
public struct TableDescription: Sendable, Equatable {
    public var object: DatabaseObject
    public var columns: [TableColumn]
    public var foreignKeys: [TableForeignKey]
    public var indexes: [TableIndex]

    public init(object: DatabaseObject, columns: [TableColumn], foreignKeys: [TableForeignKey], indexes: [TableIndex]) {
        self.object = object
        self.columns = columns
        self.foreignKeys = foreignKeys
        self.indexes = indexes
    }
}

extension DatabaseDriver {
    public var dialect: SQLDialect { SQLDialect(kind: config.kind) }

    public func tableStatistics(schema: String?) async throws -> [String: TableStatistics] { [:] }

    public func tableStatistics(schema: String?, table: String) async throws -> TableStatistics? {
        try await tableStatistics(schema: schema)[table]
    }

    /// Fallback for engines that can't stop reading early: runs the statement and drops the extra rows.
    public func executeStatement(_ sql: String, maxRows: Int?) async throws -> QueryResult {
        QueryResult.capped(try await executeStatement(sql), maxRows: maxRows)
    }

    public func cancelCurrentQuery() async throws {
        throw DatabaseError.unsupported("Cancelling a running query")
    }
    public func listForeignKeys(table: String, schema: String?) async throws -> [TableForeignKey] { [] }
    public func listTriggers(table: String, schema: String?) async throws -> [TableTrigger] { [] }

    public func describeTables(schema: String?) async throws -> [TableDescription] {
        var tables: [TableDescription] = []
        for object in try await listObjects(schema: schema) where object.kind == .table {
            try Task.checkCancellation()
            tables.append(TableDescription(
                object: object,
                columns: try await listColumns(table: object.name, schema: schema),
                foreignKeys: (try? await listForeignKeys(table: object.name, schema: schema)) ?? [],
                indexes: (try? await listIndexes(table: object.name, schema: schema)) ?? []))
        }
        return tables
    }

    /// The object's CREATE statement for the DDL pane. The default rebuilds a table from its columns and indexes;
    /// engines that store or print the original DDL override it.
    public func objectDDL(name: String, kind: DatabaseObjectKind, schema: String?) async throws -> String {
        guard kind == .table else { return "-- DDL is not available for this object." }
        return try await generatedTableDDL(name: name, schema: schema)
    }

    /// CREATE TABLE (with its foreign keys) and CREATE INDEX rebuilt from the catalog.
    public func generatedTableDDL(name: String, schema: String?) async throws -> String {
        let columns = try await listColumns(table: name, schema: schema).map(ColumnDesign.init)
        let keys = (try? await listForeignKeys(table: name, schema: schema)) ?? []
        var statements = [try dialect.createTable(name: name, schema: schema, columns: columns, foreignKeys: keys) + ";"]
        for index in try await listIndexes(table: name, schema: schema) where !index.primary {
            statements.append(try dialect.createIndex(IndexDesign(index), table: name, schema: schema) + ";")
        }
        return statements.joined(separator: "\n\n")
    }

    /// Runs a script statement by statement and returns one result per statement.
    public func execute(_ script: String) async throws -> [QueryResult] {
        var results: [QueryResult] = []
        for statement in SQLSplitter.split(script) {
            try Task.checkCancellation()
            results.append(try await executeTimed(statement))
        }
        return results
    }

    /// Runs one statement and records how long it took. `maxRows` caps the rows read (`executeStatement(_:maxRows:)`).
    public func executeTimed(_ sql: String, maxRows: Int? = nil) async throws -> QueryResult {
        if config.readOnly && !Self.isReadOnlyStatement(sql) { throw DatabaseError.readOnly }
        let clock = ContinuousClock()
        let start = clock.now
        var result = try await executeStatement(sql, maxRows: maxRows)
        result.duration = clock.now - start
        return result
    }

    public func fetchPage(table: String, schema: String?, offset: Int, limit: Int, orderBy: [OrderBy] = [], filter: String? = nil) async throws -> TablePage {
        let sql = dialect.selectPage(table: table, schema: schema, offset: offset, limit: limit, orderBy: orderBy, filter: filter)
        let result = try await executeStatement(sql)
        return TablePage(columns: result.columns, rows: result.rows, offset: offset, limit: limit)
    }

    public func countRows(table: String, schema: String?, filter: String? = nil) async throws -> Int {
        let result = try await executeStatement(dialect.countRows(table: table, schema: schema, filter: filter))
        switch result.rows.first?.first {
        case .integer(let n): return Int(n)
        case .text(let s): return Int(s) ?? 0
        case .double(let d): return Int(d)
        default: return 0
        }
    }

    /// Applies grid changes in one transaction. Rolls back everything if any statement fails
    /// or if an UPDATE/DELETE does not hit exactly one row (the row changed or vanished meanwhile).
    /// With `inOpenTransaction`, the caller owns BEGIN/COMMIT (manual "Begin Transaction" mode) and
    /// a failure is reported without rolling back.
    ///
    /// Values are bound as typed parameters (integers, doubles, booleans, bytes, dates…) chosen from
    /// `columns`' declared types; columns it doesn't describe are bound as text for the server to convert.
    /// Returns the statements that ran, rendered with literals for the history log.
    @discardableResult
    public func applyChanges(_ changes: [RowChange], table: String, schema: String?, inOpenTransaction: Bool = false,
                             columns: [TableColumn] = []) async throws -> [String] {
        guard !changes.isEmpty else { return [] }
        if config.readOnly { throw DatabaseError.readOnly }
        let statements = changes.map { dialect.sql(for: $0, table: table, schema: schema, columns: columns) }
        let bound = changes.map { dialect.boundStatement(for: $0, table: table, schema: schema, columns: columns) }
        if !inOpenTransaction { _ = try await executeStatement(dialect.beginTransaction) }
        do {
            for (index, change) in changes.enumerated() {
                let result = try await executeStatement(bound[index].sql, parameters: bound[index].parameters)
                if change.targetsSingleRow, let affected = result.affectedRows, affected != 1 {
                    throw DatabaseError.queryFailed(
                        "Expected to change 1 row but changed \(affected). Nothing was saved; reload the table and try again.\n\(statements[index])")
                }
            }
            if !inOpenTransaction { _ = try await executeStatement("COMMIT") }
        } catch {
            if !inOpenTransaction { _ = try? await executeStatement("ROLLBACK") }
            throw error
        }
        return statements
    }

    static func isReadOnlyStatement(_ sql: String) -> Bool {
        SQLSplitter.isReadOnly(sql)
    }
}

public enum DriverFactory {
    public static func make(config: ConnectionConfig, password: String?) -> any DatabaseDriver {
        make(config: config, secrets: ConnectionSecrets(password: password))
    }

    /// A driver with every secret it may need: the password, the SSH password or key passphrase, the SSL key passphrase.
    public static func make(config: ConnectionConfig, secrets: ConnectionSecrets) -> any DatabaseDriver {
        switch config.kind {
        case .sqlite: SQLiteDriver(config: config)
        case .postgresql: PostgresDriver(config: config, secrets: secrets)
        case .mysql, .mariadb: MySQLDriver(config: config, secrets: secrets)
        case .sqlserver: SQLServerDriver(config: config, secrets: secrets)
        case .redis: RedisDriver(config: config, secrets: secrets)
        case .mongodb: MongoDriver(config: config, secrets: secrets)
        }
    }
}
