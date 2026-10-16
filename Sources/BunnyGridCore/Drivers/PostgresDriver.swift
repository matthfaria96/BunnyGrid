import Foundation
import PostgresNIO

/// PostgreSQL driver on `PostgresNIO`. Uses one dedicated connection per session so
/// session state (search_path, transactions) behaves like a regular SQL console.
public actor PostgresDriver: DatabaseDriver {
    public nonisolated let config: ConnectionConfig
    private let password: String?
    private var connection: PostgresConnection?
    private let logger = Logger(label: "BunnyGrid.Postgres")

    public init(config: ConnectionConfig, password: String?) {
        self.config = config
        self.password = password
    }

    public func connect() async throws {
        guard connection == nil else { return }
        let tls: PostgresConnection.Configuration.TLS
        do {
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            // Same semantics as libpq's sslmode=prefer/require: encrypt without verifying the chain.
            tlsConfig.certificateVerification = .none
            switch config.tls {
            case .disable: tls = .disable
            case .prefer: tls = .prefer(try NIOSSLContext(configuration: tlsConfig))
            case .require: tls = .require(try NIOSSLContext(configuration: tlsConfig))
            }
        } catch {
            throw DatabaseError.connectionFailed(error.localizedDescription)
        }

        let configuration = PostgresConnection.Configuration(
            host: config.host,
            port: config.port,
            username: config.username,
            password: password,
            database: config.database.isEmpty ? nil : config.database,
            tls: tls
        )
        do {
            connection = try await PostgresConnection.connect(
                on: MultiThreadedEventLoopGroup.singleton.any(),
                configuration: configuration,
                id: 1,
                logger: logger
            ).get()
        } catch {
            throw DatabaseError.connectionFailed(Self.message(for: error))
        }
    }

    public func disconnect() async {
        try? await connection?.close().get()
        connection = nil
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
        guard let connection else { throw DatabaseError.notConnected }
        do {
            if !Self.isReadOnlyStatement(sql) {
                // The future-based API exposes the command tag, which carries the affected row count.
                // Its rows don't carry column names when empty, so reads use the streaming API below.
                let future: EventLoopFuture<PostgresQueryResult> = connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
                let result = try await future.get()
                let columns = result.rows.first.map { $0.map(\.columnName) } ?? []
                return QueryResult(
                    statement: sql,
                    columns: columns,
                    rows: result.rows.map { $0.map(Self.value) },
                    affectedRows: columns.isEmpty ? result.metadata.rows : nil
                )
            }
            let sequence = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
            let columns = sequence.columns.map(\.name)
            var rows: [[CellValue]] = []
            for try await row in sequence {
                rows.append(row.map(Self.value))
            }
            return QueryResult(statement: sql, columns: columns, rows: rows)
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

    private static func message(for error: any Error) -> String {
        if let psql = error as? PSQLError {
            if let serverMessage = psql.serverInfo?[.message] { return serverMessage }
            return String(reflecting: psql.code)
        }
        return error.localizedDescription
    }
}
