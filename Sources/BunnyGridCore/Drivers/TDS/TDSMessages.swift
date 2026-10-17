import Foundation
import NIOCore

// Tabular Data Stream (TDS 7.4), the protocol of Microsoft SQL Server, written from the public
// [MS-TDS] specification. This file builds what the client sends: packets, PRELOGIN, LOGIN7,
// SQL batches, RPC calls (sp_executesql) and ATTENTION.

enum TDSError: LocalizedError, Equatable, Sendable {
    /// The buffer ends in the middle of a token; more packets are needed.
    case incomplete
    case protocolViolation(String)
    case server(String, number: Int32)
    case connectionClosed
    case cancelled
    case encryptionRequired
    case encryptionUnsupported(TLSMode)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .incomplete: "The server's reply ended unexpectedly."
        case .protocolViolation(let detail): "Unexpected reply from SQL Server: \(detail)"
        case .server(let message, _): message
        case .connectionClosed: "The connection to SQL Server was closed."
        case .cancelled: "The query was cancelled."
        case .encryptionRequired:
            "The server requires an encrypted connection; choose an SSL mode other than Disabled."
        case .encryptionUnsupported(let mode):
            "SSL: the server doesn't support encryption, and the SSL mode “\(mode.displayName)” requires it."
        case .unsupported(let what): "\(what) is not supported."
        }
    }
}

/// The first byte of every packet header.
enum TDSPacketType: UInt8, Sendable {
    case sqlBatch = 0x01
    case rpc = 0x03
    case tabularResult = 0x04
    case attention = 0x06
    case login7 = 0x10
    case prelogin = 0x12
}

/// The 8-byte header in front of every packet. Its integers are big-endian; the payloads' are little-endian.
struct TDSPacketHeader: Equatable, Sendable {
    static let size = 8
    static let endOfMessage: UInt8 = 0x01

    var type: UInt8
    var status: UInt8
    var length: Int
    var packetID: UInt8

    var isEndOfMessage: Bool { status & Self.endOfMessage != 0 }

    /// Reads a header without consuming it; nil until 8 bytes are there.
    static func peek(_ buffer: ByteBuffer) -> TDSPacketHeader? {
        let start = buffer.readerIndex
        guard buffer.readableBytes >= size,
              let type = buffer.getInteger(at: start, as: UInt8.self),
              let status = buffer.getInteger(at: start + 1, as: UInt8.self),
              let length = buffer.getInteger(at: start + 2, endianness: .big, as: UInt16.self),
              let id = buffer.getInteger(at: start + 6, as: UInt8.self) else { return nil }
        return TDSPacketHeader(type: type, status: status, length: Int(length), packetID: id)
    }
}

enum TDSPacket {
    /// `payload` as one message: packets of at most `packetSize` bytes, the last one flagged end-of-message.
    static func encode(type: UInt8, payload: ByteBuffer, packetSize: Int) -> ByteBuffer {
        var payload = payload
        let room = max(packetSize - TDSPacketHeader.size, 1)
        var out = ByteBuffer()
        out.reserveCapacity(payload.readableBytes + (payload.readableBytes / room + 1) * TDSPacketHeader.size)
        var id: UInt8 = 1
        repeat {
            let chunk = payload.readSlice(length: min(room, payload.readableBytes))!
            let last = payload.readableBytes == 0
            out.writeInteger(type)
            out.writeInteger(last ? TDSPacketHeader.endOfMessage : 0)
            out.writeInteger(UInt16(chunk.readableBytes + TDSPacketHeader.size), endianness: .big)
            out.writeInteger(UInt16(0), endianness: .big) // SPID
            out.writeInteger(id)
            out.writeInteger(UInt8(0)) // window
            out.writeImmutableBuffer(chunk)
            id &+= 1
        } while payload.readableBytes > 0
        return out
    }

    /// ATTENTION: a header with no payload, sent while a reply is streaming to stop the request.
    static var attention: ByteBuffer {
        encode(type: TDSPacketType.attention.rawValue, payload: ByteBuffer(), packetSize: 4096)
    }
}

// MARK: - PRELOGIN

/// Encryption negotiated in PRELOGIN.
enum TDSEncryption: UInt8, Sendable {
    case off = 0x00
    case on = 0x01
    case notSupported = 0x02
    case required = 0x03
}

enum TDSPrelogin {
    private enum Option: UInt8 {
        case version = 0x00, encryption = 0x01, instance = 0x02, threadID = 0x03, mars = 0x04, terminator = 0xFF
    }

    static func encode(encryption: TDSEncryption, threadID: UInt32 = 0) -> ByteBuffer {
        let options: [(Option, [UInt8])] = [
            // Client library version 1.0.0.0, sub-build 0 (informational).
            (.version, [0x01, 0x00, 0x00, 0x00, 0x00, 0x00]),
            (.encryption, [encryption.rawValue]),
            // Default instance: an empty, NUL-terminated name.
            (.instance, [0x00]),
            (.threadID, withUnsafeBytes(of: threadID.bigEndian, Array.init)),
            (.mars, [0x00]),
        ]
        var buffer = ByteBuffer()
        var offset = options.count * 5 + 1
        for (option, data) in options {
            buffer.writeInteger(option.rawValue)
            buffer.writeInteger(UInt16(offset), endianness: .big)
            buffer.writeInteger(UInt16(data.count), endianness: .big)
            offset += data.count
        }
        buffer.writeInteger(Option.terminator.rawValue)
        for (_, data) in options { buffer.writeBytes(data) }
        return buffer
    }

    struct Response: Equatable, Sendable {
        var encryption: TDSEncryption
        /// Server version from the VERSION option (major.minor.build).
        var version: String
    }

    static func decode(_ payload: ByteBuffer) throws -> Response {
        let base = payload.readerIndex
        var cursor = base
        var encryption: TDSEncryption?
        var version = ""
        while let token = payload.getInteger(at: cursor, as: UInt8.self), token != Option.terminator.rawValue {
            guard let offset = payload.getInteger(at: cursor + 1, endianness: .big, as: UInt16.self),
                  let length = payload.getInteger(at: cursor + 3, endianness: .big, as: UInt16.self),
                  let data = payload.getBytes(at: base + Int(offset), length: Int(length)) else {
                throw TDSError.protocolViolation("malformed PRELOGIN response")
            }
            switch Option(rawValue: token) {
            case .encryption: encryption = data.first.flatMap(TDSEncryption.init(rawValue:))
            case .version where data.count >= 4:
                version = "\(data[0]).\(data[1]).\(UInt16(data[2]) << 8 | UInt16(data[3]))"
            default: break
            }
            cursor += 5
        }
        guard let encryption else { throw TDSError.protocolViolation("PRELOGIN response without an encryption option") }
        return Response(encryption: encryption, version: version)
    }
}

// MARK: - LOGIN7

struct TDSLogin7: Sendable {
    var hostName: String
    var userName: String
    var password: String
    var appName: String
    var serverName: String
    var libraryName = "BunnyGrid"
    var language = ""
    var database: String
    var packetSize: UInt32 = 4096
    var clientPID: UInt32 = UInt32(truncatingIfNeeded: ProcessInfo.processInfo.processIdentifier)

    /// TDS 7.4.
    static let tdsVersion: UInt32 = 0x7400_0004
    private static let fixedLength = 94

    func encode() -> ByteBuffer {
        // Variable part, in the order of the offset table.
        let fields: [[UInt8]] = [
            Self.utf16(hostName), Self.utf16(userName), Self.obfuscate(password), Self.utf16(appName), Self.utf16(serverName),
            [], // extension (unused)
            Self.utf16(libraryName), Self.utf16(language), Self.utf16(database),
        ]
        var data = ByteBuffer()
        var table = ByteBuffer()
        var offset = Self.fixedLength
        for field in fields {
            table.writeInteger(UInt16(offset), endianness: .little)
            table.writeInteger(UInt16(field.count / 2), endianness: .little)
            data.writeBytes(field)
            offset += field.count
        }
        table.writeBytes([UInt8](repeating: 0, count: 6)) // ClientID (MAC address)
        for _ in 0..<3 { // SSPI, AtchDBFile, ChangePassword: empty
            table.writeInteger(UInt16(offset), endianness: .little)
            table.writeInteger(UInt16(0), endianness: .little)
        }
        table.writeInteger(UInt32(0), endianness: .little) // cbSSPILong

        var out = ByteBuffer()
        out.writeInteger(UInt32(offset), endianness: .little)
        out.writeInteger(Self.tdsVersion, endianness: .little)
        out.writeInteger(packetSize, endianness: .little)
        out.writeInteger(UInt32(0x0700_0000), endianness: .little) // client program version
        out.writeInteger(clientPID, endianness: .little)
        out.writeInteger(UInt32(0), endianness: .little) // connection id
        // OptionFlags1: fUseDB, fDatabase (fail if the database can't be opened), fSetLang.
        out.writeInteger(UInt8(0xE0))
        // OptionFlags2: fLanguage fatal, fODBC (ANSI_NULLS, QUOTED_IDENTIFIER… on, as SSMS has them).
        out.writeInteger(UInt8(0x03))
        out.writeInteger(UInt8(0x00)) // TypeFlags
        out.writeInteger(UInt8(0x00)) // OptionFlags3
        out.writeInteger(Int32(0), endianness: .little) // client time zone
        out.writeInteger(UInt32(0x0409), endianness: .little) // client LCID
        out.writeBuffer(&table)
        out.writeBuffer(&data)
        return out
    }

    static func utf16(_ string: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(string.utf16.count * 2)
        for unit in string.utf16 {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8(unit >> 8))
        }
        return bytes
    }

    /// LOGIN7's password scrambling: swap each byte's nibbles, then XOR with 0xA5.
    static func obfuscate(_ password: String) -> [UInt8] {
        utf16(password).map { (($0 << 4) | ($0 >> 4)) ^ 0xA5 }
    }
}

// MARK: - Requests

enum TDSRequest {
    /// ALL_HEADERS with the transaction descriptor (required since TDS 7.2).
    static func allHeaders(transaction: UInt64) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt32(22), endianness: .little) // total length
        buffer.writeInteger(UInt32(18), endianness: .little) // header length
        buffer.writeInteger(UInt16(0x0002), endianness: .little) // transaction descriptor header
        buffer.writeInteger(transaction, endianness: .little)
        buffer.writeInteger(UInt32(1), endianness: .little) // outstanding request count
        return buffer
    }

    static func sqlBatch(_ sql: String, transaction: UInt64) -> ByteBuffer {
        var buffer = allHeaders(transaction: transaction)
        buffer.writeBytes(TDSLogin7.utf16(sql))
        return buffer
    }

    /// A value bound to an RPC parameter, with the type it is declared as in sp_executesql.
    enum Value: Equatable, Sendable {
        case null
        case bigint(Int64)
        case float(Double)
        case bit(Bool)
        case nvarchar(String)
        case varbinary(Data)

        var declaration: String {
            switch self {
            case .null, .nvarchar: "nvarchar(max)"
            case .bigint: "bigint"
            case .float: "float"
            case .bit: "bit"
            case .varbinary: "varbinary(max)"
            }
        }
    }

    /// `EXEC sp_executesql @stmt, @params, @p1, …`: the statement runs with typed parameters `@p1…@pn`.
    static func executeSQL(_ sql: String, parameters: [Value], collation: [UInt8], transaction: UInt64) -> ByteBuffer {
        var buffer = allHeaders(transaction: transaction)
        buffer.writeInteger(UInt16(0xFFFF), endianness: .little) // ProcIDSwitch: a well-known procedure
        buffer.writeInteger(UInt16(10), endianness: .little) // Sp_ExecuteSql
        buffer.writeInteger(UInt16(0), endianness: .little) // option flags
        let declarations = parameters.enumerated().map { "@p\($0.offset + 1) \($0.element.declaration)" }.joined(separator: ", ")
        writeParameter(&buffer, name: "", value: .nvarchar(sql), collation: collation)
        writeParameter(&buffer, name: "", value: .nvarchar(declarations), collation: collation)
        for (index, value) in parameters.enumerated() {
            writeParameter(&buffer, name: "@p\(index + 1)", value: value, collation: collation)
        }
        return buffer
    }

    static func writeParameter(_ buffer: inout ByteBuffer, name: String, value: Value, collation: [UInt8]) {
        let nameBytes = TDSLogin7.utf16(name)
        buffer.writeInteger(UInt8(nameBytes.count / 2))
        buffer.writeBytes(nameBytes)
        buffer.writeInteger(UInt8(0)) // status flags: input parameter
        switch value {
        case .bigint(let v):
            buffer.writeBytes([TDSDataType.intN, 8, 8])
            buffer.writeInteger(v, endianness: .little)
        case .float(let v):
            buffer.writeBytes([TDSDataType.floatN, 8, 8])
            buffer.writeInteger(v.bitPattern, endianness: .little)
        case .bit(let v):
            buffer.writeBytes([TDSDataType.bitN, 1, 1, v ? 1 : 0])
        case .null:
            buffer.writeInteger(TDSDataType.nvarchar)
            buffer.writeInteger(UInt16(0xFFFF), endianness: .little)
            buffer.writeBytes(collation)
            buffer.writeInteger(UInt64.max, endianness: .little) // PLP NULL
        case .nvarchar(let text):
            buffer.writeInteger(TDSDataType.nvarchar)
            buffer.writeInteger(UInt16(0xFFFF), endianness: .little)
            buffer.writeBytes(collation)
            writePLP(&buffer, TDSLogin7.utf16(text))
        case .varbinary(let data):
            buffer.writeInteger(TDSDataType.bigVarBinary)
            buffer.writeInteger(UInt16(0xFFFF), endianness: .little)
            writePLP(&buffer, [UInt8](data))
        }
    }

    /// Partially length-prefixed value: total length, one chunk, terminator.
    static func writePLP(_ buffer: inout ByteBuffer, _ bytes: [UInt8]) {
        buffer.writeInteger(UInt64(bytes.count), endianness: .little)
        if !bytes.isEmpty {
            buffer.writeInteger(UInt32(bytes.count), endianness: .little)
            buffer.writeBytes(bytes)
        }
        buffer.writeInteger(UInt32(0), endianness: .little)
    }
}
