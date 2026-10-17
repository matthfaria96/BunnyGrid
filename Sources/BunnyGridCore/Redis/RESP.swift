import Foundation

/// A reply in the Redis serialization protocol, RESP2 and RESP3 types alike.
/// Strings stay as bytes (`Data`): Redis values are binary safe.
public indirect enum RESPValue: Hashable, Sendable {
    case simpleString(String)
    case error(String)
    case integer(Int64)
    /// `$-1` (RESP2) and `_` (RESP3) both decode to `.null`.
    case bulkString(Data)
    case array([RESPValue])
    case null
    // RESP3
    case double(Double)
    case boolean(Bool)
    case bigNumber(String)
    /// `=` verbatim string; `format` is the three-letter type such as "txt" or "mkd".
    case verbatim(format: String, text: String)
    case map([(RESPValue, RESPValue)])
    case set([RESPValue])
    /// Out-of-band message (pub/sub, client tracking invalidations).
    case push([RESPValue])

    public static func == (a: RESPValue, b: RESPValue) -> Bool {
        switch (a, b) {
        case (.simpleString(let x), .simpleString(let y)): x == y
        case (.error(let x), .error(let y)): x == y
        case (.integer(let x), .integer(let y)): x == y
        case (.bulkString(let x), .bulkString(let y)): x == y
        case (.array(let x), .array(let y)): x == y
        case (.null, .null): true
        case (.double(let x), .double(let y)): x == y || (x.isNaN && y.isNaN)
        case (.boolean(let x), .boolean(let y)): x == y
        case (.bigNumber(let x), .bigNumber(let y)): x == y
        case (.verbatim(let f1, let t1), .verbatim(let f2, let t2)): f1 == f2 && t1 == t2
        case (.map(let x), .map(let y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.set(let x), .set(let y)): x == y
        case (.push(let x), .push(let y)): x == y
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .simpleString(let s): hasher.combine(0); hasher.combine(s)
        case .error(let s): hasher.combine(1); hasher.combine(s)
        case .integer(let n): hasher.combine(2); hasher.combine(n)
        case .bulkString(let d): hasher.combine(3); hasher.combine(d)
        case .array(let a): hasher.combine(4); hasher.combine(a)
        case .null: hasher.combine(5)
        case .double(let d): hasher.combine(6); hasher.combine(d)
        case .boolean(let b): hasher.combine(7); hasher.combine(b)
        case .bigNumber(let s): hasher.combine(8); hasher.combine(s)
        case .verbatim(let f, let t): hasher.combine(9); hasher.combine(f); hasher.combine(t)
        case .map(let pairs): hasher.combine(10); for (k, v) in pairs { hasher.combine(k); hasher.combine(v) }
        case .set(let a): hasher.combine(11); hasher.combine(a)
        case .push(let a): hasher.combine(12); hasher.combine(a)
        }
    }

    public static func bulk(_ text: String) -> RESPValue { .bulkString(Data(text.utf8)) }

    public var isError: Bool { if case .error = self { true } else { false } }

    /// The reply as text: strings decoded as UTF-8 (lossy), numbers printed. nil for aggregates and null.
    public var string: String? {
        switch self {
        case .simpleString(let s), .error(let s), .bigNumber(let s): s
        case .bulkString(let d): String(decoding: d, as: UTF8.self)
        case .verbatim(_, let t): t
        case .integer(let n): String(n)
        case .double(let d): RESPValue.format(d)
        case .boolean(let b): b ? "1" : "0"
        default: nil
        }
    }

    /// Bytes of a string reply.
    public var data: Data? {
        switch self {
        case .bulkString(let d): d
        case .simpleString(let s), .bigNumber(let s): Data(s.utf8)
        case .verbatim(_, let t): Data(t.utf8)
        case .integer, .double, .boolean: string.map { Data($0.utf8) }
        default: nil
        }
    }

    public var int: Int64? {
        switch self {
        case .integer(let n): n
        case .boolean(let b): b ? 1 : 0
        case .double(let d): Int64(exactly: d.rounded())
        default: string.flatMap { Int64($0) }
        }
    }

    public var double: Double? {
        switch self {
        case .double(let d): d
        case .integer(let n): Double(n)
        default: string.flatMap(RESPValue.parseDouble)
        }
    }

    /// Elements of an array, set or push reply (RESP3 maps are flattened to key, value, key, value…).
    public var elements: [RESPValue]? {
        switch self {
        case .array(let a), .set(let a), .push(let a): a
        case .map(let pairs): pairs.flatMap { [$0.0, $0.1] }
        default: nil
        }
    }

    /// Key / value pairs from a RESP3 map or a RESP2 flat array (HGETALL, CONFIG GET, XINFO…).
    public var pairs: [(RESPValue, RESPValue)]? {
        switch self {
        case .map(let pairs): return pairs
        case .array(let a), .set(let a):
            guard a.count % 2 == 0 else { return nil }
            return stride(from: 0, to: a.count, by: 2).map { (a[$0], a[$0 + 1]) }
        default: return nil
        }
    }

    static func format(_ d: Double) -> String {
        if d.isInfinite { return d > 0 ? "inf" : "-inf" }
        if d.isNaN { return "nan" }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }

    static func parseDouble(_ text: String) -> Double? {
        switch text.lowercased() {
        case "inf", "+inf": .infinity
        case "-inf": -.infinity
        case "nan": .nan
        default: Double(text)
        }
    }
}

public enum RESPError: LocalizedError, Equatable, Sendable {
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .protocolError(let message): "Redis protocol error: \(message)"
        }
    }
}

/// Encodes commands and decodes replies. Pure functions over byte arrays, so the client's channel handler
/// and the tests share them.
public enum RESPCodec {
    /// A command as an array of bulk strings, the only form clients send.
    public static func encode(command arguments: [Data]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(16 + arguments.reduce(0) { $0 + $1.count + 16 })
        out.append(UInt8(ascii: "*"))
        out.append(contentsOf: Array(String(arguments.count).utf8))
        out.append(contentsOf: crlf)
        for argument in arguments {
            out.append(UInt8(ascii: "$"))
            out.append(contentsOf: Array(String(argument.count).utf8))
            out.append(contentsOf: crlf)
            out.append(contentsOf: argument)
            out.append(contentsOf: crlf)
        }
        return out
    }

    public static func encode(command arguments: [String]) -> [UInt8] {
        encode(command: arguments.map { Data($0.utf8) })
    }

    /// Serializes a reply (used by tests and mock servers).
    public static func encode(reply value: RESPValue) -> [UInt8] {
        var out: [UInt8] = []
        func line(_ prefix: Character, _ text: String) {
            out.append(UInt8(ascii: prefix.unicodeScalars.first!))
            out.append(contentsOf: Array(text.utf8))
            out.append(contentsOf: crlf)
        }
        func blob(_ prefix: Character, _ bytes: [UInt8]) {
            line(prefix, String(bytes.count))
            out.append(contentsOf: bytes)
            out.append(contentsOf: crlf)
        }
        switch value {
        case .simpleString(let s): line("+", s)
        case .error(let s): line("-", s)
        case .integer(let n): line(":", String(n))
        case .bulkString(let d): blob("$", Array(d))
        case .null: line("_", "")
        case .array(let a): line("*", String(a.count)); for v in a { out += encode(reply: v) }
        case .double(let d): line(",", RESPValue.format(d))
        case .boolean(let b): line("#", b ? "t" : "f")
        case .bigNumber(let s): line("(", s)
        case .verbatim(let format, let text): blob("=", Array("\(format):\(text)".utf8))
        case .map(let pairs): line("%", String(pairs.count)); for (k, v) in pairs { out += encode(reply: k); out += encode(reply: v) }
        case .set(let a): line("~", String(a.count)); for v in a { out += encode(reply: v) }
        case .push(let a): line(">", String(a.count)); for v in a { out += encode(reply: v) }
        }
        return out
    }

    /// Decodes one value from the start of `bytes`. Returns nil when more bytes are needed,
    /// otherwise the value and how many bytes it used. Attribute replies (`|`) are skipped.
    public static func decode(_ bytes: [UInt8], from start: Int = 0) throws -> (value: RESPValue, consumed: Int)? {
        var index = start
        guard let value = try decodeValue(bytes, &index) else { return nil }
        return (value, index - start)
    }

    static let crlf: [UInt8] = [13, 10]
    static let maxDepth = 512

    private static func readLine(_ b: [UInt8], _ i: inout Int) -> String? {
        var j = i
        while j + 1 < b.count {
            if b[j] == 13 && b[j + 1] == 10 {
                let text = String(decoding: b[i..<j], as: UTF8.self)
                i = j + 2
                return text
            }
            j += 1
        }
        return nil
    }

    private static func readLength(_ b: [UInt8], _ i: inout Int, _ type: Character) throws -> Int? {
        guard let text = readLine(b, &i) else { return nil }
        guard let n = Int(text), n >= -1 else { throw RESPError.protocolError("bad \(type) length “\(text)”") }
        return n
    }

    private static func readBlob(_ b: [UInt8], _ i: inout Int, length: Int) -> [UInt8]? {
        guard b.count >= i + length + 2 else { return nil }
        let bytes = Array(b[i..<(i + length)])
        i += length + 2
        return bytes
    }

    private static func decodeAggregate(_ b: [UInt8], _ i: inout Int, count: Int, depth: Int) throws -> [RESPValue]? {
        var items: [RESPValue] = []
        items.reserveCapacity(min(count, 4096))
        for _ in 0..<count {
            guard let item = try decodeValue(b, &i, depth: depth + 1) else { return nil }
            items.append(item)
        }
        return items
    }

    private static func decodeValue(_ b: [UInt8], _ i: inout Int, depth: Int = 0) throws -> RESPValue? {
        guard depth < maxDepth else { throw RESPError.protocolError("reply nested too deeply") }
        guard i < b.count else { return nil }
        let type = b[i]
        var j = i + 1
        let result: RESPValue
        switch type {
        case UInt8(ascii: "+"):
            guard let line = readLine(b, &j) else { return nil }
            result = .simpleString(line)
        case UInt8(ascii: "-"):
            guard let line = readLine(b, &j) else { return nil }
            result = .error(line)
        case UInt8(ascii: ":"):
            guard let line = readLine(b, &j) else { return nil }
            guard let n = Int64(line) else { throw RESPError.protocolError("bad integer “\(line)”") }
            result = .integer(n)
        case UInt8(ascii: "$"), UInt8(ascii: "!"), UInt8(ascii: "="):
            guard let length = try readLength(b, &j, Character(UnicodeScalar(type))) else { return nil }
            if length < 0 {
                result = .null
            } else {
                guard let bytes = readBlob(b, &j, length: length) else { return nil }
                switch type {
                case UInt8(ascii: "!"): result = .error(String(decoding: bytes, as: UTF8.self))
                case UInt8(ascii: "="):
                    let text = String(decoding: bytes, as: UTF8.self)
                    if bytes.count >= 4, bytes[3] == UInt8(ascii: ":") {
                        result = .verbatim(format: String(text.prefix(3)), text: String(text.dropFirst(4)))
                    } else {
                        result = .verbatim(format: "txt", text: text)
                    }
                default: result = .bulkString(Data(bytes))
                }
            }
        case UInt8(ascii: "*"), UInt8(ascii: "~"), UInt8(ascii: ">"):
            guard let count = try readLength(b, &j, Character(UnicodeScalar(type))) else { return nil }
            if count < 0 {
                result = .null
            } else {
                guard let items = try decodeAggregate(b, &j, count: count, depth: depth) else { return nil }
                result = type == UInt8(ascii: "*") ? .array(items) : type == UInt8(ascii: "~") ? .set(items) : .push(items)
            }
        case UInt8(ascii: "%"), UInt8(ascii: "|"):
            guard let count = try readLength(b, &j, Character(UnicodeScalar(type))), count >= 0 else {
                return nil
            }
            guard let items = try decodeAggregate(b, &j, count: count * 2, depth: depth) else { return nil }
            let pairs = stride(from: 0, to: items.count, by: 2).map { (items[$0], items[$0 + 1]) }
            if type == UInt8(ascii: "|") {
                // An attribute describes the reply that follows it; the client has no use for it.
                i = j
                return try decodeValue(b, &i, depth: depth)
            }
            result = .map(pairs)
        case UInt8(ascii: "_"):
            guard readLine(b, &j) != nil else { return nil }
            result = .null
        case UInt8(ascii: ","):
            guard let line = readLine(b, &j) else { return nil }
            guard let d = RESPValue.parseDouble(line) else { throw RESPError.protocolError("bad double “\(line)”") }
            result = .double(d)
        case UInt8(ascii: "#"):
            guard let line = readLine(b, &j) else { return nil }
            guard line == "t" || line == "f" else { throw RESPError.protocolError("bad boolean “\(line)”") }
            result = .boolean(line == "t")
        case UInt8(ascii: "("):
            guard let line = readLine(b, &j) else { return nil }
            result = .bigNumber(line)
        default:
            throw RESPError.protocolError("unexpected byte 0x\(String(type, radix: 16)) at the start of a reply")
        }
        i = j
        return result
    }
}

/// Accumulates bytes from the socket and yields complete replies.
public struct RESPStreamDecoder: Sendable {
    private var buffer: [UInt8] = []
    private var start = 0

    public init() {}

    public mutating func append(_ bytes: some Sequence<UInt8>) {
        if start > 0 && start >= buffer.count / 2 {
            buffer.removeFirst(start)
            start = 0
        }
        buffer.append(contentsOf: bytes)
    }

    /// The next complete reply, or nil when the buffer holds only part of one.
    public mutating func next() throws -> RESPValue? {
        guard start < buffer.count, let (value, consumed) = try RESPCodec.decode(buffer, from: start) else { return nil }
        start += consumed
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: buffer.count < 1 << 20)
            start = 0
        }
        return value
    }

    public var bufferedByteCount: Int { buffer.count - start }
}
