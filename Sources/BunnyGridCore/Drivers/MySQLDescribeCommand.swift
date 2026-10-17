import MySQLNIO
import NIOCore

/// Prepares a statement only to read its result columns, then closes it without executing.
/// MySQLNIO hands column definitions out only with rows, so a SELECT without rows would have no column names;
/// COM_STMT_PREPARE reports them (names and types) without running the query.
final class MySQLDescribeCommand: MySQLCommand, @unchecked Sendable {
    private let sql: String
    private var ok: MySQLProtocol.COM_STMT_PREPARE_OK?
    private var remainingParams = 0
    private var remainingColumns = 0
    private(set) var columns: [MySQLProtocol.ColumnDefinition41] = []

    init(sql: String) { self.sql = sql }

    func activate(capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        // COM_STMT_PREPARE (0x16) followed by the statement text; MySQLNIO's encoder for it isn't public.
        var payload = ByteBuffer()
        payload.writeInteger(UInt8(0x16))
        payload.writeString(sql)
        return MySQLCommandState(response: [MySQLPacket(payload: payload)])
    }

    func handle(packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        if packet.isError {
            let error = try packet.decode(MySQLProtocol.ERR_Packet.self, capabilities: capabilities)
            return MySQLCommandState(done: true, resetSequence: true, error: MySQLError.server(error))
        }
        guard ok != nil else {
            let prepared = try packet.decode(MySQLProtocol.COM_STMT_PREPARE_OK.self, capabilities: capabilities)
            self.ok = prepared
            remainingParams = Int(prepared.numParams)
            remainingColumns = Int(prepared.numColumns)
            return try finishIfComplete(capabilities: capabilities)
        }
        // MySQLNIO always negotiates CLIENT_DEPRECATE_EOF; skip a stray EOF anyway.
        if packet.isEOF { return try finishIfComplete(capabilities: capabilities) }
        let definition = try packet.decode(MySQLProtocol.ColumnDefinition41.self, capabilities: capabilities)
        if remainingParams > 0 {
            remainingParams -= 1
        } else if remainingColumns > 0 {
            remainingColumns -= 1
            columns.append(definition)
        }
        return try finishIfComplete(capabilities: capabilities)
    }

    private func finishIfComplete(capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        guard let ok, remainingParams == 0, remainingColumns == 0 else { return MySQLCommandState() }
        // COM_STMT_CLOSE (0x19) and the statement id; the server sends no reply.
        var close = ByteBuffer()
        close.writeInteger(UInt8(0x19))
        close.writeInteger(ok.statementID, endianness: .little)
        return MySQLCommandState(response: [MySQLPacket(payload: close)], done: true, resetSequence: true)
    }
}
