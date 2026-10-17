import Foundation
import NIOCore

/// A column of COLMETADATA.
struct TDSColumn: Equatable, Sendable {
    var name: String
    var type: TDSTypeInfo
}

struct TDSServerMessage: Equatable, Sendable {
    var number: Int32
    var state: UInt8
    var severity: UInt8
    var text: String
    var procedure: String
    var line: Int32
}

struct TDSDone: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case done, proc, inProc }
    var kind: Kind
    var status: UInt16
    var rowCount: UInt64

    var hasMore: Bool { status & 0x01 != 0 }
    var isError: Bool { status & 0x02 != 0 }
    var hasCount: Bool { status & 0x10 != 0 }
    var isAttentionAck: Bool { status & 0x20 != 0 }
}

enum TDSEnvChange: Equatable, Sendable {
    case database(String)
    case packetSize(Int)
    case collation([UInt8])
    case beginTransaction(UInt64)
    case endTransaction
    case other(UInt8)
}

enum TDSToken: Equatable, Sendable {
    case columnMetadata([TDSColumn])
    case row([CellValue])
    case done(TDSDone)
    case error(TDSServerMessage)
    case info(TDSServerMessage)
    case envChange(TDSEnvChange)
    case loginAck(program: String, version: String)
    case returnStatus(Int32)
    /// SSPI token: the server's NTLM CHALLENGE during Windows Authentication.
    case sspi([UInt8])
    case ignored(UInt8)
}

/// Reads tokens of a tabular result. Throws `TDSError.incomplete` (leaving the caller to retry with more
/// bytes from a copy of the buffer) when a token isn't complete yet.
enum TDSTokenParser {
    static func next(_ buffer: inout ByteBuffer, columns: [TDSColumn]) throws -> TDSToken {
        let type = try buffer.tdsInt(UInt8.self)
        switch type {
        case 0x81: // COLMETADATA
            let count = try buffer.tdsInt(UInt16.self)
            if count == 0xFFFF { return .columnMetadata([]) }
            var result: [TDSColumn] = []
            for _ in 0..<count {
                _ = try buffer.tdsInt(UInt32.self) // user type
                _ = try buffer.tdsInt(UInt16.self) // flags
                let info = try TDSTypeInfo.read(&buffer)
                result.append(TDSColumn(name: try buffer.tdsBVarchar(), type: info))
            }
            return .columnMetadata(result)
        case 0xD1: // ROW
            return .row(try columns.map { try TDSValue.read(&buffer, $0.type) })
        case 0xD2: // NBCROW
            let bitmap = try buffer.tdsBytes((columns.count + 7) / 8)
            var values: [CellValue] = []
            values.reserveCapacity(columns.count)
            for (index, column) in columns.enumerated() {
                if bitmap[index / 8] & (1 << (index % 8)) != 0 {
                    values.append(.null)
                } else {
                    values.append(try TDSValue.read(&buffer, column.type))
                }
            }
            return .row(values)
        case 0xFD, 0xFE, 0xFF: // DONE, DONEPROC, DONEINPROC
            let status = try buffer.tdsInt(UInt16.self)
            _ = try buffer.tdsInt(UInt16.self) // current command
            let count = try buffer.tdsInt(UInt64.self)
            let kind: TDSDone.Kind = type == 0xFD ? .done : (type == 0xFE ? .proc : .inProc)
            return .done(TDSDone(kind: kind, status: status, rowCount: count))
        case 0xAA, 0xAB: // ERROR, INFO
            let length = Int(try buffer.tdsInt(UInt16.self))
            var body = try buffer.tdsSlice(length)
            let message = TDSServerMessage(number: try body.tdsInt(Int32.self), state: try body.tdsInt(UInt8.self),
                                           severity: try body.tdsInt(UInt8.self), text: try body.tdsUSVarchar(),
                                           procedure: { _ = try? body.tdsBVarchar(); return (try? body.tdsBVarchar()) ?? "" }(),
                                           line: (try? body.tdsInt(Int32.self)) ?? 0)
            return type == 0xAA ? .error(message) : .info(message)
        case 0xE3: // ENVCHANGE
            let length = Int(try buffer.tdsInt(UInt16.self))
            var body = try buffer.tdsSlice(length)
            let change = try body.tdsInt(UInt8.self)
            switch change {
            case 1: return .envChange(.database(try body.tdsBVarchar()))
            case 4: return .envChange(.packetSize(Int(try body.tdsBVarchar()) ?? 4096))
            case 7:
                let count = Int(try body.tdsInt(UInt8.self))
                return .envChange(.collation(try body.tdsBytes(count)))
            case 8:
                let count = Int(try body.tdsInt(UInt8.self))
                var value = try body.tdsSlice(count)
                return .envChange(.beginTransaction(count == 8 ? try value.tdsInt(UInt64.self) : 0))
            case 9, 10, 17: return .envChange(.endTransaction)
            default: return .envChange(.other(change))
            }
        case 0xAD: // LOGINACK
            let length = Int(try buffer.tdsInt(UInt16.self))
            var body = try buffer.tdsSlice(length)
            _ = try body.tdsInt(UInt8.self) // interface
            _ = try body.tdsInt(UInt32.self) // TDS version
            let program = try body.tdsBVarchar()
            let v = try body.tdsBytes(4)
            return .loginAck(program: program, version: "\(v[0]).\(v[1]).\(Int(v[2]) << 8 | Int(v[3]))")
        case 0x79: // RETURNSTATUS
            return .returnStatus(try buffer.tdsInt(Int32.self))
        case 0xAC: // RETURNVALUE
            _ = try buffer.tdsInt(UInt16.self)
            _ = try buffer.tdsBVarchar()
            _ = try buffer.tdsInt(UInt8.self)
            _ = try buffer.tdsInt(UInt32.self)
            _ = try buffer.tdsInt(UInt16.self)
            let info = try TDSTypeInfo.read(&buffer, inMetadata: false)
            _ = try TDSValue.read(&buffer, info)
            return .ignored(type)
        case 0xED: // SSPI
            let length = Int(try buffer.tdsInt(UInt16.self))
            return .sspi(try buffer.tdsBytes(length))
        case 0xA9, 0xA5, 0xA4: // ORDER, COLINFO, TABNAME
            let length = Int(try buffer.tdsInt(UInt16.self))
            _ = try buffer.tdsSlice(length)
            return .ignored(type)
        case 0xE4: // SESSIONSTATE
            let length = Int(try buffer.tdsInt(UInt32.self))
            _ = try buffer.tdsSlice(length)
            return .ignored(type)
        case 0xAE: // FEATUREEXTACK
            while true {
                let feature = try buffer.tdsInt(UInt8.self)
                if feature == 0xFF { break }
                _ = try buffer.tdsSlice(Int(try buffer.tdsInt(UInt32.self)))
            }
            return .ignored(type)
        default:
            throw TDSError.protocolViolation(String(format: "unknown token 0x%02X", type))
        }
    }
}
