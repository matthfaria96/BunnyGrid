import Foundation
import MySQLNIO

/// MySQL / MariaDB driver on `MySQLNIO`. MySQL has no schemas inside a database,
/// so the "schema" argument in the browser is the database name.
public actor MySQLDriver: DatabaseDriver {
    public nonisolated let config: ConnectionConfig
    private let password: String?
    private var connection: MySQLConnection?

    public init(config: ConnectionConfig, password: String?) {
        self.config = config
        self.password = password
    }

    public func connect() async throws {
        guard connection == nil else { return }
        var tlsConfig: TLSConfiguration?
        if config.tls != .disable {
            var tls = TLSConfiguration.makeClientConfiguration()
            tls.certificateVerification = .none
            tlsConfig = tls
        }
        do {
            let address = try SocketAddress.makeAddressResolvingHost(config.host, port: config.port)
            connection = try await MySQLConnection.connect(
                to: address,
                username: config.username,
                database: config.database,
                password: password,
                tlsConfiguration: tlsConfig,
                serverHostname: config.host,
                logger: Logger(label: "BunnyGrid.MySQL"),
                on: MultiThreadedEventLoopGroup.singleton.any()
            ).get()
        } catch {
            throw DatabaseError.connectionFailed(String(describing: error))
        }
    }

    public func disconnect() async {
        try? await connection?.close().get()
        connection = nil
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
            SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, ORDINAL_POSITION, COLUMN_KEY
              FROM information_schema.COLUMNS
             WHERE TABLE_SCHEMA = \(dialect.quoteLiteral(schema ?? config.database))
               AND TABLE_NAME = \(dialect.quoteLiteral(table))
             ORDER BY ORDINAL_POSITION
            """)
        return result.rows.map { row in
            TableColumn(
                name: row[0].displayString,
                dataType: row[1].displayString,
                nullable: row[2] == .text("YES"),
                defaultValue: row[3].isNull ? nil : row[3].displayString,
                isPrimaryKey: row[5] == .text("PRI"),
                ordinal: Int(row[4].displayString) ?? 0
            )
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

    public func executeStatement(_ sql: String) async throws -> QueryResult {
        guard let connection else { throw DatabaseError.notConnected }
        let box = MetadataBox()
        let rows: [MySQLRow]
        do {
            rows = try await connection.query(sql, onMetadata: { box.affected = Int($0.affectedRows) }).get()
        } catch {
            throw DatabaseError.queryFailed(String(describing: error))
        }
        let columns = rows.first?.columnDefinitions.map(\.name) ?? []
        let values = rows.map { row in
            zip(row.columnDefinitions, row.values).map { definition, buffer in
                Self.value(definition: definition, buffer: buffer, format: row.format)
            }
        }
        return QueryResult(statement: sql, columns: columns, rows: values, affectedRows: columns.isEmpty ? box.affected : nil)
    }

    // MARK: - Decoding

    private static func value(definition: MySQLProtocol.ColumnDefinition41, buffer: ByteBuffer?, format: MySQLData.Format) -> CellValue {
        guard var buffer else { return .null }
        let data = MySQLData(
            type: definition.columnType,
            format: format,
            buffer: buffer,
            isUnsigned: definition.flags.contains(.COLUMN_UNSIGNED)
        )
        switch definition.columnType {
        case .tiny, .short, .int24, .long, .longlong, .year:
            if data.isUnsigned, let u = data.uint64, u > UInt64(Int64.max) { return .text(String(u)) }
            return data.int64.map(CellValue.integer) ?? .null
        case .float, .double:
            return data.double.map(CellValue.double) ?? .null
        case .date, .datetime, .timestamp, .time:
            return data.time.map { .text(formatTime($0, type: definition.columnType)) } ?? .null
        case .blob, .tinyBlob, .mediumBlob, .longBlob, .string, .varString, .varchar, .geometry, .bit:
            if definition.characterSet == .binary {
                return .blob(Data(buffer.readBytes(length: buffer.readableBytes) ?? []))
            }
            return .text(buffer.readString(length: buffer.readableBytes) ?? "")
        default:
            return .text(buffer.readString(length: buffer.readableBytes) ?? "")
        }
    }

    private static func formatTime(_ time: MySQLTime, type: MySQLProtocol.DataType) -> String {
        func pad(_ v: UInt16?, _ width: Int = 2) -> String {
            let s = String(v ?? 0)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        let date = "\(pad(time.year, 4))-\(pad(time.month))-\(pad(time.day))"
        let clock = "\(pad(time.hour)):\(pad(time.minute)):\(pad(time.second))"
        switch type {
        case .date: return date
        case .time: return clock
        default: return "\(date) \(clock)"
        }
    }
}

/// Collects the OK-packet metadata reported on the event loop.
private final class MetadataBox: @unchecked Sendable {
    var affected: Int?
}
