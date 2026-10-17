import Foundation
import MySQLNIO
import NIOSSL

/// MySQL / MariaDB driver on `MySQLNIO`. MySQL has no schemas inside a database,
/// so the "schema" argument in the browser is the database name.
public actor MySQLDriver: DatabaseDriver {
    public nonisolated let config: ConnectionConfig
    private let password: String?
    private let secrets: ConnectionSecrets
    private var connection: MySQLConnection?
    /// The SSH tunnel (if any) the connection goes through; released on disconnect.
    private var endpoint: ConnectionEndpoint?
    /// `CONNECTION_ID()` of `connection`, for `KILL QUERY` from a second connection.
    public private(set) var connectionID: Int?

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
        await captureConnectionID()
    }

    /// A new connection to the server through `endpoint` (direct, socket file or SSH tunnel) with the SSL tab's settings.
    func openConnection(at endpoint: ConnectionEndpoint) async throws -> MySQLConnection {
        let tlsConfig: TLSConfiguration?
        let address: SocketAddress
        do {
            tlsConfig = try Self.tlsConfiguration(for: config, overTCP: endpoint.usesTLS, keyPassphrase: secrets.sslKeyPassphrase)
            switch endpoint.address {
            case .tcp(let host, let port): address = try SocketAddress.makeAddressResolvingHost(host, port: port)
            case .unixSocket(let path): address = try SocketAddress(unixDomainSocketPath: path)
            }
        } catch {
            throw DatabaseError.connectionFailed(ConnectionErrorText.describe(error))
        }
        let connection: MySQLConnection
        let open: @Sendable () async throws -> MySQLConnection = { try await Self.connectRetryingStalls { loop in
                MySQLConnection.connect(
                    to: address,
                    username: self.config.username,
                    database: self.config.database,
                    password: self.password,
                    tlsConfiguration: tlsConfig,
                    serverHostname: endpoint.tlsServerName,
                    logger: Logger(label: "BunnyGrid.MySQL"),
                    on: loop
                )
            } }
        do {
            do {
                connection = try await open()
            } catch let error as MySQLError where !(password ?? "").isEmpty && Self.mayNeedFullAuthentication(error) {
                // caching_sha2_password full authentication MySQLNIO can't do (socket without SSL, or RSA over TCP):
                // do it on a connection of our own, which fills the server's cache, then MySQLNIO's fast path works.
                var overSocket = false
                if case .unixSocket = endpoint.address { overSocket = true }
                do {
                    try await MySQLCachingSHA2.authenticate(address: address, username: config.username, password: password ?? "",
                                                            database: config.database, overSocket: overSocket)
                } catch {
                    throw DatabaseError.connectionFailed(error.localizedDescription)
                }
                connection = try await open()
            }
        } catch let error as MySQLError {
            throw DatabaseError.connectionFailed(Self.message(error))
        } catch {
            throw DatabaseError.connectionFailed(ConnectionErrorText.describe(error))
        }
        // MySQLNIO falls back to plain TCP when the server has no SSL; Require and Verify modes must not.
        if tlsConfig != nil, endpoint.usesTLS, config.tls.isEnforced,
           (try? await connection.channel.pipeline.containsHandler(type: NIOSSLClientHandler.self).get()) == nil {
            try? await connection.close().get()
            throw DatabaseError.connectionFailed(ConnectionTLSError.serverRefusedSSL(mode: config.tls).errorDescription ?? "")
        }
        return connection
    }

    /// The SSL tab's settings over TCP. Over a socket file the server already counts the transport as secure, so on a
    /// full `caching_sha2_password` authentication it expects the password in clear text, but MySQLNIO only sends it in
    /// clear over TLS (otherwise it asks for the RSA key, and the server reads that request as a wrong password).
    /// So socket connections use TLS without verification whenever the server offers it; client certificates still apply.
    static func tlsConfiguration(for config: ConnectionConfig, overTCP: Bool, keyPassphrase: String?) throws -> TLSConfiguration? {
        if overTCP { return try ConnectionTLS.configuration(for: config, keyPassphrase: keyPassphrase) }
        var local = config
        local.tls = .require
        return try ConnectionTLS.configuration(for: local, keyPassphrase: keyPassphrase)
    }

    /// Errors after which a full `caching_sha2_password` authentication of our own may help.
    static func mayNeedFullAuthentication(_ error: MySQLError) -> Bool {
        let text = "\(error)".lowercased()
        return text.contains("access denied") || text.contains("caching_sha2") || text.contains("public key") || text.contains("1045")
            || text.contains("authplugin") || text.contains("protocol")
    }

    struct HandshakeTimeout: LocalizedError {
        var errorDescription: String? { "Timed out waiting for the server's handshake." }
    }

    /// Root cause of the old "handshake stall": `MySQLConnection.connect` starts the TCP connect and only then, in a
    /// `flatMap` on the returned future, adds its handlers. Called from a thread other than the event loop, the
    /// connect can finish and the server's greeting be read (and dropped by the bare pipeline) before that callback is
    /// registered; the client then waits forever and the server drops it after `connect_timeout` ("Got timeout
    /// reading communication packets"). `withHandshakeTimeout` therefore calls `open` on the event loop itself.
    /// The timeout and one retry stay as a safety net.
    static func connectRetryingStalls(timeout: TimeAmount = .seconds(6), attempts: Int = 2,
                                      _ open: @escaping @Sendable (any EventLoop) -> EventLoopFuture<MySQLConnection>) async throws -> MySQLConnection {
        var attempt = 1
        while true {
            do {
                return try await withHandshakeTimeout(timeout, open)
            } catch is HandshakeTimeout where attempt < attempts {
                attempt += 1
            }
        }
    }

    private static func withHandshakeTimeout(_ timeout: TimeAmount,
                                             _ open: @escaping @Sendable (any EventLoop) -> EventLoopFuture<MySQLConnection>) async throws -> MySQLConnection {
        let loop = MultiThreadedEventLoopGroup.singleton.any()
        let promise = loop.makePromise(of: MySQLConnection.self)
        let timer = loop.scheduleTask(in: timeout) { promise.fail(HandshakeTimeout()) }
        loop.flatSubmit { open(loop) }.whenComplete { result in
            timer.cancel()
            switch result {
            case .success(let connection):
                // Completing an already timed-out promise is a no-op, so close the late connection instead.
                promise.futureResult.whenFailure { _ in _ = connection.close() }
                promise.succeed(connection)
            case .failure(let error):
                promise.fail(error)
            }
        }
        return try await promise.futureResult.get()
    }

    deinit {
        // MySQLNIO asserts that a connection is closed before it's released; keep it alive until the close finishes.
        if let connection, connection.channel.isActive {
            connection.close().whenComplete { _ in _ = connection }
        }
    }

    public func disconnect() async {
        try? await connection?.close().get()
        connection = nil
        await endpoint?.close()
        endpoint = nil
        connectionID = nil
    }

    private func captureConnectionID() async {
        switch try? await executeStatement("SELECT CONNECTION_ID()").rows.first?.first {
        case .integer(let id)?: connectionID = Int(id)
        case .text(let id)?: connectionID = Int(id)
        default: break
        }
    }

    /// Opens a short-lived second connection with the same settings and runs `KILL QUERY` on this
    /// connection's thread; the running statement fails with "Query execution was interrupted".
    public func cancelCurrentQuery() async throws {
        guard connection != nil, let connectionID else { return }
        // Same secrets, so the second connection goes through the same tunnel lease, socket and SSL settings.
        let canceller = MySQLDriver(config: config, secrets: secrets)
        try await canceller.connect()
        do {
            _ = try await canceller.executeStatement("KILL QUERY \(connectionID)")
        } catch {
            await canceller.disconnect()
            throw error
        }
        await canceller.disconnect()
    }

    public func serverVersion() async throws -> String {
        let version = try await executeStatement("SELECT VERSION()").rows.first?.first?.displayString ?? ""
        return "\(config.kind.displayName) \(version)"
    }

    public func listDatabases() async throws -> [String] {
        try await executeStatement("SHOW DATABASES").rows.compactMap { $0.first?.displayString }
    }

    /// Databases play the role of schemas in the browser tree.
    public func listSchemas() async throws -> [String] {
        try await listDatabases()
    }

    public func listObjects(schema: String?) async throws -> [DatabaseObject] {
        let db = schema ?? config.database
        let s = dialect.quoteLiteral(db)
        let result = try await executeStatement("""
            SELECT TABLE_NAME, IF(TABLE_TYPE = 'VIEW', 'view', 'table') AS kind
              FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(s)
            UNION ALL
            SELECT ROUTINE_NAME, 'routine' FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = \(s)
            ORDER BY 2, 1
            """)
        return result.rows.compactMap { row in
            guard row.count == 2 else { return nil }
            let kind: DatabaseObjectKind = switch row[1].displayString {
            case "view": .view
            case "routine": .routine
            default: .table
            }
            return DatabaseObject(schema: db, name: row[0].displayString, kind: kind)
        }
    }

    public func listColumns(table: String, schema: String?) async throws -> [TableColumn] {
        let result = try await executeStatement("""
            SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, ORDINAL_POSITION, COLUMN_KEY, EXTRA, COLUMN_COMMENT, DATA_TYPE, COLLATION_NAME
              FROM information_schema.COLUMNS
             WHERE TABLE_SCHEMA = \(dialect.quoteLiteral(schema ?? config.database))
               AND TABLE_NAME = \(dialect.quoteLiteral(table))
             ORDER BY ORDINAL_POSITION
            """)
        let kind = config.kind
        return result.rows.map { row in
            let extra = row[6].isNull ? "" : row[6].displayString
            return TableColumn(
                name: row[0].displayString,
                dataType: row[1].displayString,
                nullable: row[2] == .text("YES"),
                defaultValue: Self.defaultExpression(row[3].isNull ? nil : row[3].displayString, extra: extra,
                                                     dataType: row[8].displayString, kind: kind),
                isPrimaryKey: row[5] == .text("PRI"),
                ordinal: Int(row[4].displayString) ?? 0,
                // The comment and collation have fields of their own in the designer, which writes them back.
                extra: Self.preservedAttributes(extra: extra, comment: ""),
                comment: row[7].isNull || row[7].displayString.isEmpty ? nil : row[7].displayString,
                collation: row[9].isNull || row[9].displayString.isEmpty ? nil : row[9].displayString
            )
        }
    }

    /// `information_schema.COLUMNS.COLUMN_DEFAULT` as the SQL expression the designer writes after DEFAULT.
    /// MariaDB (10.2.7+) already stores SQL: `'text'` quoted, `current_timestamp()`, and the word `NULL` for no default.
    /// MySQL gives literals raw (`it's`) and flags expressions with `DEFAULT_GENERATED` in EXTRA.
    static func defaultExpression(_ raw: String?, extra: String, dataType: String, kind: DatabaseKind) -> String? {
        guard let raw else { return nil }
        if kind == .mariadb { return raw == "NULL" ? nil : raw }
        if extra.localizedCaseInsensitiveContains("DEFAULT_GENERATED") {
            let upper = raw.uppercased()
            let bare = ["CURRENT_TIMESTAMP", "NOW(", "LOCALTIME", "CURRENT_DATE", "CURRENT_TIME"].contains { upper.hasPrefix($0) }
            return bare ? raw : "(\(raw))"
        }
        let numeric = ["tinyint", "smallint", "mediumint", "int", "integer", "bigint", "decimal", "numeric", "float", "double", "real", "year"]
        if numeric.contains(dataType.lowercased()), Double(raw) != nil { return raw }
        if dataType.lowercased() == "bit", raw.hasPrefix("b'") { return raw }
        return "'" + raw.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// The EXTRA flags and comment that `MODIFY COLUMN` must repeat to keep them; generated columns and
    /// MySQL's DEFAULT_GENERATED marker aren't repeatable attributes, so they're left out.
    static func preservedAttributes(extra: String, comment: String) -> String? {
        var parts: [String] = []
        let flags = extra.lowercased()
        if flags.contains("auto_increment") { parts.append("AUTO_INCREMENT") }
        if let range = extra.range(of: "on update ", options: .caseInsensitive) {
            let rest = extra[range.upperBound...].split(separator: " ").first.map(String.init) ?? "CURRENT_TIMESTAMP"
            parts.append("ON UPDATE \(rest)")
        }
        if flags.split(separator: " ").contains("invisible") { parts.append("INVISIBLE") }
        if !comment.isEmpty {
            parts.append("COMMENT '" + comment.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''") + "'")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// MySQL prints the exact DDL with SHOW CREATE TABLE / VIEW / FUNCTION.
    public func objectDDL(name: String, kind: DatabaseObjectKind, schema: String?) async throws -> String {
        let qualified = dialect.qualifiedName(table: name, schema: schema)
        let sql: String = switch kind {
        case .table: "SHOW CREATE TABLE \(qualified)"
        case .view, .materializedView: "SHOW CREATE VIEW \(qualified)"
        case .routine: "SHOW CREATE FUNCTION \(qualified)"
        }
        let result = try await executeStatement(sql)
        let column = kind == .routine ? 2 : 1
        guard let row = result.rows.first, row.count > column else { return "" }
        return row[column].displayString + ";"
    }

    public func listForeignKeys(table: String, schema: String?) async throws -> [TableForeignKey] {
        let database = dialect.quoteLiteral(schema ?? config.database)
        let result = try await executeStatement("""
            SELECT k.CONSTRAINT_NAME, k.COLUMN_NAME, k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME,
                   r.DELETE_RULE, r.UPDATE_RULE
              FROM information_schema.KEY_COLUMN_USAGE k
              JOIN information_schema.REFERENTIAL_CONSTRAINTS r
                ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME
             WHERE k.TABLE_SCHEMA = \(database) AND k.TABLE_NAME = \(dialect.quoteLiteral(table)) AND k.REFERENCED_TABLE_NAME IS NOT NULL
             ORDER BY k.CONSTRAINT_NAME, k.ORDINAL_POSITION
            """)
        var keys: [String: TableForeignKey] = [:]
        var order: [String] = []
        for row in result.rows where row.count >= 7 {
            let name = row[0].displayString
            if keys[name] == nil {
                order.append(name)
                keys[name] = TableForeignKey(name: name, columns: [], referencedSchema: row[2].displayString, referencedTable: row[3].displayString,
                                             referencedColumns: [], onDelete: row[5].displayString, onUpdate: row[6].displayString)
            }
            keys[name]?.columns.append(row[1].displayString)
            keys[name]?.referencedColumns.append(row[4].displayString)
        }
        return order.compactMap { keys[$0] }
    }

    public func listTriggers(table: String, schema: String?) async throws -> [TableTrigger] {
        let result = try await executeStatement("""
            SELECT TRIGGER_NAME, ACTION_TIMING, EVENT_MANIPULATION, ACTION_STATEMENT
              FROM information_schema.TRIGGERS
             WHERE EVENT_OBJECT_SCHEMA = \(dialect.quoteLiteral(schema ?? config.database)) AND EVENT_OBJECT_TABLE = \(dialect.quoteLiteral(table))
             ORDER BY TRIGGER_NAME
            """)
        return result.rows.map { row in
            TableTrigger(name: row[0].displayString, timing: row[1].displayString, events: [row[2].displayString], definition: row[3].displayString)
        }
    }

    public func listIndexes(table: String, schema: String?) async throws -> [TableIndex] {
        let result = try await executeStatement("""
            SELECT INDEX_NAME, NOT NON_UNIQUE, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX)
              FROM information_schema.STATISTICS
             WHERE TABLE_SCHEMA = \(dialect.quoteLiteral(schema ?? config.database))
               AND TABLE_NAME = \(dialect.quoteLiteral(table))
             GROUP BY INDEX_NAME, NON_UNIQUE
             ORDER BY INDEX_NAME
            """)
        return result.rows.map { row in
            let name = row[0].displayString
            return TableIndex(
                name: name,
                columns: row[2].displayString.split(separator: ",").map(String.init),
                unique: row[1] == .integer(1),
                primary: name == "PRIMARY"
            )
        }
    }

    public func tableStatistics(schema: String?) async throws -> [String: TableStatistics] {
        let result = try await executeStatement("""
            SELECT TABLE_NAME, TABLE_ROWS, DATA_LENGTH + INDEX_LENGTH, TABLE_COMMENT, ENGINE, CREATE_TIME, UPDATE_TIME, TABLE_COLLATION
              FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(dialect.quoteLiteral(schema ?? config.database))
            """)
        var stats: [String: TableStatistics] = [:]
        for row in result.rows where row.count == 8 {
            func int(_ value: CellValue) -> Int? {
                switch value {
                case .integer(let v): Int(v)
                case .text(let s): Int(s)
                default: nil
                }
            }
            let comment = row[3].isNull || row[3].displayString.isEmpty ? nil : row[3].displayString
            stats[row[0].displayString] = TableStatistics(rows: int(row[1]), sizeBytes: int(row[2]), comment: comment,
                                                          engine: row[4].isNull ? nil : row[4].displayString,
                                                          created: row[5].isNull ? nil : row[5].displayString,
                                                          modified: row[6].isNull ? nil : row[6].displayString,
                                                          collation: row[7].isNull ? nil : row[7].displayString)
        }
        return stats
    }

    public func executeStatement(_ sql: String) async throws -> QueryResult {
        try await executeStatement(sql, maxRows: nil)
    }

    /// MySQLNIO has no backpressure: past `maxRows` the remaining rows still arrive, but are dropped as they do.
    public func executeStatement(_ sql: String, maxRows: Int?) async throws -> QueryResult {
        guard let connection else { throw DatabaseError.notConnected }
        let box = MetadataBox()
        do {
            try await connection.query(sql, onRow: { row in
                if let maxRows, box.rows.count >= max(maxRows, 0) {
                    box.truncated = true
                } else {
                    box.rows.append(row)
                }
            }, onMetadata: { box.affected = Int($0.affectedRows) }).get()
        } catch MySQLError.server(let packet) where packet.errorCode == .UNSUPPORTED_PS {
            // Some statements (CREATE TRIGGER/PROCEDURE, LOCK TABLES, USE, …) can't be prepared;
            // the text protocol runs them, without an affected-row count.
            do {
                try await connection.simpleQuery(sql, onRow: { row in
                    if let maxRows, box.rows.count >= max(maxRows, 0) {
                        box.truncated = true
                    } else {
                        box.rows.append(row)
                    }
                }).get()
            } catch {
                throw DatabaseError.queryFailed(Self.message(error))
            }
        } catch {
            throw DatabaseError.queryFailed(Self.message(error))
        }
        let rows = box.rows
        var columns = rows.first?.columnDefinitions.map(\.name) ?? []
        if rows.isEmpty, (box.affected ?? 0) == 0 {
            // No rows, so MySQLNIO gave no column definitions: ask the server for the statement's metadata.
            columns = await Self.describeColumns(sql, on: connection)
        }
        let values = rows.map { row in
            zip(row.columnDefinitions, row.values).map { definition, buffer in
                Self.value(definition: definition, buffer: buffer, format: row.format)
            }
        }
        return QueryResult(statement: sql, columns: columns, rows: values, affectedRows: columns.isEmpty ? box.affected : nil, isTruncated: box.truncated)
    }

    /// Result column names of `sql` from COM_STMT_PREPARE, without executing it; empty for statements without a
    /// result set or that can't be prepared.
    static func describeColumns(_ sql: String, on connection: MySQLConnection) async -> [String] {
        let command = MySQLDescribeCommand(sql: sql)
        do {
            try await connection.send(command, logger: connection.logger).get()
        } catch {
            return []
        }
        return command.columns.map(\.name)
    }

    // MARK: - Decoding

    /// The server's message without MySQLNIO's "MySQL error: Server error:" prefix.
    static func message(_ error: any Error) -> String {
        switch error {
        case MySQLError.server(let packet): packet.errorMessage
        case MySQLError.duplicateEntry(let message), MySQLError.invalidSyntax(let message): message
        default: String(describing: error)
        }
    }

    private static func value(definition: MySQLProtocol.ColumnDefinition41, buffer: ByteBuffer?, format: MySQLData.Format) -> CellValue {
        guard var buffer else { return .null }
        // Text-protocol temporals are already formatted by the server (and MySQLTime can't parse a bare date or time).
        if format == .text, [.date, .datetime, .timestamp, .time].contains(definition.columnType) {
            return .text(buffer.readString(length: buffer.readableBytes) ?? "")
        }
        if definition.columnType == .time {
            return .text(binaryTime(&buffer, decimals: definition.decimals))
        }
        let data = MySQLData(
            type: definition.columnType,
            format: format,
            buffer: buffer,
            isUnsigned: definition.flags.contains(.COLUMN_UNSIGNED)
        )
        switch definition.columnType {
        case .year where format == .binary:
            // Binary YEAR is a 2-byte integer that MySQLData doesn't decode.
            return buffer.readInteger(endianness: .little, as: UInt16.self).map { .integer(Int64($0)) } ?? .null
        case .tiny, .short, .int24, .long, .longlong, .year:
            if data.isUnsigned, let u = data.uint64, u > UInt64(Int64.max) { return .text(String(u)) }
            return data.int64.map(CellValue.integer) ?? .null
        case .float, .double:
            return data.double.map(CellValue.double) ?? .null
        case .date, .datetime, .timestamp, .time:
            return data.time.map { .text(formatTime($0, type: definition.columnType, decimals: definition.decimals)) } ?? .null
        case .blob, .tinyBlob, .mediumBlob, .longBlob, .string, .varString, .varchar, .geometry, .bit:
            if definition.characterSet == .binary {
                return .blob(Data(buffer.readBytes(length: buffer.readableBytes) ?? []))
            }
            return .text(buffer.readString(length: buffer.readableBytes) ?? "")
        default:
            return .text(buffer.readString(length: buffer.readableBytes) ?? "")
        }
    }

    private static func formatTime(_ time: MySQLTime, type: MySQLProtocol.DataType, decimals: UInt8) -> String {
        func pad(_ v: UInt16?, _ width: Int = 2) -> String {
            let s = String(v ?? 0)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        let date = "\(pad(time.year, 4))-\(pad(time.month))-\(pad(time.day))"
        var clock = "\(pad(time.hour)):\(pad(time.minute)):\(pad(time.second))"
        clock += fraction(time.microsecond ?? 0, decimals: decimals)
        switch type {
        case .date: return date
        case .time: return clock
        default: return "\(date) \(clock)"
        }
    }

    // MARK: - Bound parameters

    /// `?` placeholders through a prepared statement: integers, doubles, booleans and blobs in binary,
    /// DATE / DATETIME / TIMESTAMP as MySQL time values, everything else as strings.
    public func executeStatement(_ sql: String, parameters: [SQLParameter]) async throws -> QueryResult {
        guard !parameters.isEmpty else { return try await executeStatement(sql) }
        guard let connection else { throw DatabaseError.notConnected }
        let binds = parameters.map(Self.data)
        let box = MetadataBox()
        let rows: [MySQLRow]
        do {
            rows = try await connection.query(sql, binds, onMetadata: { box.affected = Int($0.affectedRows) }).get()
        } catch {
            throw DatabaseError.queryFailed(Self.message(error))
        }
        let columns = rows.first?.columnDefinitions.map(\.name) ?? []
        let values = rows.map { row in
            zip(row.columnDefinitions, row.values).map { definition, buffer in
                Self.value(definition: definition, buffer: buffer, format: row.format)
            }
        }
        return QueryResult(statement: sql, columns: columns, rows: values, affectedRows: columns.isEmpty ? box.affected : nil)
    }

    private static func data(_ parameter: SQLParameter) -> MySQLData {
        switch parameter {
        case .null: return .null
        case .integer(let v): return MySQLData(int: Int(v))
        case .double(let v): return MySQLData(double: v)
        case .bool(let v): return MySQLData(bool: v)
        case .text(let v), .untyped(let v): return MySQLData(string: v)
        case .blob(let data):
            return MySQLData(type: .blob, format: .binary, buffer: ByteBuffer(bytes: data), isUnsigned: false)
        case .typed(let v, let category):
            switch category {
            case .date:
                let parts = v.split(separator: "-").compactMap { UInt16($0) }
                if parts.count == 3 { return MySQLData(time: MySQLTime(year: parts[0], month: parts[1], day: parts[2])) }
            case .dateTime, .dateTimeWithTimeZone:
                if let time = MySQLTime(v) { return MySQLData(time: time) }
            default:
                break
            }
            return MySQLData(string: v)
        }
    }

    /// Binary TIME: sign, days, hours, minutes, seconds and optional microseconds, so `-838:59:59` and
    /// durations over a day survive (MySQLNIO's MySQLTime drops the days and the sign).
    static func binaryTime(_ buffer: inout ByteBuffer, decimals: UInt8 = 0) -> String {
        guard buffer.readableBytes >= 8,
              let negative = buffer.readInteger(as: UInt8.self),
              let days = buffer.readInteger(endianness: .little, as: UInt32.self),
              let hours = buffer.readInteger(as: UInt8.self),
              let minutes = buffer.readInteger(as: UInt8.self),
              let seconds = buffer.readInteger(as: UInt8.self) else { return "00:00:00" }
        let micro = buffer.readInteger(endianness: .little, as: UInt32.self) ?? 0
        func two(_ v: UInt8) -> String { v < 10 ? "0\(v)" : "\(v)" }
        let totalHours = Int(days) * 24 + Int(hours)
        var text = (negative == 1 ? "-" : "") + (totalHours < 10 ? "0\(totalHours)" : "\(totalHours)") + ":\(two(minutes)):\(two(seconds))"
        return text + fraction(micro, decimals: decimals)
    }

    /// ".120" for 120000 µs in a column with 3 fractional digits, as the text protocol prints it;
    /// empty for columns without fractional seconds.
    static func fraction(_ micro: UInt32, decimals: UInt8) -> String {
        let digits = (1...6).contains(decimals) ? Int(decimals) : (micro > 0 ? 6 : 0)
        guard digits > 0 else { return "" }
        let six = String(micro)
        return "." + String((String(repeating: "0", count: max(0, 6 - six.count)) + six).prefix(digits))
    }
}

/// Collects the rows and OK-packet metadata reported on the event loop.
private final class MetadataBox: @unchecked Sendable {
    var affected: Int?
    var rows: [MySQLRow] = []
    var truncated = false
}
