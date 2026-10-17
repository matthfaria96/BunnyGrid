import Foundation

/// Navicat's Data Transfer options.
public struct DataTransferOptions: Sendable, Equatable {
    /// CREATE TABLE on the target (tables that already exist are kept and filled, unless dropped first).
    public var createTables: Bool
    /// DROP TABLE IF EXISTS before creating.
    public var dropTargetTables: Bool
    /// Copy the rows (off: structure only).
    public var transferData: Bool
    public var createIndexes: Bool
    public var createForeignKeys: Bool
    /// Log a failed statement or row and go on, instead of stopping.
    public var continueOnError: Bool
    /// Rows per INSERT statement.
    public var rowsPerBatch: Int

    public init(createTables: Bool = true, dropTargetTables: Bool = false, transferData: Bool = true, createIndexes: Bool = true,
                createForeignKeys: Bool = true, continueOnError: Bool = false, rowsPerBatch: Int = 500) {
        self.createTables = createTables
        self.dropTargetTables = dropTargetTables
        self.transferData = transferData
        self.createIndexes = createIndexes
        self.createForeignKeys = createForeignKeys
        self.continueOnError = continueOnError
        self.rowsPerBatch = rowsPerBatch
    }
}

/// Where a transfer writes: another connection, or a .sql script for an engine.
public enum TransferDestination: Sendable {
    /// `schema`: the PostgreSQL schema, the MySQL database, nil on SQLite.
    case database(any DatabaseDriver, schema: String?)
    /// Statements are handed to `write`, each ending in `;\n`.
    case script(kind: DatabaseKind, schema: String?, write: @Sendable (String) async throws -> Void)

    public var kind: DatabaseKind {
        switch self {
        case .database(let driver, _): driver.config.kind
        case .script(let kind, _, _): kind
        }
    }

    public var schema: String? {
        switch self {
        case .database(_, let schema), .script(_, let schema, _): schema
        }
    }
}

/// What a running transfer reports.
public enum TransferEvent: Sendable, Equatable {
    case tableStarted(String, index: Int, count: Int)
    /// Rows copied so far into the table, and its row count when known.
    case rowsCopied(String, copied: Int, total: Int?)
    case log(String)
    case error(String)
}

public struct TransferSummary: Sendable, Equatable {
    public var tables = 0
    public var rows = 0
    public var errors = 0
    public init() {}
}

/// Copies tables (structure and/or rows) from one connection to another, across engines, or into a .sql script.
public struct DataTransfer: Sendable {
    public var source: any DatabaseDriver
    public var sourceSchema: String?
    public var tables: [String]
    public var destination: TransferDestination
    public var options: DataTransferOptions

    public init(source: any DatabaseDriver, sourceSchema: String?, tables: [String], destination: TransferDestination,
                options: DataTransferOptions = DataTransferOptions()) {
        self.source = source
        self.sourceSchema = sourceSchema
        self.tables = tables
        self.destination = destination
        self.options = options
    }

    /// The tables as they will be created on the target, parents before children.
    public func plan() async throws -> [TableDefinition] {
        let snapshot = try await SchemaSnapshot.read(from: source, schema: sourceSchema, tables: Set(tables), includeViews: false)
        return Self.definitions(for: snapshot, to: destination.kind, schema: destination.schema)
    }

    static func definitions(for snapshot: SchemaSnapshot, to kind: DatabaseKind, schema: String?) -> [TableDefinition] {
        let names = Set(snapshot.tables.map(\.name))
        return creationOrder(snapshot.tables).map { table in
            SchemaMapper.definition(of: table, from: snapshot.kind, to: kind, targetSchema: schema,
                                    primaryKeyOf: { snapshot.table($0)?.primaryKey }, include: { names.contains($0) })
        }
    }

    /// Parents before children; tables caught in a cycle keep their order.
    static func creationOrder(_ tables: [TableSchema]) -> [TableSchema] {
        let names = Set(tables.map(\.name))
        var pending = tables
        var created = Set<String>()
        var ordered: [TableSchema] = []
        while !pending.isEmpty {
            let ready = pending.firstIndex { table in
                table.foreignKeys.allSatisfy { $0.referencedTable == table.name || !names.contains($0.referencedTable) || created.contains($0.referencedTable) }
            } ?? 0
            let table = pending.remove(at: ready)
            created.insert(table.name)
            ordered.append(table)
        }
        return ordered
    }

    @discardableResult
    public func run(onEvent: @escaping @Sendable (TransferEvent) async -> Void = { _ in }) async throws -> TransferSummary {
        var summary = TransferSummary()
        let snapshot = try await SchemaSnapshot.read(from: source, schema: sourceSchema, tables: Set(tables), includeViews: false)
        let missing = Set(tables).subtracting(snapshot.tables.map(\.name))
        for name in missing.sorted() { await onEvent(.error("Table “\(name)” was not found in the source.")); summary.errors += 1 }
        let kind = destination.kind
        let schema = destination.schema
        let dialect = SQLDialect(kind: kind)
        let definitions = Self.definitions(for: snapshot, to: kind, schema: schema)
        let isMySQL = kind == .mysql || kind == .mariadb
        let writer = Writer(destination: destination, continueOnError: options.continueOnError, onEvent: onEvent)

        if case .script = destination {
            try await writer.comment("BunnyGrid Data Transfer: \(definitions.count) table(s) from \(source.config.kind.displayName) to \(kind.displayName)")
        }
        // Keys are checked by the server only once every table and row is in.
        if isMySQL { try await writer.execute("SET FOREIGN_KEY_CHECKS = 0") }
        if kind == .sqlite { try await writer.execute("PRAGMA foreign_keys = OFF") }

        var existing = Set<String>()
        if case .database(let driver, let schema) = destination {
            existing = Set(try await driver.listObjects(schema: schema).filter { $0.kind == .table }.map { $0.name.lowercased() })
        }
        if options.dropTargetTables {
            for table in definitions.reversed() {
                if try await writer.execute(dialect.dropTableIfExists(table.name, schema: schema)) { existing.remove(table.name.lowercased()) }
            }
        }
        var created = Set<String>()
        if options.createTables {
            for table in definitions {
                try Task.checkCancellation()
                if existing.contains(table.name.lowercased()) {
                    await onEvent(.log("\(table.name) already exists on the target; its rows are added to it."))
                    continue
                }
                let sql = try dialect.createTable(table, schema: schema, includeForeignKeys: kind == .sqlite && options.createForeignKeys)
                if try await writer.execute(sql) { created.insert(table.name) }
            }
        }

        for (index, table) in definitions.enumerated() {
            try Task.checkCancellation()
            await onEvent(.tableStarted(table.name, index: index, count: definitions.count))
            summary.tables += 1
            guard options.transferData else { continue }
            let targetColumns: [ColumnDesign]
            if created.contains(table.name) || !existing.contains(table.name.lowercased()) {
                targetColumns = table.columns
            } else if case .database(let driver, let schema) = destination {
                targetColumns = try await driver.listColumns(table: table.name, schema: schema).map(ColumnDesign.init)
            } else {
                targetColumns = table.columns
            }
            let copied = try await copyRows(of: table.name, into: table.name, targetColumns: targetColumns, writer: writer, onEvent: onEvent)
            summary.rows += copied
            if copied > 0, kind == .postgresql {
                for column in table.autoIncrement.sorted() {
                    if let sql = dialect.resetSequence(table: table.name, column: column, schema: schema) { try await writer.execute(sql) }
                }
            }
        }

        // Indexes and keys only on tables this transfer created, after their rows are in.
        for table in definitions where created.contains(table.name) {
            try Task.checkCancellation()
            if options.createIndexes {
                for index in table.indexes { try await writer.execute(try dialect.createIndex(index, table: table.name, schema: schema)) }
            }
            if options.createForeignKeys && kind != .sqlite {
                for key in table.foreignKeys { try await writer.execute(try dialect.addForeignKey(key, table: table.name, schema: schema)) }
            }
        }
        if isMySQL { try await writer.execute("SET FOREIGN_KEY_CHECKS = 1") }
        summary.errors += await writer.errors
        return summary
    }

    /// Streams the rows of `sourceTable` in pages and inserts them in batches of `rowsPerBatch`, as typed parameters
    /// (or literals in a script). Returns the rows written.
    private func copyRows(of sourceTable: String, into targetTable: String, targetColumns: [ColumnDesign], writer: Writer,
                          onEvent: @escaping @Sendable (TransferEvent) async -> Void) async throws -> Int {
        let kind = destination.kind
        let dialect = SQLDialect(kind: kind)
        let sourceColumns = try await source.listColumns(table: sourceTable, schema: sourceSchema)
        let order = sourceColumns.filter(\.isPrimaryKey).map { OrderBy(column: $0.name, direction: .ascending) }
        let total = try? await source.countRows(table: sourceTable, schema: sourceSchema)
        let targetsByName = Dictionary(targetColumns.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let pageSize = max(1000, options.rowsPerBatch)
        var copied = 0
        var offset = 0
        var mapping: [(source: Int, target: ColumnDesign)]?
        if case .database(let driver, _) = destination, kind == .sqlite { _ = try await driver.executeStatement("BEGIN") }
        do {
            while true {
                try Task.checkCancellation()
                let page = try await source.fetchPage(table: sourceTable, schema: sourceSchema, offset: offset, limit: pageSize, orderBy: order)
                if mapping == nil {
                    mapping = page.columns.enumerated().compactMap { index, name in targetsByName[name.lowercased()].map { (index, $0) } }
                    if mapping?.isEmpty == true { throw DatabaseError.queryFailed("“\(targetTable)” on the target has none of the source's columns.") }
                }
                guard let mapping else { break }
                let names = mapping.map(\.target.name)
                let categories = mapping.map { ColumnTypeCategory.classify($0.target.type, kind: kind) }
                let rows = page.rows.map { row in
                    mapping.enumerated().map { position, entry in
                        SQLParameter(entry.source < row.count ? row[entry.source] : .null, category: categories[position])
                    }
                }
                let batch = max(1, min(options.rowsPerBatch, dialect.maxParameters / max(1, names.count)))
                for start in stride(from: 0, to: rows.count, by: batch) {
                    try Task.checkCancellation()
                    let chunk = Array(rows[start..<min(start + batch, rows.count)])
                    copied += try await writer.insert(into: targetTable, columns: names, rows: chunk)
                }
                await onEvent(.rowsCopied(targetTable, copied: copied, total: total))
                if page.rows.count < pageSize { break }
                offset += pageSize
            }
            if case .database(let driver, _) = destination, kind == .sqlite { _ = try await driver.executeStatement("COMMIT") }
        } catch {
            if case .database(let driver, _) = destination, kind == .sqlite { _ = try? await driver.executeStatement("ROLLBACK") }
            throw error
        }
        return copied
    }
}

/// Runs statements on the target or writes them to the script, reporting failures (and going on when asked).
private actor Writer {
    let destination: TransferDestination
    let continueOnError: Bool
    let onEvent: @Sendable (TransferEvent) async -> Void
    private(set) var errors = 0
    private var rowErrorsLogged = 0

    init(destination: TransferDestination, continueOnError: Bool, onEvent: @escaping @Sendable (TransferEvent) async -> Void) {
        self.destination = destination
        self.continueOnError = continueOnError
        self.onEvent = onEvent
    }

    private var dialect: SQLDialect { SQLDialect(kind: destination.kind) }

    func comment(_ text: String) async throws {
        if case .script(_, _, let write) = destination { try await write("-- \(text)\n\n") }
    }

    /// Runs one statement. False when it failed and `continueOnError` let the transfer go on.
    @discardableResult
    func execute(_ sql: String) async throws -> Bool {
        switch destination {
        case .script(_, _, let write):
            try await write(sql + ";\n\n")
            return true
        case .database(let driver, _):
            do {
                _ = try await driver.executeStatement(sql)
                return true
            } catch {
                errors += 1
                await onEvent(.error("\(error.localizedDescription)\n\(sql.prefix(300))"))
                if !continueOnError { throw error }
                return false
            }
        }
    }

    /// Inserts rows in one statement. When it fails and `continueOnError` is on, retries them one by one so only the
    /// bad rows are skipped. Returns the rows written.
    func insert(into table: String, columns: [String], rows: [[SQLParameter]]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        let d = dialect
        let schema = destination.schema
        switch destination {
        case .script(_, _, let write):
            let target = d.qualifiedName(table: table, schema: schema)
            let names = columns.map(d.quoteIdentifier).joined(separator: ", ")
            let tuples = rows.map { "(" + $0.map(d.literal).joined(separator: ", ") + ")" }.joined(separator: ",\n  ")
            try await write("INSERT INTO \(target) (\(names)) VALUES \(tuples);\n")
            return rows.count
        case .database(let driver, _):
            do {
                _ = try await driver.executeStatement(d.multiRowInsert(into: table, schema: schema, columns: columns, rowCount: rows.count),
                                                      parameters: rows.flatMap { $0 })
                return rows.count
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard continueOnError else {
                    errors += 1
                    await onEvent(.error("\(table): \(error.localizedDescription)"))
                    throw error
                }
                guard rows.count > 1 else {
                    errors += 1
                    if rowErrorsLogged < 50 {
                        rowErrorsLogged += 1
                        await onEvent(.error("\(table): row skipped: \(error.localizedDescription)"))
                    }
                    return 0
                }
                var written = 0
                for row in rows { written += try await insert(into: table, columns: columns, rows: [row]) }
                return written
            }
        }
    }
}
