import Foundation

/// Pretty-print, minify and validate JSON for the value editor, keeping keys in their original order.
public enum JSONFormatter {
    public struct InvalidJSON: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// nil when `text` is valid JSON (any value, not only objects), otherwise the parser's message.
    public static func validate(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Empty value" }
        do {
            _ = try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])
            return nil
        } catch let error as NSError {
            return (error.userInfo["NSDebugDescription"] as? String) ?? error.localizedDescription
        }
    }

    /// Indented JSON with `indent` spaces per level; `{}` and `[]` stay on one line.
    public static func pretty(_ text: String, indent: Int = 2) throws -> String {
        if let message = validate(text) { throw InvalidJSON(message: message) }
        let unit = String(repeating: " ", count: indent)
        var output = ""
        var depth = 0
        var inString = false
        var escaped = false
        var pendingOpen = false

        func newline() { output += "\n" + String(repeating: unit, count: depth) }

        for character in text {
            if inString {
                output.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            if character.isWhitespace { continue }
            if pendingOpen {
                pendingOpen = false
                if character == "}" || character == "]" {
                    depth -= 1
                    output.append(character)
                    continue
                }
                newline()
            }
            switch character {
            case "{", "[":
                output.append(character)
                depth += 1
                pendingOpen = true
            case "}", "]":
                depth -= 1
                newline()
                output.append(character)
            case ",":
                output.append(character)
                newline()
            case ":":
                output += ": "
            case "\"":
                inString = true
                output.append(character)
            default:
                output.append(character)
            }
        }
        return output
    }

    /// JSON without insignificant whitespace.
    public static func minify(_ text: String) throws -> String {
        if let message = validate(text) { throw InvalidJSON(message: message) }
        var output = ""
        var inString = false
        var escaped = false
        for character in text {
            if inString {
                output.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
            } else if !character.isWhitespace {
                if character == "\"" { inString = true }
                output.append(character)
            }
        }
        return output
    }
}

/// Hex dumps and hex parsing for binary values.
public enum HexFormatter {
    /// Lowercase hex digits without separators: `0aff`.
    public static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// `xxd`-style lines: offset, 16 bytes in two groups of eight, and the printable ASCII.
    /// Stops after `limit` bytes and says how many were left out.
    public static func dump(_ data: Data, limit: Int = 64 * 1024) -> String {
        guard !data.isEmpty else { return "" }
        let bytes = [UInt8](data.prefix(limit))
        var lines: [String] = []
        lines.reserveCapacity(bytes.count / 16 + 1)
        for start in stride(from: 0, to: bytes.count, by: 16) {
            let chunk = bytes[start..<min(start + 16, bytes.count)]
            var hex = ""
            for (offset, byte) in chunk.enumerated() {
                hex += String(format: "%02x ", byte)
                if offset == 7 { hex += " " }
            }
            let padded = hex.padding(toLength: 16 * 3 + 1, withPad: " ", startingAt: 0)
            let ascii = String(chunk.map { (0x20...0x7e).contains($0) ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08x  ", start) + padded + " |" + ascii + "|")
        }
        if data.count > limit { lines.append("… \(data.count - limit) more bytes") }
        return lines.joined(separator: "\n")
    }

    /// Bytes from hex text. Accepts `0x…`, `\x…` (PostgreSQL) and `X'…'` (SQL); whitespace is ignored.
    /// With `requirePrefix`, plain digits are not taken as hex (so `cafe` typed into a blob stays text).
    public static func parse(_ text: String, requirePrefix: Bool = true) -> Data? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("0x") || body.hasPrefix("0X") || body.hasPrefix("\\x") {
            body.removeFirst(2)
        } else if (body.hasPrefix("X'") || body.hasPrefix("x'")) && body.hasSuffix("'") && body.count >= 3 {
            body = String(body.dropFirst(2).dropLast())
        } else if requirePrefix {
            return nil
        }
        let digits = body.filter { !$0.isWhitespace }
        guard digits.count % 2 == 0, digits.allSatisfy(\.isHexDigit) else { return nil }
        var data = Data(capacity: digits.count / 2)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

/// What a blob looks like from its first bytes, for the value editor's preview and Save panel.
public enum BlobKind: String, Sendable, CaseIterable {
    case png, jpeg, gif, bmp, tiff, webp, heic, pdf, zip, gzip, sqlite, utf8Text, binary

    public static func detect(_ data: Data) -> BlobKind {
        let b = [UInt8](data.prefix(16))
        func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            b.count >= offset + prefix.count && Array(b[offset..<offset + prefix.count]) == prefix
        }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if starts(Array("GIF8".utf8)) { return .gif }
        if starts(Array("BM".utf8)) && data.count > 14 { return .bmp }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if starts(Array("RIFF".utf8)) && starts(Array("WEBP".utf8), at: 8) { return .webp }
        if starts(Array("ftyp".utf8), at: 4) && (starts(Array("heic".utf8), at: 8) || starts(Array("heix".utf8), at: 8) || starts(Array("mif1".utf8), at: 8)) { return .heic }
        if starts(Array("%PDF".utf8)) { return .pdf }
        if starts([0x50, 0x4B, 0x03, 0x04]) { return .zip }
        if starts([0x1F, 0x8B]) { return .gzip }
        if starts(Array("SQLite format 3".utf8)) { return .sqlite }
        if !data.isEmpty, let text = String(data: data.prefix(4096), encoding: .utf8),
           !text.unicodeScalars.contains(where: { $0.value < 0x09 || ($0.value > 0x0D && $0.value < 0x20) }) {
            return .utf8Text
        }
        return .binary
    }

    public var isImage: Bool { [.png, .jpeg, .gif, .bmp, .tiff, .webp, .heic].contains(self) }

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .utf8Text: "txt"
        case .binary: "bin"
        case .gzip: "gz"
        default: rawValue
        }
    }

    public var displayName: String {
        switch self {
        case .png: "PNG image"
        case .jpeg: "JPEG image"
        case .gif: "GIF image"
        case .bmp: "BMP image"
        case .tiff: "TIFF image"
        case .webp: "WebP image"
        case .heic: "HEIC image"
        case .pdf: "PDF document"
        case .zip: "ZIP archive"
        case .gzip: "gzip data"
        case .sqlite: "SQLite database"
        case .utf8Text: "UTF-8 text"
        case .binary: "Binary data"
        }
    }
}

/// Reads and writes the text form of temporal values (`2026-10-17`, `09:30:00`, `2026-10-17 09:30:00-03:00`)
/// for the value editor's date picker. Values without an offset are wall-clock times in `timeZone`.
public enum TemporalText {
    public static func parse(_ text: String, category: ColumnTypeCategory, timeZone: TimeZone = .current) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var components = DateComponents()
        var rest = Substring(trimmed)

        func number(_ length: Int) -> Int? {
            guard rest.count >= length else { return nil }
            let digits = rest.prefix(length)
            guard digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber), let value = Int(digits) else { return nil }
            rest = rest.dropFirst(length)
            return value
        }
        func take(_ character: Character) -> Bool {
            guard rest.first == character else { return false }
            rest = rest.dropFirst()
            return true
        }
        func time() -> Bool {
            guard let hour = number(2), take(":"), let minute = number(2) else { return false }
            components.hour = hour
            components.minute = minute
            components.second = 0
            if take(":") {
                guard let second = number(2) else { return false }
                components.second = second
                if take(".") {
                    let fraction = rest.prefix { $0.isASCII && $0.isNumber }
                    rest = rest.dropFirst(fraction.count)
                    components.nanosecond = Int((Double("0." + fraction) ?? 0) * 1_000_000_000)
                }
            }
            return true
        }

        if category == .time || category == .timeWithTimeZone {
            components.year = 2000
            components.month = 1
            components.day = 1
            guard time() else { return nil }
        } else {
            guard let year = number(4), take("-"), let month = number(2), take("-"), let day = number(2) else { return nil }
            components.year = year
            components.month = month
            components.day = day
            if take(" ") || take("T") {
                guard time() else { return nil }
            }
        }
        var zone = timeZone
        rest = rest.drop { $0 == " " }
        if take("Z") {
            zone = TimeZone(secondsFromGMT: 0)!
        } else if let sign = rest.first, sign == "+" || sign == "-" {
            rest = rest.dropFirst()
            guard let hours = number(2) else { return nil }
            _ = take(":")
            let minutes = number(2) ?? 0
            let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
            guard let offset = TimeZone(secondsFromGMT: seconds) else { return nil }
            zone = offset
        }
        guard rest.isEmpty else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == components.day else { return nil }
        return date
    }

    public static func format(_ date: Date, category: ColumnTypeCategory, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = switch category {
        case .date: "yyyy-MM-dd"
        case .time: "HH:mm:ss"
        case .timeWithTimeZone: "HH:mm:ssxxx"
        case .dateTimeWithTimeZone: "yyyy-MM-dd HH:mm:ssxxx"
        default: "yyyy-MM-dd HH:mm:ss"
        }
        return formatter.string(from: date)
    }
}
