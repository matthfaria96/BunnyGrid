import Foundation

/// Splits a console line into arguments with redis-cli's quoting rules: double quotes take
/// `\n \r \t \b \a \\ \" \xHH`, single quotes take only `\'`, and a closing quote must be followed by a space.
public enum RedisCommandLine {
    public enum ParseError: LocalizedError, Equatable, Sendable {
        case unbalancedQuotes
        case quoteNotFollowedBySpace

        public var errorDescription: String? {
            switch self {
            case .unbalancedQuotes: "Invalid arguments: unbalanced quotes."
            case .quoteNotFollowedBySpace: "Invalid arguments: a closing quote must be followed by a space."
            }
        }
    }

    public static func parse(_ line: String) throws -> [Data] {
        let b = Array(line.utf8)
        var i = 0
        var args: [Data] = []
        func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 97...102: c - 87
            case 65...70: c - 55
            default: nil
            }
        }
        while true {
            while i < b.count, isSpace(b[i]) { i += 1 }
            guard i < b.count else { return args }
            var current: [UInt8] = []
            var inDouble = false, inSingle = false
            var done = false
            while !done {
                if inDouble {
                    guard i < b.count else { throw ParseError.unbalancedQuotes }
                    let c = b[i]
                    if c == 92, i + 3 < b.count, b[i + 1] == UInt8(ascii: "x"), let h = hex(b[i + 2]), let l = hex(b[i + 3]) {
                        current.append(h << 4 | l); i += 3
                    } else if c == 92, i + 1 < b.count {
                        i += 1
                        switch b[i] {
                        case UInt8(ascii: "n"): current.append(10)
                        case UInt8(ascii: "r"): current.append(13)
                        case UInt8(ascii: "t"): current.append(9)
                        case UInt8(ascii: "b"): current.append(8)
                        case UInt8(ascii: "a"): current.append(7)
                        default: current.append(b[i])
                        }
                    } else if c == 34 {
                        if i + 1 < b.count, !isSpace(b[i + 1]) { throw ParseError.quoteNotFollowedBySpace }
                        done = true
                    } else {
                        current.append(c)
                    }
                } else if inSingle {
                    guard i < b.count else { throw ParseError.unbalancedQuotes }
                    let c = b[i]
                    if c == 92, i + 1 < b.count, b[i + 1] == 39 {
                        current.append(39); i += 1
                    } else if c == 39 {
                        if i + 1 < b.count, !isSpace(b[i + 1]) { throw ParseError.quoteNotFollowedBySpace }
                        done = true
                    } else {
                        current.append(c)
                    }
                } else {
                    guard i < b.count else { break }
                    let c = b[i]
                    if isSpace(c) { done = true }
                    else if c == 34 { inDouble = true }
                    else if c == 39 { inSingle = true }
                    else { current.append(c) }
                }
                if i < b.count { i += 1 }
            }
            args.append(Data(current))
        }
    }

    public static func parseStrings(_ line: String) throws -> [String] {
        try parse(line).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Quotes an argument for display so that `parse` reads it back unchanged.
    public static func quote(_ data: Data) -> String {
        let plain = !data.isEmpty && data.allSatisfy { $0 > 32 && $0 < 127 && $0 != 34 && $0 != 39 && $0 != 92 }
        if plain { return String(decoding: data, as: UTF8.self) }
        var out = "\""
        for c in data {
            switch c {
            case 34: out += "\\\""
            case 92: out += "\\\\"
            case 10: out += "\\n"
            case 13: out += "\\r"
            case 9: out += "\\t"
            case 32..<127: out.append(Character(UnicodeScalar(c)))
            default: out += String(format: "\\x%02x", c)
            }
        }
        return out + "\""
    }

    /// redis-cli style rendering of a reply, one line per element with `1)` numbering.
    public static func render(_ value: RESPValue, indent: Int = 0) -> String {
        func nested(_ items: [RESPValue], empty: String) -> String {
            guard !items.isEmpty else { return empty }
            let width = String(items.count).count
            var lines: [String] = []
            for (n, item) in items.enumerated() {
                let label = String(repeating: " ", count: width - String(n + 1).count) + "\(n + 1)) "
                let body = render(item, indent: indent + label.count)
                lines.append((n == 0 ? "" : String(repeating: " ", count: indent)) + label + body)
            }
            return lines.joined(separator: "\n")
        }
        switch value {
        case .simpleString(let s): return s
        case .error(let s): return "(error) " + s
        case .integer(let n): return "(integer) \(n)"
        case .bulkString(let d): return quote(d)
        case .null: return "(nil)"
        case .double(let d): return "(double) " + RESPValue.format(d)
        case .boolean(let b): return b ? "(true)" : "(false)"
        case .bigNumber(let s): return "(big number) " + s
        case .verbatim(_, let t): return t
        case .array(let a), .set(let a), .push(let a): return nested(a, empty: "(empty array)")
        case .map(let pairs):
            return nested(pairs.flatMap { [$0.0, $0.1] }, empty: "(empty hash)")
        }
    }
}
