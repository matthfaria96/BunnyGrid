import Foundation

/// Text forms of BSON values: the shell syntax used by the JSON view and the document editor
/// (`ObjectId("…")`, `ISODate("…")`, `NumberLong(…)`, which `MongoShellParser` reads back without loss), and
/// relaxed Extended JSON for export files.
public enum BSONFormat {
    public enum Layout: Sendable {
        /// One line, `{ "a": 1, "b": [1, 2] }`.
        case compact
        /// Indented, one key per line.
        case pretty
    }

    // MARK: - Shell syntax

    public static func shell(_ document: BSONDocument, layout: Layout = .pretty) -> String {
        shell(.document(document), layout: layout)
    }

    public static func shell(_ value: BSON, layout: Layout = .pretty) -> String {
        var out = ""
        writeShell(value, layout: layout, indent: 0, to: &out)
        return out
    }

    private static func writeShell(_ value: BSON, layout: Layout, indent: Int, to out: inout String) {
        switch value {
        case .document(let document):
            if document.isEmpty { out += "{}"; return }
            switch layout {
            case .compact:
                out += "{ "
                for (i, element) in document.elements.enumerated() {
                    if i > 0 { out += ", " }
                    out += quote(element.key) + ": "
                    writeShell(element.value, layout: layout, indent: indent, to: &out)
                }
                out += " }"
            case .pretty:
                out += "{\n"
                let pad = String(repeating: "  ", count: indent + 1)
                for (i, element) in document.elements.enumerated() {
                    out += pad + quote(element.key) + ": "
                    writeShell(element.value, layout: layout, indent: indent + 1, to: &out)
                    out += i == document.count - 1 ? "\n" : ",\n"
                }
                out += String(repeating: "  ", count: indent) + "}"
            }
        case .array(let array):
            if array.isEmpty { out += "[]"; return }
            // Short arrays of scalars stay on one line, as mongosh prints them.
            if layout == .compact || (array.count <= 8 && array.allSatisfy(\.isScalar)) {
                out += "["
                for (i, item) in array.enumerated() {
                    if i > 0 { out += ", " }
                    writeShell(item, layout: .compact, indent: indent, to: &out)
                }
                out += "]"
            } else {
                out += "[\n"
                let pad = String(repeating: "  ", count: indent + 1)
                for (i, item) in array.enumerated() {
                    out += pad
                    writeShell(item, layout: layout, indent: indent + 1, to: &out)
                    out += i == array.count - 1 ? "\n" : ",\n"
                }
                out += String(repeating: "  ", count: indent) + "]"
            }
        default:
            out += scalarShell(value)
        }
    }

    /// A scalar in shell syntax. Documents and arrays come out compact.
    public static func scalarShell(_ value: BSON) -> String {
        switch value {
        case .double(let v): return formatDouble(v)
        case .string(let s), .symbol(let s): return quote(s)
        case .document, .array: return shell(value, layout: .compact)
        case .binary(let b):
            if let uuid = b.uuid { return "UUID(\"\(uuid.uuidString.lowercased())\")" }
            return "BinData(\(b.subtype), \"\(b.data.base64EncodedString())\")"
        case .undefined: return "undefined"
        case .objectId(let id): return "ObjectId(\"\(id.hexString)\")"
        case .bool(let b): return b ? "true" : "false"
        case .date(let ms):
            if let iso = isoString(milliseconds: ms) { return "ISODate(\"\(iso)\")" }
            return "new Date(\(ms))"
        case .null: return "null"
        case .regex(let r): return "/\(r.pattern.replacingOccurrences(of: "/", with: "\\/"))/\(r.options)"
        case .javascript(let code): return "Code(\(quote(code)))"
        case .javascriptWithScope(let code, let scope): return "Code(\(quote(code)), \(shell(scope, layout: .compact)))"
        case .int32(let v): return String(v)
        case .timestamp(let t): return "Timestamp(\(t.timestamp), \(t.increment))"
        case .int64(let v): return "NumberLong(\(v))"
        case .decimal128(let d): return "NumberDecimal(\"\(d)\")"
        case .minKey: return "MinKey()"
        case .maxKey: return "MaxKey()"
        }
    }

    /// Text for one grid cell or tree value: strings unquoted, ids as hex, dates as ISO, nested values compact.
    public static func display(_ value: BSON) -> String {
        switch value {
        case .string(let s), .symbol(let s): s
        case .objectId(let id): id.hexString
        case .date(let ms): isoString(milliseconds: ms) ?? String(ms)
        case .int64(let v): String(v)
        case .decimal128(let d): d.description
        case .double(let v): formatDouble(v)
        default: scalarShell(value)
        }
    }

    static func formatDouble(_ v: Double) -> String {
        if v.isNaN { return "NaN" }
        if v.isInfinite { return v < 0 ? "-Infinity" : "Infinity" }
        if v == v.rounded(), abs(v) < 1e16 { return String(format: "%.1f", v) }
        return "\(v)"
    }

    public static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: - Dates

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
    private static let isoLock = NSLock()

    /// `2024-05-01T12:00:00.000Z` for years 0001–9999, nil outside.
    public static func isoString(milliseconds ms: Int64) -> String? {
        // -62135596800000 is 0001-01-01, 253402300799999 is 9999-12-31T23:59:59.999.
        guard ms >= -62_135_596_800_000, ms <= 253_402_300_799_999 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        isoLock.lock()
        defer { isoLock.unlock() }
        return isoFormatter.string(from: date)
    }

    /// Reads ISO 8601 dates as the shell's `ISODate` does: with or without fractions, `Z` or an offset, or a bare date.
    public static func parseISODate(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        let attempts: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
            [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate, .withFractionalSeconds],
            [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate],
            [.withFullDate, .withDashSeparatorInDate],
        ]
        for options in attempts {
            formatter.formatOptions = options
            if let date = formatter.date(from: trimmed) { return Int64((date.timeIntervalSince1970 * 1000).rounded()) }
        }
        // "2024-05-01 12:00:00" (space instead of T).
        if trimmed.count >= 19, trimmed[trimmed.index(trimmed.startIndex, offsetBy: 10)] == " " {
            var replaced = trimmed
            replaced.replaceSubrange(replaced.index(replaced.startIndex, offsetBy: 10)...replaced.index(replaced.startIndex, offsetBy: 10), with: "T")
            return parseISODate(replaced)
        }
        return nil
    }

    // MARK: - Extended JSON (relaxed)

    /// Relaxed Extended JSON v2, as `mongoexport` writes it.
    public static func extendedJSON(_ document: BSONDocument, pretty: Bool = false) -> String {
        var out = ""
        writeEJSON(.document(document), pretty: pretty, indent: 0, to: &out)
        return out
    }

    public static func extendedJSON(_ value: BSON, pretty: Bool = false) -> String {
        var out = ""
        writeEJSON(value, pretty: pretty, indent: 0, to: &out)
        return out
    }

    private static func writeEJSON(_ value: BSON, pretty: Bool, indent: Int, to out: inout String) {
        func object(_ pairs: [(String, String)]) -> String {
            "{" + pairs.map { "\(quote($0.0)):\($0.1)" }.joined(separator: ",") + "}"
        }
        switch value {
        case .document(let document):
            if document.isEmpty { out += "{}"; return }
            out += pretty ? "{\n" : "{"
            let pad = pretty ? String(repeating: "  ", count: indent + 1) : ""
            for (i, element) in document.elements.enumerated() {
                out += pad + quote(element.key) + (pretty ? ": " : ":")
                writeEJSON(element.value, pretty: pretty, indent: indent + 1, to: &out)
                if i < document.count - 1 { out += "," }
                if pretty { out += "\n" }
            }
            out += (pretty ? String(repeating: "  ", count: indent) : "") + "}"
        case .array(let array):
            if array.isEmpty { out += "[]"; return }
            out += "["
            for (i, item) in array.enumerated() {
                if i > 0 { out += pretty ? ", " : "," }
                writeEJSON(item, pretty: pretty, indent: indent + 1, to: &out)
            }
            out += "]"
        case .double(let v):
            if v.isFinite {
                out += v == v.rounded() && abs(v) < 1e16 ? String(format: "%.1f", v) : "\(v)"
            } else {
                out += object([("$numberDouble", quote(v.isNaN ? "NaN" : (v < 0 ? "-Infinity" : "Infinity")))])
            }
        case .string(let s): out += quote(s)
        case .binary(let b):
            out += object([("$binary", object([("base64", quote(b.data.base64EncodedString())), ("subType", quote(String(format: "%02x", b.subtype)))]))])
        case .undefined: out += object([("$undefined", "true")])
        case .objectId(let id): out += object([("$oid", quote(id.hexString))])
        case .bool(let b): out += b ? "true" : "false"
        case .date(let ms):
            // Relaxed form for 1970–9999; canonical outside.
            if ms >= 0, let iso = isoString(milliseconds: ms) {
                out += object([("$date", quote(iso))])
            } else {
                out += object([("$date", object([("$numberLong", quote(String(ms)))]))])
            }
        case .null: out += "null"
        case .regex(let r): out += object([("$regularExpression", object([("pattern", quote(r.pattern)), ("options", quote(r.options))]))])
        case .javascript(let code): out += object([("$code", quote(code))])
        case .symbol(let s): out += object([("$symbol", quote(s))])
        case .javascriptWithScope(let code, let scope):
            var scopeText = ""
            writeEJSON(.document(scope), pretty: false, indent: 0, to: &scopeText)
            out += object([("$code", quote(code)), ("$scope", scopeText)])
        case .int32(let v): out += String(v)
        case .timestamp(let t): out += object([("$timestamp", object([("t", String(t.timestamp)), ("i", String(t.increment))]))])
        case .int64(let v): out += String(v)
        case .decimal128(let d): out += object([("$numberDecimal", quote(d.description))])
        case .minKey: out += object([("$minKey", "1")])
        case .maxKey: out += object([("$maxKey", "1")])
        }
    }
}
