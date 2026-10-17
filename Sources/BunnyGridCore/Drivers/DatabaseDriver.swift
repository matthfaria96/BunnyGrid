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

    /// Row estimates, sizes and comments for the Objects tab, keyed by table name.
    func tableStatistics(schema: String?) async throws -> [String: TableStatistics]
    func objectDDL(name: String, kind: DatabaseObjectKind, schema: String?) async throws -> String
    func listForeignKeys(table: String, schema: String?) async throws -> [TableForeignKey]
    func listTriggers(table: String, schema: String?) async throws -> [TableTrigger]
}

extension DatabaseDriver {
    public var dialect: SQLDialect { SQLDialect(kind: config.kind) }

    public func tableStatistics(schema: String?) async throws -> [String: TableStatistics] { [:] }
    public func listForeignKeys(table: String, schema: String?) async throws -> [TableForeignKey] { [] }
    public func listTriggers(table: String, schema: String?) async throws -> [TableTrigger] { [] }

    /// The object's CREATE statement for the DDL pane. The default rebuilds a table from its columns and indexes;
    /// engines that store or print the original DDL override it.
    public func objectDDL(name: String, kind: DatabaseObjectKind, schema: String?) async throws -> String {
        guard kind == .table else { return "-- DDL is not available for this object." }
        return try await generatedTableDDL(name: name, schema: schema)
    }

    /// CREATE TABLE (and CREATE INDEX) rebuilt from the catalog.
    public func generatedTableDDL(name: String, schema: String?) async throws -> String {
        let columns = try await listColumns(table: name, schema: schema).map(ColumnDesign.init)
        var statements = [try dialect.createTable(name: name, schema: schema, columns: columns) + ";"]
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

    public func executeTimed(_ sql: String) async throws -> QueryResult {
        if config.readOnly && !Self.isReadOnlyStatement(sql) { throw DatabaseError.readOnly }
        let clock = ContinuousClock()
        let start = clock.now
        var result = try await executeStatement(sql)
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
    /// a failure is reported without rolling back. Returns the statements that ran.
    @discardableResult
    public func applyChanges(_ changes: [RowChange], table: String, schema: String?, inOpenTransaction: Bool = false) async throws -> [String] {
        guard !changes.isEmpty else { return [] }
        if config.readOnly { throw DatabaseError.readOnly }
        let statements = changes.map { dialect.sql(for: $0, table: table, schema: schema) }
        if !inOpenTransaction { _ = try await executeStatement(dialect.beginTransaction) }
        do {
            for (change, statement) in zip(changes, statements) {
                let result = try await executeStatement(statement)
                if change.targetsSingleRow, let affected = result.affectedRows, affected != 1 {
                    throw DatabaseError.queryFailed(
                        "Expected to change 1 row but changed \(affected). Nothing was saved; reload the table and try again.\n\(statement)")
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
        let first = sql.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix { !$0.isWhitespace && $0 != "(" }
            .uppercased()
        return ["SELECT", "WITH", "SHOW", "EXPLAIN", "DESCRIBE", "DESC", "PRAGMA", "VALUES"].contains(first)
    }
}

public enum DriverFactory {
    public static func make(config: ConnectionConfig, password: String?) -> any DatabaseDriver {
        switch config.kind {
        case .sqlite: SQLiteDriver(config: config)
        case .postgresql: PostgresDriver(config: config, password: password)
        case .mysql, .mariadb: MySQLDriver(config: config, password: password)
        }
    }
}
