import Foundation
import PostgresNIO

/// PostgreSQL driver on `PostgresNIO`. Uses one dedicated connection per session so
/// session state (search_path, transactions) behaves like a regular SQL console.
public actor PostgresDriver: DatabaseDriver {
    public nonisolated let config: ConnectionConfig
    private let password: String?
    private let secrets: ConnectionSecrets
    private var connection: PostgresConnection?
    /// The SSH tunnel (if any) the connection goes through; released on disconnect.
    private var endpoint: ConnectionEndpoint?
    /// `pg_backend_pid()` of `connection`, for `pg_cancel_backend` from a second connection.
    public private(set) var backendPID: Int?
    private let logger = Logger(label: "BunnyGrid.Postgres")

    public init(config: ConnectionConfig, password: String?) {
        self.init(config: config, secrets: ConnectionSecrets(password: password))
    }

    public init(config: ConnectionConfig, secrets: ConnectionSecrets) {
        self.config = config
        self.password = secrets.password
        self.secrets = secrets
    }

    public func connect() async throws {
        guard connection == nil else { return }
        let endpoint = try await ConnectionEndpoint.open(for: config, sshSecret: secrets.sshSecret)
        do {
            connection = try await openConnection(at: endpoint)
            self.endpoint = endpoint
        } catch {
            await endpoint.close()
            throw error
        }
        await captureBackendPID()
    }

    /// A new connection to the server through `endpoint` (direct, socket file or SSH tunnel) with the SSL tab's settings.
    func openConnection(at endpoint: ConnectionEndpoint, id: Int = 1) async throws -> PostgresConnection {
        var configuration: PostgresConnection.Configuration
        let database = config.database.isEmpty ? nil : config.database
        switch endpoint.address {
        case .unixSocket(let path):
            // Like libpq, SSL doesn't apply to socket files.
            configuration = .init(unixSocketPath: path, username: config.username, password: password, database: database)
        case .tcp(let host, let port):
            let tls: PostgresConnection.Configuration.TLS
            do {
                if let tlsConfig = try ConnectionTLS.configuration(for: config, keyPassphrase: secrets.sslKeyPassphrase) {
                    let context = try NIOSSLContext(configuration: tlsConfig)
                    tls = config.tls.isEnforced ? .require(context) : .prefer(context)
                } else {
                    tls = .disable
                }
            } catch {
                throw DatabaseError.connectionFailed(ConnectionErrorText.describe(error))
            }
            configuration = .init(host: host, port: port, username: config.username, password: password, database: database, tls: tls)
            configuration.options.tlsServerName = endpoint.tlsServerName
        }
        configuration.options.connectTimeout = .seconds(15)
        do {
            return try await PostgresConnection.connect(
                on: MultiThreadedEventLoopGroup.singleton.any(),
                configuration: configuration,
                id: id,
                logger: logger
            ).get()
        } catch {
            throw DatabaseError.connectionFailed(Self.connectMessage(for: error, mode: config.tls))
        }
    }

    public func disconnect() async {
        try? await connection?.close().get()
        connection = nil
        await endpoint?.close()
        endpoint = nil
        backendPID = nil
    }

    private func captureBackendPID() async {
        if case .integer(let pid)? = try? await executeStatement("SELECT pg_backend_pid()").rows.first?.first {
            backendPID = Int(pid)
        }
    }

    /// Opens a short-lived second connection (same settings, so through the same tunnel or TLS) and runs
    /// `pg_cancel_backend` on this connection's backend. The actor is free meanwhile: a running statement
    /// is suspended on the network, not holding it.
    public func cancelCurrentQuery() async throws {
        guard connection != nil, let backendPID else { return }
        // Same secrets, so the second connection goes through the same tunnel lease, socket and SSL settings.
        let canceller = PostgresDriver(config: config, secrets: secrets)
        try await canceller.connect()
        do {
            _ = try await canceller.executeStatement("SELECT pg_cancel_backend(\(backendPID))")
        } catch {
            await canceller.disconnect()
            throw error
        }
        await canceller.disconnect()
    }

    public func serverVersion() async throws -> String {
        try await executeStatement("SELECT version()").rows.first?.first?.displayString ?? "PostgreSQL"
    }

    public func listDatabases() async throws -> [String] {
        try await column("SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY datname")
    }

    public func listSchemas() async throws -> [String] {
        try await column("""
            SELECT nspname FROM pg_namespace
            WHERE nspname NOT LIKE 'pg\\_temp\\_%' AND nspname NOT LIKE 'pg\\_toast\\_temp\\_%'
            ORDER BY nspname
            """)
    }

    public func listObjects(schema: String?) async throws -> [DatabaseObject] {
        let schema = schema ?? "public"
        let s = dialect.quoteLiteral(schema)
        let result = try await executeStatement("""
            SELECT table_name, CASE table_type WHEN 'VIEW' THEN 'view' ELSE 'table' END
              FROM information_schema.tables
             WHERE table_schema = \(s) AND table_type IN ('BASE TABLE', 'VIEW', 'FOREIGN')
            UNION ALL
            SELECT matviewname, 'matview' FROM pg_matviews WHERE schemaname = \(s)
            UNION ALL
            SELECT DISTINCT routine_name, 'routine' FROM information_schema.routines
             WHERE routine_schema = \(s)
            ORDER BY 2, 1
            """)
        return result.rows.compactMap { row in
            guard row.count == 2 else { return nil }
            let kind: DatabaseObjectKind = switch row[1].displayString {
            case "view": .view
            case "matview": .materializedView
            case "routine": .routine
            default: .table
            }
            return DatabaseObject(schema: schema, name: row[0].displayString, kind: kind)
        }
    }

    public func listColumns(table: String, schema: String?) async throws -> [TableColumn] {
        let s = dialect.quoteLiteral(schema ?? "public")
        let t = dialect.quoteLiteral(table)
        let result = try await executeStatement("""
            SELECT c.column_name,
                   -- Short type names with modifiers, as Navicat shows them: int4, numeric(5,2), timestamp(6)
                   CASE
                     WHEN c.udt_name = 'numeric' AND c.numeric_precision IS NOT NULL
                       THEN 'numeric(' || c.numeric_precision || ',' || c.numeric_scale || ')'
                     WHEN c.character_maximum_length IS NOT NULL
                       THEN c.udt_name || '(' || c.character_maximum_length || ')'
                     WHEN c.udt_name IN ('timestamp', 'timestamptz', 'time', 'timetz') AND c.datetime_precision IS NOT NULL
                       THEN c.udt_name || '(' || c.datetime_precision || ')'
                     ELSE c.udt_name
                   END,
                   c.is_nullable, c.column_default, c.ordinal_position,
                   EXISTS (
                     SELECT 1 FROM information_schema.table_constraints tc
                       JOIN information_schema.key_column_usage k
                         ON k.constraint_name = tc.constraint_name AND k.table_schema = tc.table_schema
                      WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_schema = c.table_schema
                        AND tc.table_name = c.table_name AND k.column_name = c.column_name
                   )
              FROM information_schema.columns c
             WHERE c.table_schema = \(s) AND c.table_name = \(t)
             ORDER BY c.ordinal_position
            """)
        return result.rows.map { row in
            TableColumn(
                name: row[0].displayString,
                dataType: row[1].displayString,
                nullable: row[2] == .text("YES"),
                defaultValue: row[3].isNull ? nil : row[3].displayString,
                isPrimaryKey: row[5] == .bool(true),
                ordinal: Int(row[4].displayString) ?? 0
            )
        }
    }

    /// Views and functions come from pg_get_viewdef / pg_get_functiondef; tables are rebuilt from the catalog.
    public func objectDDL(name: String, kind: DatabaseObjectKind, schema: String?) async throws -> String {
        let qualified = dialect.qualifiedName(table: name, schema: schema)
        switch kind {
        case .table:
            return try await tableDDL(name: name, schema: schema)
        case .view, .materializedView:
            let result = try await executeStatement("SELECT pg_get_viewdef(\(dialect.quoteLiteral(qualified))::regclass, true)")
            let body = result.rows.first?.first?.displayString ?? ""
            return "CREATE \(kind == .materializedView ? "MATERIALIZED " : "")VIEW \(qualified) AS\n\(body)"
        case .routine:
            let result = try await executeStatement("""
                SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                 WHERE p.proname = \(dialect.quoteLiteral(name)) AND n.nspname = \(dialect.quoteLiteral(schema ?? "public")) LIMIT 1
                """)
            return result.rows.first?.first?.displayString ?? ""
        }
    }

    /// CREATE TABLE assembled from the catalog, as pg_dump writes it: columns with primary key, unique, check and
    /// exclusion constraints inline; then indexes, comments and triggers; foreign keys last as ALTER TABLE so a
    /// script of several tables runs in any order.
    func tableDDL(name: String, schema: String?) async throws -> String {
        let qualified = dialect.qualifiedName(table: name, schema: schema ?? "public")
        let regclass = "\(dialect.quoteLiteral(qualified))::regclass"
        let columns = try await listColumns(table: name, schema: schema ?? "public")
        var parts = columns.map { "  " + dialect.columnDefinition(ColumnDesign($0)) }
        let constraints = try await executeStatement("""
            SELECT conname, contype::text, pg_get_constraintdef(oid, true)
              FROM pg_constraint WHERE conrelid = \(regclass) AND contype IN ('p', 'u', 'c', 'x', 'f')
             ORDER BY CASE contype WHEN 'p' THEN 0 WHEN 'u' THEN 1 WHEN 'c' THEN 2 WHEN 'x' THEN 3 ELSE 4 END, conname
            """).rows
        var foreignKeys: [String] = []
        for row in constraints where row.count == 3 {
            let clause = "CONSTRAINT \(dialect.quoteIdentifier(row[0].displayString)) \(row[2].displayString)"
            if row[1].displayString == "f" {
                foreignKeys.append("ALTER TABLE \(qualified) ADD \(clause);")
            } else {
                parts.append("  " + clause)
            }
        }
        var statements = ["CREATE TABLE \(qualified) (\n\(parts.joined(separator: ",\n"))\n);"]
        // Indexes that don't back a constraint of this table (those come with the constraint).
        let indexes = try await executeStatement("""
            SELECT pg_get_indexdef(i.indexrelid) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
             WHERE i.indrelid = \(regclass)
               AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = i.indexrelid AND k.conrelid = i.indrelid AND k.contype IN ('p', 'u', 'x'))
             ORDER BY c.relname
            """).rows
        statements += indexes.compactMap { $0.first.map { $0.displayString + ";" } }
        let comments = try await executeStatement("""
            SELECT NULL::text, obj_description(\(regclass), 'pg_class')
            UNION ALL
            SELECT a.attname::text, col_description(a.attrelid, a.attnum) FROM pg_attribute a
             WHERE a.attrelid = \(regclass) AND a.attnum > 0 AND NOT a.attisdropped AND col_description(a.attrelid, a.attnum) IS NOT NULL
            """).rows
        for row in comments where row.count == 2 && !row[1].isNull {
            let target = row[0].isNull ? "TABLE \(qualified)" : "COLUMN \(qualified).\(dialect.quoteIdentifier(row[0].displayString))"
            statements.append("COMMENT ON \(target) IS \(dialect.quoteLiteral(row[1].displayString));")
        }
        statements += try await listTriggers(table: name, schema: schema ?? "public").map { $0.definition + ";" }
        statements += foreignKeys
        return statements.joined(separator: "\n\n")
    }

    public func listForeignKeys(table: String, schema: String?) async throws -> [TableForeignKey] {
        let result = try await executeStatement("""
            SELECT c.conname, rn.nspname, r.relname,
                   array_to_string(ARRAY(SELECT a.attname FROM unnest(c.conkey) WITH ORDINALITY k(n, o)
                     JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.n ORDER BY k.o), chr(31)),
                   array_to_string(ARRAY(SELECT a.attname FROM unnest(c.confkey) WITH ORDINALITY k(n, o)
                     JOIN pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = k.n ORDER BY k.o), chr(31)),
                   c.confdeltype::text, c.confupdtype::text
              FROM pg_constraint c
              JOIN pg_class t ON t.oid = c.conrelid
              JOIN pg_namespace n ON n.oid = t.relnamespace
              JOIN pg_class r ON r.oid = c.confrelid
              JOIN pg_namespace rn ON rn.oid = r.relnamespace
             WHERE c.contype = 'f' AND t.relname = \(dialect.quoteLiteral(table)) AND n.nspname = \(dialect.quoteLiteral(schema ?? "public"))
             ORDER BY c.conname
            """)
        func action(_ code: String) -> String {
            switch code {
            case "c": "CASCADE"
            case "n": "SET NULL"
            case "d": "SET DEFAULT"
            case "r": "RESTRICT"
            default: "NO ACTION"
            }
        }
        return result.rows.map { row in
            TableForeignKey(name: row[0].displayString, columns: row[3].displayString.split(separator: "\u{1F}").map(String.init),
                            referencedSchema: row[1].displayString, referencedTable: row[2].displayString,
                            referencedColumns: row[4].displayString.split(separator: "\u{1F}").map(String.init),
                            onDelete: action(row[5].displayString), onUpdate: action(row[6].displayString))
        }
    }

    public func listTriggers(table: String, schema: String?) async throws -> [TableTrigger] {
        let result = try await executeStatement("""
            SELECT tg.tgname, pg_get_triggerdef(tg.oid, true), tg.tgtype
              FROM pg_trigger tg
              JOIN pg_class t ON t.oid = tg.tgrelid
              JOIN pg_namespace n ON n.oid = t.relnamespace
             WHERE NOT tg.tgisinternal AND t.relname = \(dialect.quoteLiteral(table)) AND n.nspname = \(dialect.quoteLiteral(schema ?? "public"))
             ORDER BY tg.tgname
            """)
        return result.rows.map { row in
            let definition = row[1].displayString
            let upper = definition.uppercased()
            let timing = upper.contains(" INSTEAD OF ") ? "INSTEAD OF" : (upper.contains(" BEFORE ") ? "BEFORE" : "AFTER")
            let events = ["INSERT", "UPDATE", "DELETE", "TRUNCATE"].filter { upper.contains(" \($0)") }
            return TableTrigger(name: row[0].displayString, timing: timing, events: events, definition: definition)
        }
    }

    public func listIndexes(table: String, schema: String?) async throws -> [TableIndex] {
        let result = try await executeStatement("""
            SELECT i.relname, ix.indisunique, ix.indisprimary,
                   array_to_string(ARRAY(
                     SELECT a.attname FROM unnest(ix.indkey) WITH ORDINALITY AS k(attnum, ord)
                       JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
                      ORDER BY k.ord), ',')
              FROM pg_index ix
              JOIN pg_class t ON t.oid = ix.indrelid
              JOIN pg_class i ON i.oid = ix.indexrelid
              JOIN pg_namespace n ON n.oid = t.relnamespace
             WHERE t.relname = \(dialect.quoteLiteral(table)) AND n.nspname = \(dialect.quoteLiteral(schema ?? "public"))
             ORDER BY i.relname
            """)
        return result.rows.map { row in
            TableIndex(
                name: row[0].displayString,
                columns: row[3].displayString.split(separator: ",").map(String.init),
                unique: row[1] == .bool(true),
                primary: row[2] == .bool(true)
            )
        }
    }

    public func tableStatistics(schema: String?) async throws -> [String: TableStatistics] {
        let result = try await executeStatement("""
            SELECT c.relname, c.reltuples::bigint, pg_total_relation_size(c.oid), obj_description(c.oid, 'pg_class')
              FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = \(dialect.quoteLiteral(schema ?? "public")) AND c.relkind IN ('r', 'p', 'm', 'v', 'f')
            """)
        var stats: [String: TableStatistics] = [:]
        for row in result.rows where row.count == 4 {
            var rows: Int?
            if case .integer(let estimate) = row[1], estimate >= 0 { rows = Int(estimate) }
            var size: Int?
            if case .integer(let bytes) = row[2] { size = Int(bytes) }
            stats[row[0].displayString] = TableStatistics(rows: rows, sizeBytes: size, comment: row[3].isNull ? nil : row[3].displayString)
        }
        // Tables never analyzed have no estimate (-1); count the small ones exactly, as an estimate would be.
        for (name, stat) in stats where stat.rows == nil && (stat.sizeBytes ?? 0) > 0 && (stat.sizeBytes ?? 0) < 32 * 1024 * 1024 {
            if let value = try? await executeStatement("SELECT COUNT(*) FROM \(dialect.qualifiedName(table: name, schema: schema ?? "public"))").rows.first?.first,
               case .integer(let count) = value {
                stats[name]?.rows = Int(count)
            }
        }
        return stats
    }

    public func executeStatement(_ sql: String) async throws -> QueryResult {
        try await executeStatement(sql, maxRows: nil)
    }

    public func executeStatement(_ sql: String, maxRows: Int?) async throws -> QueryResult {
        guard let connection else { throw DatabaseError.notConnected }
        do {
            if !Self.isReadOnlyStatement(sql) {
                // The future-based API exposes the command tag, which carries the affected row count.
                // Its rows don't carry column names when empty, so reads use the streaming API below.
                let future: EventLoopFuture<PostgresQueryResult> = connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
                let result = try await future.get()
                let columns = result.rows.first.map { $0.map(\.columnName) } ?? []
                return QueryResult.capped(QueryResult(
                    statement: sql,
                    columns: columns,
                    rows: result.rows.map { $0.map(Self.value) },
                    affectedRows: columns.isEmpty ? result.metadata.rows : nil
                ), maxRows: maxRows)
            }
            let sequence = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
            let columns = sequence.columns.map(\.name)
            var rows: [[CellValue]] = []
            var truncated = false
            for try await row in sequence {
                // Leaving the loop drops the stream: PostgresNIO discards the remaining rows as they arrive.
                if let maxRows, rows.count >= max(maxRows, 0) {
                    truncated = true
                    break
                }
                rows.append(row.map(Self.value))
            }
            return QueryResult(statement: sql, columns: columns, rows: rows, isTruncated: truncated)
        } catch {
            throw DatabaseError.queryFailed(Self.message(for: error))
        }
    }

    private func column(_ sql: String) async throws -> [String] {
        try await executeStatement(sql).rows.compactMap { $0.first?.displayString }
    }

    // MARK: - Decoding

    private static func value(_ cell: PostgresCell) -> CellValue {
        guard cell.bytes != nil else { return .null }
        if cell.format == .text, var bytes = cell.bytes {
            return .text(bytes.readString(length: bytes.readableBytes) ?? "")
        }
        switch cell.dataType {
        case .bool:
            return (try? cell.decode(Bool.self)).map(CellValue.bool) ?? .null
        case .int2, .int4, .int8, .oid:
            return (try? cell.decode(Int64.self)).map(CellValue.integer) ?? .null
        case .float4, .float8:
            return (try? cell.decode(Double.self)).map(CellValue.double) ?? .null
        case .numeric:
            return (try? cell.decode(Decimal.self)).map { .text("\($0)") } ?? fallback(cell)
        case .uuid:
            return (try? cell.decode(UUID.self)).map { .text($0.uuidString.lowercased()) } ?? fallback(cell)
        case .timestamptz:
            return (try? cell.decode(Date.self)).map { .text(timestampTZFormat.format($0)) } ?? fallback(cell)
        case .timestamp:
            return (try? cell.decode(Date.self)).map { .text(timestampFormat.format($0)) } ?? fallback(cell)
        case .date:
            return (try? cell.decode(Date.self)).map { .text(dateFormat.format($0)) } ?? fallback(cell)
        case .bytea:
            guard var bytes = cell.bytes else { return .null }
            return .blob(Data(bytes.readBytes(length: bytes.readableBytes) ?? []))
        case .jsonb:
            // Binary jsonb is a version byte followed by the JSON text.
            guard var bytes = cell.bytes else { return .null }
            _ = bytes.readInteger(as: UInt8.self)
            return .text(bytes.readString(length: bytes.readableBytes) ?? "")
        default:
            return fallback(cell)
        }
    }

    private static func fallback(_ cell: PostgresCell) -> CellValue {
        if let string = try? cell.decode(String.self) { return .text(string) }
        return .text("<\(cell.dataType)>")
    }

    private static let timestampFormat = Date.ISO8601FormatStyle(timeZone: .gmt)
        .year().month().day().dateTimeSeparator(.space).time(includingFractionalSeconds: false)
    /// Local time with its offset, like psql: 2026-10-16 19:57:39-03:00.
    private static let timestampTZFormat = Date.ISO8601FormatStyle(timeZone: .current)
        .year().month().day().dateTimeSeparator(.space).time(includingFractionalSeconds: false).timeZone(separator: .colon)
    private static let dateFormat = Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()

    /// Connection errors: server messages, SSL refusals and handshake failures in words.
    private static func connectMessage(for error: any Error, mode: TLSMode) -> String {
        if let psql = error as? PSQLError {
            if let serverMessage = psql.serverInfo?[.message] { return serverMessage }
            if psql.code == .sslUnsupported {
                return ConnectionTLSError.serverRefusedSSL(mode: mode).errorDescription ?? "SSL is not supported by the server."
            }
            if let underlying = psql.underlying { return ConnectionErrorText.describe(underlying) }
            return String(reflecting: psql.code)
        }
        return ConnectionErrorText.describe(error)
    }

    private static func message(for error: any Error) -> String {
        if let psql = error as? PSQLError {
            if let serverMessage = psql.serverInfo?[.message] { return serverMessage }
            return String(reflecting: psql.code)
        }
        return error.localizedDescription
    }
}
