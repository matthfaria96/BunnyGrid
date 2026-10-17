import Foundation

/// A 12-byte MongoDB ObjectId: 4-byte timestamp, 5 random bytes, 3-byte counter.
public struct ObjectId: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let bytes: [UInt8]

    private static let process: [UInt8] = (0..<5).map { _ in UInt8.random(in: 0...255) }
    private static let counter = AtomicCounter(start: UInt32.random(in: 0...0xFFFFFF))

    /// A new id for the current time.
    public init() {
        let seconds = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970))
        let count = Self.counter.next()
        bytes = [UInt8(seconds >> 24), UInt8((seconds >> 16) & 0xFF), UInt8((seconds >> 8) & 0xFF), UInt8(seconds & 0xFF)]
            + Self.process
            + [UInt8((count >> 16) & 0xFF), UInt8((count >> 8) & 0xFF), UInt8(count & 0xFF)]
    }

    public init?(bytes: [UInt8]) {
        guard bytes.count == 12 else { return nil }
        self.bytes = bytes
    }

    /// From 24 hex digits.
    public init?(_ hex: String) {
        let scalars = Array(hex.utf8)
        guard scalars.count == 24 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(12)
        for i in stride(from: 0, to: 24, by: 2) {
            guard let high = Self.nibble(scalars[i]), let low = Self.nibble(scalars[i + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        self.bytes = bytes
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: c - 48
        case 65...70: c - 55
        case 97...102: c - 87
        default: nil
        }
    }

    public var hexString: String { bytes.map { String(format: "%02x", $0) }.joined() }
    public var description: String { hexString }

    /// When the id was generated (second precision).
    public var date: Date {
        let seconds = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    public static func < (a: ObjectId, b: ObjectId) -> Bool { a.bytes.lexicographicallyPrecedes(b.bytes) }
}

final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt32

    init(start: UInt32) { value = start }

    func next() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        value = (value &+ 1) & 0xFFFFFF
        return value
    }
}

public struct BSONBinary: Hashable, Sendable {
    public var subtype: UInt8
    public var data: Data

    public init(subtype: UInt8 = 0, data: Data) {
        self.subtype = subtype
        self.data = data
    }

    /// Subtype 4: a UUID, printed as `UUID("…")`.
    public var uuid: UUID? {
        guard subtype == 4, data.count == 16 else { return nil }
        let b = [UInt8](data)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    public init(uuid: UUID) {
        let u = uuid.uuid
        subtype = 4
        data = Data([u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15])
    }
}

public struct BSONRegex: Hashable, Sendable {
    public var pattern: String
    /// Flags in alphabetical order (`imsux`), as BSON requires.
    public var options: String

    public init(pattern: String, options: String = "") {
        self.pattern = pattern
        self.options = String(options.sorted())
    }
}

public struct BSONTimestamp: Hashable, Sendable {
    /// Seconds since the epoch.
    public var timestamp: UInt32
    public var increment: UInt32

    public init(timestamp: UInt32, increment: UInt32) {
        self.timestamp = timestamp
        self.increment = increment
    }
}

/// One BSON value. Dates keep the exact milliseconds; Decimal128 keeps its raw bits.
public indirect enum BSON: Hashable, Sendable {
    case double(Double)
    case string(String)
    case document(BSONDocument)
    case array([BSON])
    case binary(BSONBinary)
    case undefined
    case objectId(ObjectId)
    case bool(Bool)
    /// Milliseconds since the Unix epoch.
    case date(Int64)
    case null
    case regex(BSONRegex)
    case javascript(String)
    case symbol(String)
    case javascriptWithScope(String, BSONDocument)
    case int32(Int32)
    case timestamp(BSONTimestamp)
    case int64(Int64)
    case decimal128(BSONDecimal128)
    case minKey
    case maxKey

    public static func date(_ date: Date) -> BSON { .date(Int64((date.timeIntervalSince1970 * 1000).rounded())) }

    /// Type name as mongosh's `$type` / Navicat's column type header shows it.
    public var typeName: String {
        switch self {
        case .double: "Double"
        case .string: "String"
        case .document: "Document"
        case .array: "Array"
        case .binary: "Binary"
        case .undefined: "Undefined"
        case .objectId: "ObjectId"
        case .bool: "Boolean"
        case .date: "Date"
        case .null: "Null"
        case .regex: "Regex"
        case .javascript, .javascriptWithScope: "JavaScript"
        case .symbol: "Symbol"
        case .int32: "Int32"
        case .timestamp: "Timestamp"
        case .int64: "Int64"
        case .decimal128: "Decimal128"
        case .minKey: "MinKey"
        case .maxKey: "MaxKey"
        }
    }

    var typeByte: UInt8 {
        switch self {
        case .double: 0x01
        case .string: 0x02
        case .document: 0x03
        case .array: 0x04
        case .binary: 0x05
        case .undefined: 0x06
        case .objectId: 0x07
        case .bool: 0x08
        case .date: 0x09
        case .null: 0x0A
        case .regex: 0x0B
        case .javascript: 0x0D
        case .symbol: 0x0E
        case .javascriptWithScope: 0x0F
        case .int32: 0x10
        case .timestamp: 0x11
        case .int64: 0x12
        case .decimal128: 0x13
        case .minKey: 0xFF
        case .maxKey: 0x7F
        }
    }

    public var documentValue: BSONDocument? { if case .document(let d) = self { d } else { nil } }
    public var arrayValue: [BSON]? { if case .array(let a) = self { a } else { nil } }
    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }

    /// Any numeric case as an integer (doubles truncated), for server replies such as `n` or `ok`.
    public var intValue: Int? {
        switch self {
        case .int32(let v): Int(v)
        case .int64(let v): Int(v)
        case .double(let v) where v.isFinite: Int(v)
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int32(let v): Double(v)
        case .int64(let v): Double(v)
        case .double(let v): v
        default: nil
        }
    }

    public var isScalar: Bool {
        switch self {
        case .document, .array: false
        default: true
        }
    }
}

public struct BSONElement: Hashable, Sendable {
    public var key: String
    public var value: BSON

    public init(_ key: String, _ value: BSON) {
        self.key = key
        self.value = value
    }
}

/// An ordered BSON document. Key order is kept, since commands depend on it (the command name comes first).
public struct BSONDocument: Hashable, Sendable, Sequence, ExpressibleByDictionaryLiteral {
    public var elements: [BSONElement]

    public init(_ elements: [BSONElement] = []) {
        self.elements = elements
    }

    public init(dictionaryLiteral elements: (String, BSON)...) {
        self.elements = elements.map { BSONElement($0.0, $0.1) }
    }

    public var keys: [String] { elements.map(\.key) }
    public var count: Int { elements.count }
    public var isEmpty: Bool { elements.isEmpty }

    public subscript(key: String) -> BSON? {
        get { elements.first { $0.key == key }?.value }
        set {
            if let index = elements.firstIndex(where: { $0.key == key }) {
                if let newValue { elements[index].value = newValue } else { elements.remove(at: index) }
            } else if let newValue {
                elements.append(BSONElement(key, newValue))
            }
        }
    }

    public mutating func append(_ key: String, _ value: BSON) {
        elements.append(BSONElement(key, value))
    }

    public func makeIterator() -> IndexingIterator<[BSONElement]> { elements.makeIterator() }

    /// The value at a dotted path (`address.city`, `items.0.sku`).
    public func value(atPath path: String) -> BSON? {
        var current: BSON = .document(self)
        for part in path.split(separator: ".", omittingEmptySubsequences: false).map(String.init) {
            switch current {
            case .document(let document):
                guard let next = document[part] else { return nil }
                current = next
            case .array(let array):
                guard let index = Int(part), array.indices.contains(index) else { return nil }
                current = array[index]
            default:
                return nil
            }
        }
        return current
    }

    /// `ok: 1` in a server reply.
    public var isOK: Bool { (self["ok"]?.doubleValue ?? 0) == 1 }
}

public enum BSONError: LocalizedError, Equatable, Sendable {
    case truncated
    case invalidLength
    case unknownType(UInt8)
    case invalidString

    public var errorDescription: String? {
        switch self {
        case .truncated: "BSON: unexpected end of data."
        case .invalidLength: "BSON: invalid length."
        case .unknownType(let byte): "BSON: unknown element type 0x\(String(byte, radix: 16))."
        case .invalidString: "BSON: invalid UTF-8 string."
        }
    }
}

// MARK: - Encoding

public enum BSONEncoder {
    public static func encode(_ document: BSONDocument) -> [UInt8] {
        var out: [UInt8] = []
        write(document, to: &out)
        return out
    }

    static func write(_ document: BSONDocument, to out: inout [UInt8]) {
        let start = out.count
        out.append(contentsOf: [0, 0, 0, 0])
        for element in document.elements {
            writeElement(element.key, element.value, to: &out)
        }
        out.append(0)
        patchLength(at: start, in: &out)
    }

    static func writeArray(_ array: [BSON], to out: inout [UInt8]) {
        let start = out.count
        out.append(contentsOf: [0, 0, 0, 0])
        for (index, value) in array.enumerated() {
            writeElement(String(index), value, to: &out)
        }
        out.append(0)
        patchLength(at: start, in: &out)
    }

    private static func patchLength(at start: Int, in out: inout [UInt8]) {
        let length = UInt32(out.count - start)
        out[start] = UInt8(length & 0xFF)
        out[start + 1] = UInt8((length >> 8) & 0xFF)
        out[start + 2] = UInt8((length >> 16) & 0xFF)
        out[start + 3] = UInt8((length >> 24) & 0xFF)
    }

    private static func writeElement(_ key: String, _ value: BSON, to out: inout [UInt8]) {
        out.append(value.typeByte)
        writeCString(key, to: &out)
        switch value {
        case .double(let v): appendLE(v.bitPattern, to: &out)
        case .string(let s), .javascript(let s), .symbol(let s): writeString(s, to: &out)
        case .document(let d): write(d, to: &out)
        case .array(let a): writeArray(a, to: &out)
        case .binary(let b):
            appendLE(UInt32(b.data.count), to: &out)
            out.append(b.subtype)
            out.append(contentsOf: b.data)
        case .undefined, .null, .minKey, .maxKey: break
        case .objectId(let id): out.append(contentsOf: id.bytes)
        case .bool(let b): out.append(b ? 1 : 0)
        case .date(let ms): appendLE(UInt64(bitPattern: ms), to: &out)
        case .regex(let r):
            writeCString(r.pattern, to: &out)
            writeCString(r.options, to: &out)
        case .javascriptWithScope(let code, let scope):
            let start = out.count
            out.append(contentsOf: [0, 0, 0, 0])
            writeString(code, to: &out)
            write(scope, to: &out)
            patchLength(at: start, in: &out)
        case .int32(let v): appendLE(UInt32(bitPattern: v), to: &out)
        case .timestamp(let t):
            appendLE(t.increment, to: &out)
            appendLE(t.timestamp, to: &out)
        case .int64(let v): appendLE(UInt64(bitPattern: v), to: &out)
        case .decimal128(let d):
            appendLE(d.low, to: &out)
            appendLE(d.high, to: &out)
        }
    }

    private static func writeCString(_ s: String, to out: inout [UInt8]) {
        // Keys can't hold NUL; drop any so the document stays well-formed.
        out.append(contentsOf: s.utf8.filter { $0 != 0 })
        out.append(0)
    }

    private static func writeString(_ s: String, to out: inout [UInt8]) {
        let bytes = Array(s.utf8)
        appendLE(UInt32(bytes.count + 1), to: &out)
        out.append(contentsOf: bytes)
        out.append(0)
    }

    static func appendLE<T: FixedWidthInteger>(_ value: T, to out: inout [UInt8]) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
    }
}

// MARK: - Decoding

public enum BSONDecoder {
    public static func decode(_ bytes: [UInt8]) throws -> BSONDocument {
        var reader = BSONReader(bytes: bytes)
        let document = try reader.readDocument()
        return document
    }

    public static func decode(_ data: Data) throws -> BSONDocument {
        try decode([UInt8](data))
    }
}

struct BSONReader {
    let bytes: [UInt8]
    var position: Int

    init(bytes: [UInt8], position: Int = 0) {
        self.bytes = bytes
        self.position = position
    }

    var remaining: Int { bytes.count - position }

    mutating func readInteger<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw BSONError.truncated }
        var value: T = 0
        for i in 0..<size {
            value |= T(truncatingIfNeeded: bytes[position + i]) << (8 * i)
        }
        position += size
        return value
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, remaining >= count else { throw BSONError.truncated }
        defer { position += count }
        return Array(bytes[position..<position + count])
    }

    mutating func readCString() throws -> String {
        guard let end = bytes[position...].firstIndex(of: 0) else { throw BSONError.truncated }
        let s = String(decoding: bytes[position..<end], as: UTF8.self)
        position = end + 1
        return s
    }

    mutating func readString() throws -> String {
        let length = Int(try readInteger(Int32.self))
        guard length >= 1, remaining >= length else { throw BSONError.invalidLength }
        let s = String(decoding: bytes[position..<position + length - 1], as: UTF8.self)
        position += length
        return s
    }

    mutating func readDocument() throws -> BSONDocument {
        let start = position
        let length = Int(try readInteger(Int32.self))
        guard length >= 5, start + length <= bytes.count else { throw BSONError.invalidLength }
        let end = start + length - 1
        var elements: [BSONElement] = []
        while position < end {
            let type = bytes[position]
            position += 1
            let key = try readCString()
            elements.append(BSONElement(key, try readValue(type: type)))
        }
        guard position == end, bytes[end] == 0 else { throw BSONError.invalidLength }
        position = end + 1
        return BSONDocument(elements)
    }

    mutating func readValue(type: UInt8) throws -> BSON {
        switch type {
        case 0x01: return .double(Double(bitPattern: try readInteger(UInt64.self)))
        case 0x02: return .string(try readString())
        case 0x03: return .document(try readDocument())
        case 0x04: return .array(try readDocument().elements.map(\.value))
        case 0x05:
            let length = Int(try readInteger(Int32.self))
            let subtype = try readBytes(1)[0]
            var data = try readBytes(length)
            // Old binary subtype 2 wraps the bytes in a second length prefix.
            if subtype == 2, data.count >= 4 { data.removeFirst(4) }
            return .binary(BSONBinary(subtype: subtype, data: Data(data)))
        case 0x06: return .undefined
        case 0x07: return .objectId(ObjectId(bytes: try readBytes(12))!)
        case 0x08: return .bool(try readBytes(1)[0] != 0)
        case 0x09: return .date(try readInteger(Int64.self))
        case 0x0A: return .null
        case 0x0B: return .regex(BSONRegex(pattern: try readCString(), options: try readCString()))
        case 0x0C:
            // DBPointer (deprecated): namespace + id, shown as a DBRef-like document.
            let namespace = try readString()
            let id = ObjectId(bytes: try readBytes(12))!
            return .document(["$ref": .string(namespace), "$id": .objectId(id)])
        case 0x0D: return .javascript(try readString())
        case 0x0E: return .symbol(try readString())
        case 0x0F:
            _ = try readInteger(Int32.self)
            let code = try readString()
            return .javascriptWithScope(code, try readDocument())
        case 0x10: return .int32(try readInteger(Int32.self))
        case 0x11:
            let increment = try readInteger(UInt32.self)
            return .timestamp(BSONTimestamp(timestamp: try readInteger(UInt32.self), increment: increment))
        case 0x12: return .int64(try readInteger(Int64.self))
        case 0x13:
            let low = try readInteger(UInt64.self)
            return .decimal128(BSONDecimal128(high: try readInteger(UInt64.self), low: low))
        case 0xFF: return .minKey
        case 0x7F: return .maxKey
        default: throw BSONError.unknownType(type)
        }
    }
}
