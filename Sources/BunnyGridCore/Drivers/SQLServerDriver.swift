import Foundation
import NIOSSL

/// Microsoft SQL Server (and Azure SQL) on BunnyGrid's own TDS 7.4 client (`Drivers/TDS`).
/// Like PostgreSQL, one connection serves one database; schemas (`dbo`, …) live inside it.
public actor SQLServerDriver: DatabaseDriver {
    public nonisolated let config: ConnectionConfig
    private let secrets: ConnectionSecrets
    private var connection: TDSConnection?
    /// The SSH tunnel (if any) the connection goes through; released on disconnect.
    private var endpoint: ConnectionEndpoint?

    public init(config: ConnectionConfig, password: String?) {
        self.init(config: config, secrets: ConnectionSecrets(password: password))
    }

    public init(config: ConnectionConfig, secrets: ConnectionSecrets) {
        self.config = config
        self.secrets = secrets
    }

    public func connect() async throws {
        guard connection == nil else { return }
        let endpoint = try await ConnectionEndpoint.open(for: config, sshSecret: secrets.sshSecret)
        do {
            guard case .tcp(let host, let port) = endpoint.address else {
                throw DatabaseError.connectionFailed("SQL Server doesn't accept connections through a socket file; use host and port.")
            }
            let tls: TLSConfiguration?
            do {
                tls = try ConnectionTLS.configuration(for: config, keyPassphrase: secrets.sslKeyPassphrase)
            } catch {
                throw DatabaseError.connectionFailed(ConnectionErrorText.describe(error))
            }
            let options = TDSConnection.Options(
                host: host, port: port, tlsServerName: endpoint.tlsServerName, mode: config.tls, tls: tls,
                username: config.username, password: secrets.password ?? "",
                database: config.database.isEmpty ? (config.kind.serverDatabase ?? "") : config.database,
                serverName: config.host)
            do {
                connection = try await TDSConnection.connect(options)
            } catch let error as DatabaseError {
                throw error
            } catch {
                throw DatabaseError.connectionFailed(ConnectionErrorText.describe(error))
            }
            self.endpoint = endpoint
        } catch {
            await endpoint.close()
            throw error
        }
    }

    public func disconnect() async {
        await connection?.close()
        connection = nil
        await endpoint?.close()
        endpoint = nil
    }

    /// ATTENTION on the same connection: the server stops the running request and acknowledges it.
    public func cancelCurrentQuery() async throws {
        await connection?.cancel()
    }

    // MARK: - Execution

    public func executeStatement(_ sql: String) async throws -> QueryResult {
        try await executeStatement(sql, maxRows: nil)
    }

    public func executeStatement(_ sql: String, maxRows: Int?) async throws -> QueryResult {
        let connection = try requireConnection()
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased().hasPrefix(SQLDialect.showplanPrefix) {
            return try await showPlan(String(trimmed.dropFirst(SQLDialect.showplanPrefix.count)), on: connection)
        }
        do {
            return Self.result(sql, try await connection.execute(sql, maxRows: maxRows))
        } catch {
            throw Self.queryError(error)
        }
    }

    public func executeStatement(_ sql: String, parameters: [SQLParameter]) async throws -> QueryResult {
        guard !parameters.isEmpty else { return try await executeStatement(sql) }
        let connection = try requireConnection()
        do {
            return Self.result(sql, try await connection.executeSQL(sql, parameters: parameters.map(Self.value)))
        } catch {
            throw Self.queryError(error)
        }
    }

    /// The estimated plan (SHOWPLAN_XML), which `QueryPlan.sqlServerXML` turns into a tree.
    private func showPlan(_ statement: String, on connection: TDSConnection) async throws -> QueryResult {
        do {
            _ = try await connection.execute("SET SHOWPLAN_XML ON")
            let response: TDSResponse
            do {
                response = try await connection.execute(statement)
            } catch {
                _ = try? await connection.execute("SET SHOWPLAN_XML OFF")
                throw error
            }
            _ = try await connection.execute("SET SHOWPLAN_XML OFF")
            // One plan document per statement; joined they still parse as a list of plans.
            let documents = response.resultSets.compactMap { $0.rows.first?.first?.displayString }
            return QueryResult(statement: SQLDialect.showplanPrefix + "\n" + statement, columns: ["Microsoft SQL Server 2005 XML Showplan"],
                               rows: [[.text(documents.joined(separator: "\n"))]])
        } catch {
            throw Self.queryError(error)
        }
    }

    private func requireConnection() throws -> TDSConnection {
        guard let connection else { throw DatabaseError.notConnected }
        return connection
    }

    /// The last result set (a batch that selects several times shows the final one), or the row count.
    static func result(_ sql: String, _ response: TDSResponse) -> QueryResult {
        if let set = response.resultSets.last(where: { !$0.columns.isEmpty }) {
            return QueryResult(statement: sql, columns: set.columns.map(\.name), rows: set.rows, isTruncated: set.isTruncated)
        }
        return QueryResult(statement: sql, columns: [], rows: [], affectedRows: response.affectedRows)
    }

    static func queryError(_ error: any Error) -> DatabaseError {
        if let error = error as? DatabaseError { return error }
        if let error = error as? TDSError {
            if case .cancelled = error { return .queryFailed("Query was cancelled (Operation cancelled by user).") }
            return .queryFailed(error.errorDescription ?? "\(error)")
        }
        return .queryFailed(ConnectionErrorText.describe(error))
    }

    /// Integers, doubles, booleans and bytes keep their type; text (also dates, uuids and decimals) goes as
    /// nvarchar, which SQL Server converts to the column's type as it would a quoted literal.
    static func value(_ parameter: SQLParameter) -> TDSRequest.Value {
        switch parameter {
        case .null: .null
        case .integer(let v): .bigint(v)
        case .double(let v): .float(v)
        case .bool(let v): .bit(v)
        case .blob(let data): .varbinary(data)
        case .text(let v), .untyped(let v), .typed(let v, _): .nvarchar(v)
        }
    }

    private func rows(_ sql: String) async throws -> [[CellValue]] {
        try await executeStatement(sql).rows
    }

    private func lit(_ value: String) -> String { dialect.quoteLiteral(value) }
    private func objectID(_ name: String, _ schema: String?) -> String {
        "OBJECT_ID(\(lit(dialect.qualifiedName(table: name, schema: schema ?? "dbo"))))"
    }

    // MARK: - Catalog

    public func serverVersion() async throws -> String {
        let text = try await rows("SELECT @@VERSION").first?.first?.displayString ?? "SQL Server"
        return text.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? text
    }

    public func listDatabases() async throws -> [String] {
        try await rows("SELECT name FROM sys.databases WHERE state = 0 AND HAS_DBACCESS(name) = 1 ORDER BY name").compactMap { $0.first?.displayString }
    }

    /// The database's schemas, without the ones that belong to the fixed database roles (db_owner, db_datareader…).
    public func listSchemas() async throws -> [String] {
        try await rows("""
            SELECT name FROM sys.schemas WHERE NOT (principal_id BETWEEN 16384 AND 16399) ORDER BY name
            """).compactMap { $0.first?.displayString }
    }

    public func listObjects(schema: String?) async throws -> [DatabaseObject] {
        let schema = schema ?? "dbo"
        let result = try await rows("""
            SELECT o.name, CASE WHEN o.type = 'U' THEN 'table' WHEN o.type = 'V' THEN 'view' ELSE 'routine' END AS kind
              FROM sys.all_objects o JOIN sys.schemas s ON s.schema_id = o.schema_id
             WHERE s.name = \(lit(schema)) AND o.type IN ('U', 'V', 'P', 'PC', 'FN', 'IF', 'TF', 'FS', 'FT')
               AND (o.is_ms_shipped = 0 OR s.name IN ('sys', 'INFORMATION_SCHEMA'))
             ORDER BY kind, o.name
            """)
        return result.compactMap { row in
            guard row.count == 2 else { return nil }
            let kind: DatabaseObjectKind = switch row[1].displayString {
            case "view": .view
            case "routine": .routine
            default: .table
            }
            return DatabaseObject(schema: schema, name: row[0].displayString, kind: kind)
        }
    }

    /// Column facts for the grid, the designer and the DDL.
    struct ColumnInfo {
        var column: TableColumn
        var identity: (seed: String, increment: String)?
        var computed: String?
        var defaultName: String?
    }

    func columnInfo(table: String, schema: String?) async throws -> [ColumnInfo] {
        let result = try await rows("""
            SELECT c.name, t.name, c.max_length, c.precision, c.scale, c.is_nullable, dc.definition, c.column_id,
                   CASE WHEN EXISTS (SELECT 1 FROM sys.index_columns ic JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                                      WHERE i.is_primary_key = 1 AND ic.object_id = c.object_id AND ic.column_id = c.column_id) THEN 1 ELSE 0 END,
                   c.is_identity, CAST(ic.seed_value AS nvarchar(40)), CAST(ic.increment_value AS nvarchar(40)), cc.definition, dc.name,
                   t.is_user_defined
              FROM sys.columns c
              JOIN sys.types t ON t.user_type_id = c.user_type_id
              LEFT JOIN sys.default_constraints dc ON dc.object_id = c.default_object_id
              LEFT JOIN sys.identity_columns ic ON ic.object_id = c.object_id AND ic.column_id = c.column_id
              LEFT JOIN sys.computed_columns cc ON cc.object_id = c.object_id AND cc.column_id = c.column_id
             WHERE c.object_id = \(objectID(table, schema))
             ORDER BY c.column_id
            """)
        return result.map { row in
            let typeName = row[1].displayString
            let type = row[14] == .bool(true) ? typeName
                : Self.typeDeclaration(typeName, maxLength: Int(row[2].displayString) ?? 0,
                                       precision: Int(row[3].displayString) ?? 0, scale: Int(row[4].displayString) ?? 0)
            let column = TableColumn(name: row[0].displayString, dataType: type, nullable: row[5] == .bool(true),
                                     defaultValue: row[6].isNull ? nil : row[6].displayString, isPrimaryKey: row[8] == .integer(1),
                                     ordinal: Int(row[7].displayString) ?? 0)
            return ColumnInfo(column: column,
                              identity: row[9] == .bool(true) ? (row[10].displayString, row[11].displayString) : nil,
                              computed: row[12].isNull ? nil : row[12].displayString,
                              defaultName: row[13].isNull ? nil : row[13].displayString)
        }
    }

    public func listColumns(table: String, schema: String?) async throws -> [TableColumn] {
        try await columnInfo(table: table, schema: schema).map(\.column)
    }

    /// `nvarchar(50)`, `varchar(max)`, `decimal(10,2)`, `datetime2(7)` from sys.columns.
    static func typeDeclaration(_ name: String, maxLength: Int, precision: Int, scale: Int) -> String {
        switch name {
        case "varchar", "char", "varbinary", "binary":
            return "\(name)(\(maxLength < 0 ? "max" : String(maxLength)))"
        case "nvarchar", "nchar":
            return "\(name)(\(maxLength < 0 ? "max" : String(maxLength / 2)))"
        case "decimal", "numeric":
            return "\(name)(\(precision),\(scale))"
        case "datetime2", "time", "datetimeoffset":
            return "\(name)(\(scale))"
        default:
            return name
        }
    }

    public func listIndexes(table: String, schema: String?) async throws -> [TableIndex] {
        let result = try await rows("""
            SELECT i.name, i.is_unique, i.is_primary_key,
                   STUFF((SELECT N',' + c.name FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                           WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
                           ORDER BY ic.key_ordinal FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, '')
              FROM sys.indexes i
             WHERE i.object_id = \(objectID(table, schema)) AND i.index_id > 0 AND i.is_hypothetical = 0
             ORDER BY i.name
            """)
        return result.map { row in
            TableIndex(name: row[0].displayString, columns: row[3].displayString.split(separator: ",").map(String.init),
                       unique: row[1] == .bool(true), primary: row[2] == .bool(true))
        }
    }

    public func listForeignKeys(table: String, schema: String?) async throws -> [TableForeignKey] {
        let result = try await rows("""
            SELECT fk.name, SCHEMA_NAME(r.schema_id), r.name, pc.name, rc.name,
                   fk.delete_referential_action_desc, fk.update_referential_action_desc
              FROM sys.foreign_keys fk
              JOIN sys.foreign_key_columns k ON k.constraint_object_id = fk.object_id
              JOIN sys.objects r ON r.object_id = fk.referenced_object_id
              JOIN sys.columns pc ON pc.object_id = k.parent_object_id AND pc.column_id = k.parent_column_id
              JOIN sys.columns rc ON rc.object_id = k.referenced_object_id AND rc.column_id = k.referenced_column_id
             WHERE fk.parent_object_id = \(objectID(table, schema))
             ORDER BY fk.name, k.constraint_column_id
            """)
        var keys: [String: TableForeignKey] = [:]
        var order: [String] = []
        func action(_ text: String) -> String { text.replacingOccurrences(of: "_", with: " ") }
        for row in result where row.count == 7 {
            let name = row[0].displayString
            if keys[name] == nil {
                order.append(name)
                keys[name] = TableForeignKey(name: name, columns: [], referencedSchema: row[1].displayString, referencedTable: row[2].displayString,
                                             referencedColumns: [], onDelete: action(row[5].displayString), onUpdate: action(row[6].displayString))
            }
            keys[name]?.columns.append(row[3].displayString)
            keys[name]?.referencedColumns.append(row[4].displayString)
        }
        return order.compactMap { keys[$0] }
    }

    public func listTriggers(table: String, schema: String?) async throws -> [TableTrigger] {
        let result = try await rows("""
            SELECT t.name, t.is_instead_of_trigger, OBJECT_DEFINITION(t.object_id),
                   STUFF((SELECT ',' + e.type_desc FROM sys.trigger_events e WHERE e.object_id = t.object_id FOR XML PATH('')), 1, 1, '')
              FROM sys.triggers t WHERE t.parent_id = \(objectID(table, schema)) ORDER BY t.name
            """)
        return result.map { row in
            TableTrigger(name: row[0].displayString, timing: row[1] == .bool(true) ? "INSTEAD OF" : "AFTER",
                         events: row[3].displayString.split(separator: ",").map(String.init), definition: row[2].displayString)
        }
    }

    public func tableStatistics(schema: String?) async throws -> [String: TableStatistics] {
        let result = try await rows("""
            SELECT o.name,
                   (SELECT SUM(p.rows) FROM sys.partitions p WHERE p.object_id = o.object_id AND p.index_id IN (0, 1)),
                   (SELECT SUM(a.total_pages) * 8192 FROM sys.partitions p JOIN sys.allocation_units a ON a.container_id = p.partition_id
                     WHERE p.object_id = o.object_id),
                   CAST(ep.value AS nvarchar(max)), CONVERT(nvarchar(30), o.create_date, 120), CONVERT(nvarchar(30), o.modify_date, 120)
              FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id
              LEFT JOIN sys.extended_properties ep ON ep.major_id = o.object_id AND ep.minor_id = 0 AND ep.class = 1 AND ep.name = 'MS_Description'
             WHERE s.name = \(lit(schema ?? "dbo")) AND o.type IN ('U', 'V')
            """)
        var stats: [String: TableStatistics] = [:]
        for row in result where row.count == 6 {
            func int(_ value: CellValue) -> Int? {
                switch value {
                case .integer(let v): Int(v)
                case .text(let s): Int(s)
                default: nil
                }
            }
            stats[row[0].displayString] = TableStatistics(rows: int(row[1]), sizeBytes: int(row[2]),
                                                          comment: row[3].isNull ? nil : row[3].displayString,
                                                          created: row[4].isNull ? nil : row[4].displayString,
                                                          modified: row[5].isNull ? nil : row[5].displayString)
        }
        return stats
    }

    // MARK: - DDL

    /// Views, routines and triggers print their stored definition; tables are rebuilt from the catalog.
    public func objectDDL(name: String, kind: DatabaseObjectKind, schema: String?) async throws -> String {
        guard kind == .table else {
            let text = try await rows("SELECT OBJECT_DEFINITION(\(objectID(name, schema)))").first?.first
            guard let text, !text.isNull else { return "-- The definition of \(name) is not available (encrypted, or no permission)." }
            return text.displayString.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try await tableDDL(name: name, schema: schema)
    }

    /// CREATE TABLE as SSMS scripts it: columns with IDENTITY, computed expressions and named defaults, the primary key,
    /// unique and check constraints; then indexes, triggers and finally the foreign keys as ALTER TABLE (so a script
    /// of several tables runs in any order).
    func tableDDL(name: String, schema: String?) async throws -> String {
        let schema = schema ?? "dbo"
        let qualified = dialect.qualifiedName(table: name, schema: schema)
        let columns = try await columnInfo(table: name, schema: schema)
        guard !columns.isEmpty else { throw DatabaseError.queryFailed("Table \(qualified) was not found.") }
        var parts: [String] = columns.map { info in
            let id = dialect.quoteIdentifier(info.column.name)
            if let computed = info.computed { return "  \(id) AS \(computed)" }
            var sql = "  \(id) \(info.column.dataType)"
            if let identity = info.identity { sql += " IDENTITY(\(identity.seed),\(identity.increment))" }
            sql += info.column.nullable ? " NULL" : " NOT NULL"
            if let value = info.column.defaultValue {
                if let constraint = info.defaultName { sql += " CONSTRAINT \(dialect.quoteIdentifier(constraint))" }
                sql += " DEFAULT \(value)"
            }
            return sql
        }
        let oid = objectID(name, schema)
        let keyConstraints = try await rows("""
            SELECT kc.name, kc.type, i.type_desc,
                   STUFF((SELECT ', ' + QUOTENAME(c.name) + CASE WHEN ic.is_descending_key = 1 THEN ' DESC' ELSE '' END
                            FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                           WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
                           ORDER BY ic.key_ordinal FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '')
              FROM sys.key_constraints kc JOIN sys.indexes i ON i.object_id = kc.parent_object_id AND i.index_id = kc.unique_index_id
             WHERE kc.parent_object_id = \(oid) ORDER BY CASE kc.type WHEN 'PK' THEN 0 ELSE 1 END, kc.name
            """)
        for row in keyConstraints where row.count == 4 {
            let keyword = row[1].displayString.trimmingCharacters(in: .whitespaces) == "PK" ? "PRIMARY KEY" : "UNIQUE"
            parts.append("  CONSTRAINT \(dialect.quoteIdentifier(row[0].displayString)) \(keyword) \(row[2].displayString) (\(row[3].displayString))")
        }
        for row in try await rows("SELECT name, definition FROM sys.check_constraints WHERE parent_object_id = \(oid) ORDER BY name") {
            parts.append("  CONSTRAINT \(dialect.quoteIdentifier(row[0].displayString)) CHECK \(row[1].displayString)")
        }
        var statements = ["CREATE TABLE \(qualified) (\n\(parts.joined(separator: ",\n"))\n);"]
        let indexes = try await rows("""
            SELECT i.name, i.is_unique, i.type_desc,
                   STUFF((SELECT ', ' + QUOTENAME(c.name) + CASE WHEN ic.is_descending_key = 1 THEN ' DESC' ELSE '' END
                            FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                           WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
                           ORDER BY ic.key_ordinal FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, ''),
                   STUFF((SELECT ', ' + QUOTENAME(c.name)
                            FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                           WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1
                           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, ''),
                   i.filter_definition
              FROM sys.indexes i
             WHERE i.object_id = \(oid) AND i.index_id > 0 AND i.is_primary_key = 0 AND i.is_unique_constraint = 0 AND i.is_hypothetical = 0
               AND i.type IN (1, 2)
             ORDER BY i.name
            """)
        for row in indexes where row.count == 6 {
            var sql = "CREATE \(row[1] == .bool(true) ? "UNIQUE " : "")\(row[2].displayString) INDEX \(dialect.quoteIdentifier(row[0].displayString)) ON \(qualified) (\(row[3].displayString))"
            if !row[4].isNull { sql += " INCLUDE (\(row[4].displayString))" }
            if !row[5].isNull { sql += " WHERE \(row[5].displayString)" }
            statements.append(sql + ";")
        }
        for trigger in try await listTriggers(table: name, schema: schema) {
            statements.append(trigger.definition.trimmingCharacters(in: .whitespacesAndNewlines) + ";")
        }
        for key in try await listForeignKeys(table: name, schema: schema) {
            statements.append("ALTER TABLE \(qualified) ADD \(try dialect.foreignKeyClause(key, schema: schema));")
        }
        return statements.joined(separator: "\n\n")
    }
}
