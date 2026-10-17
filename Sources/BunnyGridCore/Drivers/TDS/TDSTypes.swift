import Foundation
import NIOCore

/// Data type bytes of TYPE_INFO ([MS-TDS] 2.2.5.4).
enum TDSDataType {
    static let null: UInt8 = 0x1F
    static let int1: UInt8 = 0x30
    static let bit: UInt8 = 0x32
    static let int2: UInt8 = 0x34
    static let int4: UInt8 = 0x38
    static let dateTime4: UInt8 = 0x3A
    static let float4: UInt8 = 0x3B
    static let money: UInt8 = 0x3C
    static let dateTime: UInt8 = 0x3D
    static let float8: UInt8 = 0x3E
    static let money4: UInt8 = 0x7A
    static let int8: UInt8 = 0x7F

    static let guid: UInt8 = 0x24
    static let intN: UInt8 = 0x26
    static let decimal: UInt8 = 0x37
    static let numeric: UInt8 = 0x3F
    static let bitN: UInt8 = 0x68
    static let decimalN: UInt8 = 0x6A
    static let numericN: UInt8 = 0x6C
    static let floatN: UInt8 = 0x6D
    static let moneyN: UInt8 = 0x6E
    static let dateTimeN: UInt8 = 0x6F
    static let date: UInt8 = 0x28
    static let time: UInt8 = 0x29
    static let dateTime2: UInt8 = 0x2A
    static let dateTimeOffset: UInt8 = 0x2B
    static let char: UInt8 = 0x2F
    static let varChar: UInt8 = 0x27
    static let binary: UInt8 = 0x2D
    static let varBinary: UInt8 = 0x25

    static let bigVarBinary: UInt8 = 0xA5
    static let bigVarChar: UInt8 = 0xA7
    static let bigBinary: UInt8 = 0xAD
    static let bigChar: UInt8 = 0xAF
    static let nvarchar: UInt8 = 0xE7
    static let nchar: UInt8 = 0xEF
    static let xml: UInt8 = 0xF1
    static let udt: UInt8 = 0xF0

    static let text: UInt8 = 0x23
    static let image: UInt8 = 0x22
    static let ntext: UInt8 = 0x63
    static let variant: UInt8 = 0x62
}

/// How a column's values are length-prefixed on the wire.
enum TDSLengthKind: Equatable, Sendable {
    case fixed(Int)
    /// One length byte; 0 is NULL.
    case byte
    /// Two length bytes; 0xFFFF is NULL.
    case ushort
    /// text / ntext / image: a text pointer, a timestamp and a four-byte length.
    case textPointer
    /// Partially length-prefixed (the `max` types, xml, CLR types).
    case plp
    /// sql_variant: a four-byte length, then the base type inside the value.
    case variant
}

/// A column's (or parameter's) TYPE_INFO.
struct TDSTypeInfo: Equatable, Sendable {
    var type: UInt8
    var lengthKind: TDSLengthKind
    var maxLength = 0
    var precision: UInt8 = 0
    var scale: UInt8 = 0
    /// Five bytes for character types: LCID and flags, then the sort id.
    var collation: [UInt8] = []
    /// CLR type name (hierarchyid, geometry, geography).
    var udtName = ""

    /// Reads TYPE_INFO. Text, ntext and image columns in COLMETADATA also carry their table name.
    static func read(_ buffer: inout ByteBuffer, inMetadata: Bool = true) throws -> TDSTypeInfo {
        let type = try buffer.tdsInt(UInt8.self)
        var info = TDSTypeInfo(type: type, lengthKind: .byte)
        switch type {
        case TDSDataType.null: info.lengthKind = .fixed(0)
        case TDSDataType.int1, TDSDataType.bit: info.lengthKind = .fixed(1)
        case TDSDataType.int2: info.lengthKind = .fixed(2)
        case TDSDataType.int4, TDSDataType.dateTime4, TDSDataType.float4, TDSDataType.money4: info.lengthKind = .fixed(4)
        case TDSDataType.money, TDSDataType.dateTime, TDSDataType.float8, TDSDataType.int8: info.lengthKind = .fixed(8)
        case TDSDataType.guid, TDSDataType.intN, TDSDataType.bitN, TDSDataType.floatN, TDSDataType.moneyN, TDSDataType.dateTimeN,
             TDSDataType.char, TDSDataType.varChar, TDSDataType.binary, TDSDataType.varBinary:
            info.maxLength = Int(try buffer.tdsInt(UInt8.self))
        case TDSDataType.decimal, TDSDataType.numeric, TDSDataType.decimalN, TDSDataType.numericN:
            info.maxLength = Int(try buffer.tdsInt(UInt8.self))
            info.precision = try buffer.tdsInt(UInt8.self)
            info.scale = try buffer.tdsInt(UInt8.self)
        case TDSDataType.date:
            info.maxLength = 3
        case TDSDataType.time, TDSDataType.dateTime2, TDSDataType.dateTimeOffset:
            info.scale = try buffer.tdsInt(UInt8.self)
        case TDSDataType.bigVarBinary, TDSDataType.bigBinary:
            let length = try buffer.tdsInt(UInt16.self)
            info.maxLength = Int(length)
            info.lengthKind = length == 0xFFFF ? .plp : .ushort
        case TDSDataType.bigVarChar, TDSDataType.bigChar, TDSDataType.nvarchar, TDSDataType.nchar:
            let length = try buffer.tdsInt(UInt16.self)
            info.maxLength = Int(length)
            info.lengthKind = length == 0xFFFF ? .plp : .ushort
            info.collation = try buffer.tdsBytes(5)
        case TDSDataType.text, TDSDataType.ntext, TDSDataType.image:
            info.maxLength = Int(try buffer.tdsInt(Int32.self))
            if type != TDSDataType.image { info.collation = try buffer.tdsBytes(5) }
            if inMetadata {
                let parts = try buffer.tdsInt(UInt8.self)
                for _ in 0..<parts { _ = try buffer.tdsUSVarchar() }
            }
            info.lengthKind = .textPointer
        case TDSDataType.xml:
            if try buffer.tdsInt(UInt8.self) == 1 { // schema present
                _ = try buffer.tdsBVarchar()
                _ = try buffer.tdsBVarchar()
                _ = try buffer.tdsUSVarchar()
            }
            info.lengthKind = .plp
        case TDSDataType.udt:
            info.maxLength = Int(try buffer.tdsInt(UInt16.self))
            _ = try buffer.tdsBVarchar() // database
            _ = try buffer.tdsBVarchar() // schema
            info.udtName = try buffer.tdsBVarchar()
            _ = try buffer.tdsUSVarchar() // assembly-qualified name
            info.lengthKind = .plp
        case TDSDataType.variant:
            info.maxLength = Int(try buffer.tdsInt(Int32.self))
            info.lengthKind = .variant
        default:
            throw TDSError.protocolViolation(String(format: "unknown data type 0x%02X", type))
        }
        return info
    }

    /// The SQL type name, as SQL Server spells it in a declaration.
    var typeName: String {
        switch type {
        case TDSDataType.int1: return "tinyint"
        case TDSDataType.bit, TDSDataType.bitN: return "bit"
        case TDSDataType.int2: return "smallint"
        case TDSDataType.int4: return "int"
        case TDSDataType.int8: return "bigint"
        case TDSDataType.intN: return [1: "tinyint", 2: "smallint", 4: "int"][maxLength] ?? "bigint"
        case TDSDataType.float4: return "real"
        case TDSDataType.float8: return "float"
        case TDSDataType.floatN: return maxLength == 4 ? "real" : "float"
        case TDSDataType.money: return "money"
        case TDSDataType.money4: return "smallmoney"
        case TDSDataType.moneyN: return maxLength == 4 ? "smallmoney" : "money"
        case TDSDataType.dateTime: return "datetime"
        case TDSDataType.dateTime4: return "smalldatetime"
        case TDSDataType.dateTimeN: return maxLength == 4 ? "smalldatetime" : "datetime"
        case TDSDataType.decimal, TDSDataType.decimalN: return "decimal(\(precision),\(scale))"
        case TDSDataType.numeric, TDSDataType.numericN: return "numeric(\(precision),\(scale))"
        case TDSDataType.guid: return "uniqueidentifier"
        case TDSDataType.date: return "date"
        case TDSDataType.time: return "time(\(scale))"
        case TDSDataType.dateTime2: return "datetime2(\(scale))"
        case TDSDataType.dateTimeOffset: return "datetimeoffset(\(scale))"
        case TDSDataType.bigVarChar, TDSDataType.varChar: return lengthKind == .plp ? "varchar(max)" : "varchar(\(maxLength))"
        case TDSDataType.bigChar, TDSDataType.char: return "char(\(maxLength))"
        case TDSDataType.nvarchar: return lengthKind == .plp ? "nvarchar(max)" : "nvarchar(\(maxLength / 2))"
        case TDSDataType.nchar: return "nchar(\(maxLength / 2))"
        case TDSDataType.bigVarBinary, TDSDataType.varBinary: return lengthKind == .plp ? "varbinary(max)" : "varbinary(\(maxLength))"
        case TDSDataType.bigBinary, TDSDataType.binary: return "binary(\(maxLength))"
        case TDSDataType.text: return "text"
        case TDSDataType.ntext: return "ntext"
        case TDSDataType.image: return "image"
        case TDSDataType.xml: return "xml"
        case TDSDataType.udt: return udtName.isEmpty ? "udt" : udtName
        case TDSDataType.variant: return "sql_variant"
        default: return "null"
        }
    }
}

// MARK: - Values

enum TDSValue {
    /// Reads one value of `info` and decodes it.
    static func read(_ buffer: inout ByteBuffer, _ info: TDSTypeInfo) throws -> CellValue {
        switch info.lengthKind {
        case .fixed(let size):
            guard size > 0 else { return .null }
            return try decode(try buffer.tdsSlice(size), info)
        case .byte:
            let length = Int(try buffer.tdsInt(UInt8.self))
            guard length > 0 else { return .null }
            return try decode(try buffer.tdsSlice(length), info)
        case .ushort:
            let length = try buffer.tdsInt(UInt16.self)
            guard length != 0xFFFF else { return .null }
            return try decode(try buffer.tdsSlice(Int(length)), info)
        case .textPointer:
            let pointer = Int(try buffer.tdsInt(UInt8.self))
            guard pointer > 0 else { return .null }
            _ = try buffer.tdsSlice(pointer + 8) // text pointer and timestamp
            let length = try buffer.tdsInt(Int32.self)
            return try decode(try buffer.tdsSlice(Int(max(length, 0))), info)
        case .plp:
            guard let bytes = try readPLP(&buffer) else { return .null }
            return try decode(bytes, info)
        case .variant:
            let length = Int(try buffer.tdsInt(Int32.self))
            guard length > 0 else { return .null }
            var value = try buffer.tdsSlice(length)
            return try decodeVariant(&value)
        }
    }

    /// The chunks of a PLP value joined; nil for NULL.
    static func readPLP(_ buffer: inout ByteBuffer) throws -> ByteBuffer? {
        let total = try buffer.tdsInt(UInt64.self)
        if total == UInt64.max { return nil }
        var out = ByteBuffer()
        if total != UInt64.max - 1, total < UInt64(Int32.max) { out.reserveCapacity(Int(total)) }
        while true {
            let chunk = try buffer.tdsInt(UInt32.self)
            if chunk == 0 { break }
            var slice = try buffer.tdsSlice(Int(chunk))
            out.writeBuffer(&slice)
        }
        return out
    }

    /// sql_variant: base type, property bytes, then the value without a length prefix.
    static func decodeVariant(_ value: inout ByteBuffer) throws -> CellValue {
        let base = try value.tdsInt(UInt8.self)
        let propertyCount = Int(try value.tdsInt(UInt8.self))
        var properties = try value.tdsSlice(propertyCount)
        var info = TDSTypeInfo(type: base, lengthKind: .byte, maxLength: value.readableBytes)
        switch base {
        case TDSDataType.decimalN, TDSDataType.numericN:
            info.precision = try properties.tdsInt(UInt8.self)
            info.scale = try properties.tdsInt(UInt8.self)
        case TDSDataType.time, TDSDataType.dateTime2, TDSDataType.dateTimeOffset:
            info.scale = try properties.tdsInt(UInt8.self)
        case TDSDataType.bigVarChar, TDSDataType.bigChar, TDSDataType.nvarchar, TDSDataType.nchar:
            info.collation = try properties.tdsBytes(5)
        default:
            break
        }
        return try decode(value, info)
    }

    /// Decodes the bytes of a non-NULL value.
    static func decode(_ bytes: ByteBuffer, _ info: TDSTypeInfo) throws -> CellValue {
        var b = bytes
        let size = b.readableBytes
        switch info.type {
        case TDSDataType.int1:
            return .integer(Int64(try b.tdsInt(UInt8.self)))
        case TDSDataType.int2:
            return .integer(Int64(try b.tdsInt(Int16.self)))
        case TDSDataType.int4:
            return .integer(Int64(try b.tdsInt(Int32.self)))
        case TDSDataType.int8:
            return .integer(try b.tdsInt(Int64.self))
        case TDSDataType.intN:
            switch size {
            case 1: return .integer(Int64(try b.tdsInt(UInt8.self)))
            case 2: return .integer(Int64(try b.tdsInt(Int16.self)))
            case 4: return .integer(Int64(try b.tdsInt(Int32.self)))
            default: return .integer(try b.tdsInt(Int64.self))
            }
        case TDSDataType.bit, TDSDataType.bitN:
            return .bool(try b.tdsInt(UInt8.self) != 0)
        case TDSDataType.float4, TDSDataType.float8, TDSDataType.floatN:
            if size == 4 {
                // Through the float's shortest text, so 3.14 shows as 3.14 and not 3.140000104904175.
                let float = Float(bitPattern: try b.tdsInt(UInt32.self))
                return .double(Double(String(float)) ?? Double(float))
            }
            return .double(Double(bitPattern: try b.tdsInt(UInt64.self)))
        case TDSDataType.money, TDSDataType.money4, TDSDataType.moneyN:
            let value: Int64
            if size == 4 {
                value = Int64(try b.tdsInt(Int32.self))
            } else {
                let high = Int64(try b.tdsInt(Int32.self))
                let low = Int64(try b.tdsInt(UInt32.self))
                value = high << 32 | low
            }
            return .text(TDSFormat.scaled(magnitude: [UInt32(truncatingIfNeeded: value.magnitude), UInt32(truncatingIfNeeded: value.magnitude >> 32)],
                                          negative: value < 0, scale: 4))
        case TDSDataType.dateTime, TDSDataType.dateTime4, TDSDataType.dateTimeN:
            if size == 4 {
                let days = Int(try b.tdsInt(UInt16.self))
                let minutes = Int(try b.tdsInt(UInt16.self))
                return .text(TDSFormat.date(daysSince1970: days + TDSFormat.days1900) + " " + TDSFormat.clock(seconds: minutes * 60, fraction: nil))
            }
            let days = Int(try b.tdsInt(Int32.self))
            let ticks = Int(try b.tdsInt(UInt32.self)) // 1/300 s
            var milliseconds = (ticks * 10 + 1) / 3
            var dayOffset = 0
            if milliseconds >= 86_400_000 { milliseconds -= 86_400_000; dayOffset = 1 }
            return .text(TDSFormat.date(daysSince1970: days + dayOffset + TDSFormat.days1900) + " "
                         + TDSFormat.clock(seconds: milliseconds / 1000, fraction: (Int64(milliseconds % 1000), 3)))
        case TDSDataType.date:
            return .text(TDSFormat.date(daysSince1970: try b.tdsUInt24() + TDSFormat.days0001))
        case TDSDataType.time:
            return .text(try TDSFormat.time(&b, scale: Int(info.scale)))
        case TDSDataType.dateTime2:
            let time = try TDSFormat.time(&b, scale: Int(info.scale))
            return .text(TDSFormat.date(daysSince1970: try b.tdsUInt24() + TDSFormat.days0001) + " " + time)
        case TDSDataType.dateTimeOffset:
            let units = try TDSFormat.timeUnits(&b, scale: Int(info.scale))
            let days = try b.tdsUInt24() + TDSFormat.days0001
            let offset = Int(try b.tdsInt(Int16.self))
            return .text(TDSFormat.dateTimeOffset(units: units, scale: Int(info.scale), utcDays: days, offsetMinutes: offset))
        case TDSDataType.decimal, TDSDataType.numeric, TDSDataType.decimalN, TDSDataType.numericN:
            let positive = try b.tdsInt(UInt8.self) == 1
            var limbs: [UInt32] = []
            while b.readableBytes >= 4 { limbs.append(try b.tdsInt(UInt32.self)) }
            return .text(TDSFormat.scaled(magnitude: limbs, negative: !positive, scale: Int(info.scale)))
        case TDSDataType.guid:
            return .text(TDSFormat.guid(try b.tdsBytes(16)))
        case TDSDataType.bigVarChar, TDSDataType.bigChar, TDSDataType.char, TDSDataType.varChar, TDSDataType.text:
            return .text(TDSCollation.decode(try b.tdsBytes(size), collation: info.collation))
        case TDSDataType.nvarchar, TDSDataType.nchar, TDSDataType.ntext, TDSDataType.xml:
            var text = TDSFormat.utf16(try b.tdsBytes(size))
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            return .text(text)
        case TDSDataType.bigVarBinary, TDSDataType.bigBinary, TDSDataType.binary, TDSDataType.varBinary, TDSDataType.image, TDSDataType.udt:
            return .blob(Data(try b.tdsBytes(size)))
        default:
            return .text(String(format: "<type 0x%02X>", info.type))
        }
    }
}

// MARK: - Formatting

enum TDSFormat {
    /// Days from 1970-01-01 back to 0001-01-01 and to 1900-01-01.
    static let days0001 = -719_162
    static let days1900 = -25_567

    /// `yyyy-MM-dd` in the proleptic Gregorian calendar (H. Hinnant's civil_from_days).
    static func date(daysSince1970 days: Int) -> String {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        return pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2)
    }

    /// `HH:mm:ss` plus `fraction.value` printed with `fraction.digits` digits.
    static func clock(seconds: Int, fraction: (value: Int64, digits: Int)?) -> String {
        var text = pad(seconds / 3600, 2) + ":" + pad(seconds / 60 % 60, 2) + ":" + pad(seconds % 60, 2)
        if let fraction, fraction.digits > 0 { text += "." + pad(Int(fraction.value), fraction.digits) }
        return text
    }

    /// time(n): 3 to 5 bytes counting 10⁻ⁿ seconds since midnight.
    static func timeUnits(_ b: inout ByteBuffer, scale: Int) throws -> Int64 {
        let length = scale <= 2 ? 3 : (scale <= 4 ? 4 : 5)
        var units: Int64 = 0
        for (index, byte) in try b.tdsBytes(length).enumerated() { units |= Int64(byte) << (8 * index) }
        return units
    }

    static func time(_ b: inout ByteBuffer, scale: Int) throws -> String {
        clock(units: try timeUnits(&b, scale: scale), scale: scale)
    }

    static func clock(units: Int64, scale: Int) -> String {
        let divisor = power10(scale)
        return clock(seconds: Int(units / divisor), fraction: (units % divisor, scale))
    }

    /// The local time of a datetimeoffset (stored as UTC plus the offset), as SSMS prints it: `2026-10-17 09:30:00.1234567 -03:00`.
    static func dateTimeOffset(units: Int64, scale: Int, utcDays: Int, offsetMinutes: Int) -> String {
        let perDay = 86_400 * power10(scale)
        var local = Int64(utcDays) * perDay + units + Int64(offsetMinutes) * 60 * power10(scale)
        var days = Int(local / perDay)
        local %= perDay
        if local < 0 { local += perDay; days -= 1 }
        let sign = offsetMinutes < 0 ? "-" : "+"
        let offset = abs(offsetMinutes)
        return date(daysSince1970: days) + " " + clock(units: local, scale: scale) + " \(sign)" + pad(offset / 60, 2) + ":" + pad(offset % 60, 2)
    }

    static func power10(_ n: Int) -> Int64 {
        (0..<max(n, 0)).reduce(Int64(1)) { value, _ in value * 10 }
    }

    /// A little-endian magnitude in 32-bit limbs, as decimal text with `scale` fractional digits.
    static func scaled(magnitude: [UInt32], negative: Bool, scale: Int) -> String {
        var limbs = magnitude
        var digits: [UInt8] = []
        while limbs.contains(where: { $0 != 0 }) {
            var remainder: UInt64 = 0
            for index in limbs.indices.reversed() {
                let value = remainder << 32 | UInt64(limbs[index])
                limbs[index] = UInt32(value / 10)
                remainder = value % 10
            }
            digits.append(UInt8(remainder))
        }
        while digits.count <= scale { digits.append(0) }
        var text = String(digits.reversed().map { Character(String($0)) })
        if scale > 0 { text.insert(".", at: text.index(text.endIndex, offsetBy: -scale)) }
        let isZero = !magnitude.contains { $0 != 0 }
        return (negative && !isZero ? "-" : "") + text
    }

    /// uniqueidentifier: the first three groups are little-endian on the wire.
    static func guid(_ bytes: [UInt8]) -> String {
        let order = [3, 2, 1, 0, -1, 5, 4, -1, 7, 6, -1, 8, 9, -1, 10, 11, 12, 13, 14, 15]
        return order.map { $0 < 0 ? "-" : String(format: "%02X", bytes[$0]) }.joined()
    }

    static func utf16(_ bytes: [UInt8]) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = 0
        while index + 1 < bytes.count {
            units.append(UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }
}

/// Decodes varchar / char / text bytes with the code page their collation implies.
enum TDSCollation {
    /// Latin1_General_CI_AS, for parameters before the server reports its collation.
    static let latin1General: [UInt8] = [0x09, 0x04, 0xD0, 0x00, 0x34]

    static func decode(_ bytes: [UInt8], collation: [UInt8]) -> String {
        let encoding = self.encoding(for: collation)
        if encoding == .utf8 { return String(decoding: bytes, as: UTF8.self) }
        return String(bytes: bytes, encoding: encoding) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    static func encoding(for collation: [UInt8]) -> String.Encoding {
        guard collation.count == 5 else { return .windowsCP1252 }
        // _UTF8 collations (SQL Server 2019+): flag bit 26 of the first four bytes.
        if collation[3] & 0x04 != 0 { return .utf8 }
        let sortID = collation[4]
        if sortID != 0 { return sqlSortEncoding(sortID) }
        let lcid = Int(collation[0]) | Int(collation[1]) << 8 | Int(collation[2] & 0x0F) << 16
        return codePage(forLCID: lcid).map(windowsEncoding) ?? .windowsCP1252
    }

    /// Code pages of the SQL_* collations' sort ids.
    private static func sqlSortEncoding(_ id: UInt8) -> String.Encoding {
        switch id {
        case 30...34: windowsEncoding(437)
        case 40...49, 55...61, 182...186: windowsEncoding(850)
        case 80...98: windowsEncoding(1250)
        case 104...108: windowsEncoding(1251)
        case 112...114, 120...124: windowsEncoding(1253)
        case 128...130: windowsEncoding(1254)
        case 136...138: windowsEncoding(1255)
        case 144...146: windowsEncoding(1256)
        case 152...160: windowsEncoding(1257)
        default: .windowsCP1252
        }
    }

    static func codePage(forLCID lcid: Int) -> UInt32? {
        switch lcid & 0x3FF {
        case 0x11: 932
        case 0x04: [0x0404, 0x0C04, 0x1404].contains(lcid) ? 950 : 936
        case 0x12: 949
        case 0x02, 0x19, 0x22, 0x23, 0x2F, 0x3F, 0x40, 0x44, 0x50: 1251
        case 0x08: 1253
        case 0x1F, 0x2C: 1254
        case 0x0D: 1255
        case 0x01, 0x20, 0x29: 1256
        case 0x25, 0x26, 0x27: 1257
        case 0x2A: 1258
        case 0x1E: 874
        case 0x05, 0x0E, 0x15, 0x18, 0x1B, 0x1C, 0x24: 1250
        case 0x1A: lcid == 0x0C1A || lcid == 0x1C1A ? 1251 : 1250
        default: nil
        }
    }

    static func windowsEncoding(_ codePage: UInt32) -> String.Encoding {
        let cf = CFStringConvertWindowsCodepageToEncoding(codePage)
        guard cf != kCFStringEncodingInvalidId else { return .windowsCP1252 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
}

// MARK: - Reading

extension ByteBuffer {
    /// A little-endian integer, or `TDSError.incomplete` when the bytes aren't there yet.
    mutating func tdsInt<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        guard let value = readInteger(endianness: .little, as: T.self) else { throw TDSError.incomplete }
        return value
    }

    mutating func tdsUInt24() throws -> Int {
        let bytes = try tdsBytes(3)
        return Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16
    }

    mutating func tdsBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, let bytes = readBytes(length: count) else { throw TDSError.incomplete }
        return bytes
    }

    mutating func tdsSlice(_ count: Int) throws -> ByteBuffer {
        guard count >= 0, let slice = readSlice(length: count) else { throw TDSError.incomplete }
        return slice
    }

    /// B_VARCHAR: a one-byte character count, then UTF-16.
    mutating func tdsBVarchar() throws -> String {
        let count = Int(try tdsInt(UInt8.self))
        return TDSFormat.utf16(try tdsBytes(count * 2))
    }

    /// US_VARCHAR: a two-byte character count, then UTF-16.
    mutating func tdsUSVarchar() throws -> String {
        let count = Int(try tdsInt(UInt16.self))
        return TDSFormat.utf16(try tdsBytes(count * 2))
    }
}
