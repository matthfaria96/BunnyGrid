import Foundation

public struct MongoShellError: LocalizedError, Equatable, Sendable {
    public var message: String
    /// Offset (in Unicode scalars) where parsing failed.
    public var offset: Int

    public init(_ message: String, offset: Int) {
        self.message = message
        self.offset = offset
    }

    public var errorDescription: String? { message }
}

/// One method call in a shell statement: `find({ a: 1 })`, `.sort({ b: -1 })`.
public struct MongoShellCall: Equatable, Sendable {
    public var name: String
    public var arguments: [BSON]

    public init(_ name: String, _ arguments: [BSON] = []) {
        self.name = name
        self.arguments = arguments
    }
}

/// A shell statement: `db.coll.find(…).sort(…).limit(n)`, `db.runCommand({…})`, `show collections`, `use test`.
public struct MongoShellStatement: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        /// `db.method(…)`.
        case database
        /// `db.<name>.method(…)` or `db.getCollection("name").method(…)`.
        case collection(String)
        /// `show dbs`, `show collections`, `show users`…
        case show(String)
        /// `use <database>`.
        case use(String)
    }

    public var target: Target
    /// `db.getSiblingDB("other")…`: the database the statement runs in, when not the current one.
    public var database: String?
    /// The method and the calls chained after it (`find`, then `sort`, `limit`…).
    public var calls: [MongoShellCall]
    /// The statement's source text.
    public var text: String

    public init(target: Target, database: String? = nil, calls: [MongoShellCall] = [], text: String = "") {
        self.target = target
        self.database = database
        self.calls = calls
        self.text = text
    }

    public var method: String? { calls.first?.name }

    /// The chained call named `name` (`sort`, `limit`…), if any.
    public func chained(_ name: String) -> MongoShellCall? {
        calls.dropFirst().last { $0.name == name }
    }
}

/// Reads mongosh-style input without a JavaScript engine: JSON5-ish values (unquoted keys, single quotes,
/// trailing commas, comments), the shell's constructors (`ObjectId("…")`, `ISODate("…")`, `new Date(…)`,
/// `NumberLong`, `NumberInt`, `NumberDecimal`, `Timestamp`, `BinData`, `UUID`, `MinKey`/`MaxKey`), regex
/// literals, Extended JSON wrappers (`{"$oid": …}`), and statements of the form `db.coll.method(…).chain(…)`.
public enum MongoShellParser {
    /// One value; the whole text must be consumed.
    public static func parseValue(_ text: String) throws -> BSON {
        var parser = Parser(text)
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.atEnd else { throw parser.error("Unexpected text after the value") }
        return value
    }

    /// A document (`{ … }`). Empty or blank text is `{}`.
    public static func parseDocument(_ text: String) throws -> BSONDocument {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return BSONDocument() }
        guard case .document(let document) = try parseValue(text) else {
            throw MongoShellError("Expected a document in braces, such as { name: \"Ann\" }", offset: 0)
        }
        return document
    }

    /// An array of documents (`[{…}, {…}]`), e.g. an aggregation pipeline. A single document is accepted too.
    public static func parseDocuments(_ text: String) throws -> [BSONDocument] {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        switch try parseValue(text) {
        case .document(let document): return [document]
        case .array(let items):
            return try items.map {
                guard case .document(let document) = $0 else { throw MongoShellError("Expected an array of documents", offset: 0) }
                return document
            }
        default:
            throw MongoShellError("Expected an array of documents", offset: 0)
        }
    }

    /// Every statement in a script. Statements end at `;` or at the end of a line, unless the next line
    /// continues the chain with `.method(…)`.
    public static func parseScript(_ text: String) throws -> [MongoShellStatement] {
        var parser = Parser(text)
        var statements: [MongoShellStatement] = []
        while true {
            parser.skipWhitespace()
            while parser.peek == ";" {
                parser.advance()
                parser.skipWhitespace()
            }
            if parser.atEnd { break }
            let start = parser.position
            var statement = try parser.parseStatement()
            statement.text = parser.text(from: start).trimmingCharacters(in: .whitespacesAndNewlines)
            statements.append(statement)
            parser.skipInlineWhitespace()
            if let next = parser.peek, next != ";" && next != "\n" && next != "\r" {
                throw parser.error("Expected the end of the statement")
            }
        }
        return statements
    }

    /// Splits a script into statement texts for display (each statement's own source).
    public static func statementTexts(_ text: String) -> [String] {
        (try? parseScript(text).map(\.text)) ?? [text]
    }
}

private struct Parser {
    let scalars: [Unicode.Scalar]
    var position = 0

    init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    var atEnd: Bool { position >= scalars.count }
    var peek: Unicode.Scalar? { position < scalars.count ? scalars[position] : nil }

    func peek(_ offset: Int) -> Unicode.Scalar? {
        position + offset < scalars.count ? scalars[position + offset] : nil
    }

    mutating func advance() { position += 1 }

    func error(_ message: String) -> MongoShellError {
        let near = String(String.UnicodeScalarView(scalars[position..<min(scalars.count, position + 20)]))
        return MongoShellError(near.isEmpty ? "\(message) at the end of the text." : "\(message) near “\(near)”.", offset: position)
    }

    func text(from start: Int) -> String {
        String(String.UnicodeScalarView(scalars[start..<min(position, scalars.count)]))
    }

    // MARK: Whitespace and comments

    mutating func skipWhitespace() {
        while let c = peek {
            if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{A0}" || c == "\u{FEFF}" {
                advance()
            } else if c == "/" && peek(1) == "/" {
                while let d = peek, d != "\n" { _ = d; advance() }
            } else if c == "/" && peek(1) == "*" {
                position += 2
                while !atEnd && !(peek == "*" && peek(1) == "/") { advance() }
                position = min(position + 2, scalars.count)
            } else {
                break
            }
        }
    }

    /// Spaces and comments on the current line only (statement ends at a newline).
    mutating func skipInlineWhitespace() {
        while let c = peek {
            if c == " " || c == "\t" {
                advance()
            } else if c == "/" && peek(1) == "/" {
                while let d = peek, d != "\n" { _ = d; advance() }
            } else if c == "/" && peek(1) == "*" {
                position += 2
                while !atEnd && !(peek == "*" && peek(1) == "/") { advance() }
                position = min(position + 2, scalars.count)
            } else {
                break
            }
        }
    }

    mutating func expect(_ c: Unicode.Scalar, _ what: String) throws {
        skipWhitespace()
        guard peek == c else { throw error("Expected \(what)") }
        advance()
    }

    static func isIdentifierStart(_ c: Unicode.Scalar) -> Bool {
        c == "_" || c == "$" || CharacterSet.letters.contains(c)
    }

    static func isIdentifierPart(_ c: Unicode.Scalar) -> Bool {
        isIdentifierStart(c) || ("0"..."9").contains(c)
    }

    mutating func identifier() -> String? {
        guard let c = peek, Self.isIdentifierStart(c) else { return nil }
        let start = position
        while let d = peek, Self.isIdentifierPart(d) { advance() }
        return text(from: start)
    }

    // MARK: Statements

    mutating func parseStatement() throws -> MongoShellStatement {
        let start = position
        guard let word = identifier() else { throw error("Expected a command such as db.collection.find()") }
        switch word {
        case "show":
            skipInlineWhitespace()
            guard let what = identifier() else { throw error("Expected what to show (dbs, collections, users…)") }
            return MongoShellStatement(target: .show(what.lowercased()))
        case "use":
            skipInlineWhitespace()
            let begin = position
            while let c = peek, c != ";" && c != "\n" && c != "\r" && c != " " && c != "\t" { advance() }
            let name = text(from: begin)
            guard !name.isEmpty else { throw error("Expected a database name after use") }
            return MongoShellStatement(target: .use(name))
        case "db":
            break
        default:
            position = start
            throw error("Statements start with db., show or use")
        }

        var database: String?
        var collection: [String] = []
        var calls: [MongoShellCall] = []
        while true {
            var segments: [String] = []
            while true {
                skipWhitespace()
                if peek == "." {
                    advance()
                    skipWhitespace()
                    guard let name = identifier() else { throw error("Expected a name after the dot") }
                    segments.append(name)
                } else if peek == "[" {
                    advance()
                    skipWhitespace()
                    guard let quote = peek, quote == "\"" || quote == "'" || quote == "`" else { throw error("Expected a quoted collection name") }
                    segments.append(try parseString())
                    try expect("]", "]")
                } else {
                    break
                }
            }
            skipWhitespace()
            guard peek == "(" else {
                if calls.isEmpty { throw error("Expected a method call such as .find()") }
                if !segments.isEmpty { throw error("Expected ( after \(segments.last!)") }
                break
            }
            guard let name = segments.last else { throw error("Expected a method name") }
            let prefix = segments.dropLast()
            advance()
            let arguments = try parseArguments()
            if calls.isEmpty {
                collection += prefix
                if name == "getCollection" && collection.isEmpty {
                    guard case .string(let collectionName)? = arguments.first else { throw error("getCollection needs a collection name") }
                    collection = [collectionName]
                } else if name == "getSiblingDB" && collection.isEmpty && database == nil {
                    guard case .string(let databaseName)? = arguments.first else { throw error("getSiblingDB needs a database name") }
                    database = databaseName
                } else {
                    calls.append(MongoShellCall(name, arguments))
                }
            } else {
                guard prefix.isEmpty else { throw error("Unexpected .\(prefix.joined(separator: "."))") }
                calls.append(MongoShellCall(name, arguments))
            }
            // A chain continues on the next line when it starts with a dot.
            let save = position
            skipWhitespace()
            if peek == "." { continue }
            position = save
            if calls.isEmpty, !collection.isEmpty || database != nil {
                // db.getCollection("x") alone, or db.getSiblingDB("y") alone.
                continue
            }
            break
        }
        let target: MongoShellStatement.Target = collection.isEmpty ? .database : .collection(collection.joined(separator: "."))
        return MongoShellStatement(target: target, database: database, calls: calls)
    }

    /// Arguments after `(`, through the closing `)`.
    mutating func parseArguments() throws -> [BSON] {
        var arguments: [BSON] = []
        skipWhitespace()
        if peek == ")" {
            advance()
            return arguments
        }
        while true {
            arguments.append(try parseValue())
            skipWhitespace()
            if peek == "," {
                advance()
                skipWhitespace()
                if peek == ")" { advance(); return arguments }
                continue
            }
            if peek == ")" {
                advance()
                return arguments
            }
            throw error("Expected , or )")
        }
    }

    // MARK: Values

    mutating func parseValue() throws -> BSON {
        skipWhitespace()
        guard let c = peek else { throw error("Expected a value") }
        switch c {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"", "'", "`": return .string(try parseString())
        case "/": return .regex(try parseRegex())
        case "-", "+", ".", "0"..."9": return try parseNumber()
        default:
            guard let word = identifier() else { throw error("Unexpected character") }
            return try parseWord(word)
        }
    }

    mutating func parseObject() throws -> BSON {
        advance()
        var document = BSONDocument()
        while true {
            skipWhitespace()
            if peek == "}" {
                advance()
                break
            }
            let key: String
            if let c = peek, c == "\"" || c == "'" || c == "`" {
                key = try parseString()
            } else if let name = identifier() {
                key = name
            } else if let c = peek, ("0"..."9").contains(c) || c == "-" {
                let start = position
                while let d = peek, ("0"..."9").contains(d) || d == "." || d == "-" { advance() }
                key = text(from: start)
            } else {
                throw error("Expected a field name")
            }
            try expect(":", ": after the field name")
            document.append(key, try parseValue())
            skipWhitespace()
            if peek == "," {
                advance()
            } else if peek != "}" {
                throw error("Expected , or }")
            }
        }
        return Self.convertExtendedJSON(document)
    }

    mutating func parseArray() throws -> BSON {
        advance()
        var items: [BSON] = []
        while true {
            skipWhitespace()
            if peek == "]" {
                advance()
                break
            }
            items.append(try parseValue())
            skipWhitespace()
            if peek == "," {
                advance()
            } else if peek != "]" {
                throw error("Expected , or ]")
            }
        }
        return .array(items)
    }

    mutating func parseString() throws -> String {
        guard let quote = peek else { throw error("Expected a string") }
        advance()
        var out = String.UnicodeScalarView()
        while true {
            guard let c = peek else { throw error("Unterminated string") }
            advance()
            if c == quote { break }
            if c == "\\" {
                guard let e = peek else { throw error("Unterminated string") }
                advance()
                switch e {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "v": out.append("\u{0B}")
                case "0": out.append("\u{00}")
                case "\n": break
                case "u":
                    var hex = ""
                    if peek == "{" {
                        advance()
                        while let d = peek, d != "}" { hex.unicodeScalars.append(d); advance() }
                        advance()
                    } else {
                        for _ in 0..<4 {
                            guard let d = peek else { throw error("Bad \\u escape") }
                            hex.unicodeScalars.append(d)
                            advance()
                        }
                    }
                    guard var code = UInt32(hex, radix: 16) else { throw error("Bad \\u escape") }
                    // Surrogate pair.
                    if (0xD800...0xDBFF).contains(code), peek == "\\", peek(1) == "u" {
                        let save = position
                        position += 2
                        var low = ""
                        for _ in 0..<4 { if let d = peek { low.unicodeScalars.append(d); advance() } }
                        if let lowCode = UInt32(low, radix: 16), (0xDC00...0xDFFF).contains(lowCode) {
                            code = 0x10000 + ((code - 0xD800) << 10) + (lowCode - 0xDC00)
                        } else {
                            position = save
                        }
                    }
                    out.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                case "x":
                    var hex = ""
                    for _ in 0..<2 { if let d = peek { hex.unicodeScalars.append(d); advance() } }
                    out.append(UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init) ?? "\u{FFFD}")
                default: out.append(e)
                }
            } else {
                out.append(c)
            }
        }
        return String(out)
    }

    mutating func parseRegex() throws -> BSONRegex {
        advance()
        var pattern = String.UnicodeScalarView()
        var inClass = false
        while true {
            guard let c = peek, c != "\n" else { throw error("Unterminated regular expression") }
            advance()
            if c == "\\" {
                guard let e = peek else { throw error("Unterminated regular expression") }
                advance()
                // `\/` is only an escape for the delimiter.
                if e != "/" { pattern.append("\\") }
                pattern.append(e)
                continue
            }
            if c == "[" { inClass = true } else if c == "]" { inClass = false }
            if c == "/" && !inClass { break }
            pattern.append(c)
        }
        var flags = ""
        while let c = peek, CharacterSet.letters.contains(c) {
            flags.unicodeScalars.append(c)
            advance()
        }
        // JavaScript's `g` and `y` have no meaning on the server.
        return BSONRegex(pattern: String(pattern), options: flags.filter { "imsux".contains($0) })
    }

    mutating func parseNumber() throws -> BSON {
        let start = position
        if peek == "-" || peek == "+" { advance() }
        skipWhitespace()
        if let word = identifier() {
            guard word == "Infinity" else { throw error("Expected a number") }
            return .double(scalars[start] == "-" ? -.infinity : .infinity)
        }
        let digitsStart = position
        if peek == "0", let x = peek(1), x == "x" || x == "X" {
            position += 2
            let hexStart = position
            while let d = peek, d.properties.isASCIIHexDigit { advance() }
            guard let value = Int64(text(from: hexStart), radix: 16) else { throw error("Bad hex number") }
            return Self.integer(scalars[start] == "-" ? -value : value)
        }
        var isFloat = false
        while let d = peek {
            if ("0"..."9").contains(d) || d == "_" {
                advance()
            } else if d == "." {
                isFloat = true
                advance()
            } else if d == "e" || d == "E" {
                isFloat = true
                advance()
                if peek == "-" || peek == "+" { advance() }
            } else {
                break
            }
        }
        let digits = text(from: digitsStart).replacingOccurrences(of: "_", with: "")
        guard !digits.isEmpty, digits != "." else { throw error("Expected a number") }
        let negative = scalars[start] == "-"
        if !isFloat, let value = Int64(digits) {
            return Self.integer(negative ? -value : value)
        }
        guard let value = Double(digits) else { throw error("Bad number") }
        return .double(negative ? -value : value)
    }

    /// Whole numbers become Int32 when they fit (as the shell stores them), Int64 otherwise.
    static func integer(_ value: Int64) -> BSON {
        if let small = Int32(exactly: value) { return .int32(small) }
        return .int64(value)
    }

    mutating func parseWord(_ word: String) throws -> BSON {
        var name = word
        if name == "new" {
            skipWhitespace()
            guard let next = identifier() else { throw error("Expected a constructor after new") }
            name = next
        }
        switch name {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null": return .null
        case "undefined": return .undefined
        case "NaN": return .double(.nan)
        case "Infinity": return .double(.infinity)
        default: break
        }
        skipWhitespace()
        let arguments: [BSON]
        if peek == "(" {
            advance()
            arguments = try parseArguments()
        } else if name == "MinKey" || name == "MaxKey" {
            arguments = []
        } else {
            throw error("Unknown value “\(name)”")
        }
        return try constructor(name, arguments)
    }

    func constructor(_ name: String, _ args: [BSON]) throws -> BSON {
        func string(_ index: Int) -> String? {
            guard args.indices.contains(index) else { return nil }
            switch args[index] {
            case .string(let s): return s
            case .int32(let v): return String(v)
            case .int64(let v): return String(v)
            case .double(let v): return v == v.rounded() ? String(Int64(v)) : String(v)
            default: return nil
            }
        }
        switch name {
        case "ObjectId", "ObjectID":
            guard let hex = string(0) else { return .objectId(ObjectId()) }
            guard let id = ObjectId(hex) else { throw error("ObjectId needs 24 hex digits") }
            return .objectId(id)
        case "ISODate", "Date":
            if args.isEmpty { return .date(Date()) }
            switch args[0] {
            case .string(let text):
                guard let ms = BSONFormat.parseISODate(text) else { throw error("Invalid date “\(text)”") }
                return .date(ms)
            case .int32(let v): return .date(Int64(v))
            case .int64(let v): return .date(v)
            case .double(let v): return .date(Int64(v))
            default: throw error("Invalid date")
            }
        case "NumberLong", "Long":
            guard let text = string(0), let value = Int64(text) else { throw error("NumberLong needs an integer") }
            return .int64(value)
        case "NumberInt", "Int32":
            guard let text = string(0), let value = Int32(text) ?? Double(text).flatMap({ Int32(exactly: $0.rounded(.towardZero)) }) else {
                throw error("NumberInt needs a 32-bit integer")
            }
            return .int32(value)
        case "Double":
            guard let value = args.first?.doubleValue ?? string(0).flatMap(Double.init) else { throw error("Double needs a number") }
            return .double(value)
        case "NumberDecimal", "Decimal128":
            guard let text = string(0), let value = BSONDecimal128(text) else { throw error("Invalid decimal") }
            return .decimal128(value)
        case "Timestamp":
            if case .document(let d)? = args.first {
                return .timestamp(BSONTimestamp(timestamp: UInt32(clamping: d["t"]?.intValue ?? 0), increment: UInt32(clamping: d["i"]?.intValue ?? 0)))
            }
            return .timestamp(BSONTimestamp(timestamp: UInt32(clamping: args.first?.intValue ?? 0),
                                            increment: UInt32(clamping: args.count > 1 ? args[1].intValue ?? 0 : 0)))
        case "BinData":
            guard let subtype = args.first?.intValue, let base64 = string(1), let data = Data(base64Encoded: base64) else {
                throw error("BinData needs a subtype and base64 text")
            }
            return .binary(BSONBinary(subtype: UInt8(clamping: subtype), data: data))
        case "HexData":
            guard let subtype = args.first?.intValue, let hex = string(1), let data = Self.hexData(hex) else { throw error("HexData needs a subtype and hex text") }
            return .binary(BSONBinary(subtype: UInt8(clamping: subtype), data: data))
        case "UUID":
            if args.isEmpty { return .binary(BSONBinary(uuid: UUID())) }
            guard var text = string(0) else { throw error("UUID needs a string") }
            if !text.contains("-"), text.count == 32 {
                for offset in [8, 13, 18, 23] { text.insert("-", at: text.index(text.startIndex, offsetBy: offset)) }
            }
            guard let uuid = UUID(uuidString: text) else { throw error("Invalid UUID") }
            return .binary(BSONBinary(uuid: uuid))
        case "MinKey": return .minKey
        case "MaxKey": return .maxKey
        case "RegExp":
            guard let pattern = string(0) else { throw error("RegExp needs a pattern") }
            return .regex(BSONRegex(pattern: pattern, options: (string(1) ?? "").filter { "imsux".contains($0) }))
        case "Code":
            guard let code = string(0) else { throw error("Code needs a string") }
            if case .document(let scope)? = args.dropFirst().first { return .javascriptWithScope(code, scope) }
            return .javascript(code)
        case "DBRef":
            guard let collection = string(0), args.count >= 2 else { throw error("DBRef needs a collection and an id") }
            var document: BSONDocument = ["$ref": .string(collection), "$id": args[1]]
            if let db = string(2) { document.append("$db", .string(db)) }
            return .document(document)
        default:
            throw error("Unknown function “\(name)”")
        }
    }

    static func hexData(_ hex: String) -> Data? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var data = Data()
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(decoding: chars[i...i + 1], as: UTF8.self), radix: 16) else { return nil }
            data.append(byte)
        }
        return data
    }

    // MARK: Extended JSON

    /// `{"$oid": "…"}` and the other Extended JSON v1/v2 wrappers become the BSON values they stand for.
    static func convertExtendedJSON(_ document: BSONDocument) -> BSON {
        let keys = document.keys
        guard let first = keys.first, first.hasPrefix("$") else { return .document(document) }
        func text(_ key: String) -> String? { document[key]?.stringValue }
        switch keys.count {
        case 1:
            let value = document[first]!
            switch first {
            case "$oid": if let s = value.stringValue, let id = ObjectId(s) { return .objectId(id) }
            case "$date":
                switch value {
                case .string(let s): if let ms = BSONFormat.parseISODate(s) { return .date(ms) }
                case .int32(let v): return .date(Int64(v))
                case .int64(let v): return .date(v)
                case .double(let v): return .date(Int64(v))
                case .document(let inner): if let s = inner["$numberLong"]?.stringValue, let ms = Int64(s) { return .date(ms) }
                case .date(let ms): return .date(ms)
                default: break
                }
            case "$numberLong": if let s = value.stringValue, let v = Int64(s) { return .int64(v) }
            case "$numberInt": if let s = value.stringValue, let v = Int32(s) { return .int32(v) }
            case "$numberDouble":
                if let s = value.stringValue {
                    switch s {
                    case "Infinity": return .double(.infinity)
                    case "-Infinity": return .double(-.infinity)
                    case "NaN": return .double(.nan)
                    default: if let v = Double(s) { return .double(v) }
                    }
                }
            case "$numberDecimal": if let s = value.stringValue, let d = BSONDecimal128(s) { return .decimal128(d) }
            case "$binary":
                if case .document(let inner) = value, let base64 = inner["base64"]?.stringValue, let data = Data(base64Encoded: base64) {
                    let subtype = inner["subType"]?.stringValue.flatMap { UInt8($0, radix: 16) } ?? 0
                    return .binary(BSONBinary(subtype: subtype, data: data))
                }
            case "$uuid": if let s = value.stringValue, let uuid = UUID(uuidString: s) { return .binary(BSONBinary(uuid: uuid)) }
            case "$regularExpression":
                if case .document(let inner) = value, let pattern = inner["pattern"]?.stringValue {
                    return .regex(BSONRegex(pattern: pattern, options: inner["options"]?.stringValue ?? ""))
                }
            case "$timestamp":
                if case .document(let inner) = value, let t = inner["t"]?.intValue, let i = inner["i"]?.intValue {
                    return .timestamp(BSONTimestamp(timestamp: UInt32(clamping: t), increment: UInt32(clamping: i)))
                }
            case "$minKey": return .minKey
            case "$maxKey": return .maxKey
            case "$undefined": return .undefined
            case "$symbol": if let s = value.stringValue { return .symbol(s) }
            case "$code": if let s = value.stringValue { return .javascript(s) }
            default: break
            }
        case 2:
            // Legacy forms: {"$binary": base64, "$type": "00"}, {"$regex": …, "$options": …}, {"$code", "$scope"}.
            if let base64 = text("$binary"), let type = text("$type"), let data = Data(base64Encoded: base64) {
                return .binary(BSONBinary(subtype: UInt8(type, radix: 16) ?? 0, data: data))
            }
            if let pattern = text("$regex"), let options = text("$options") {
                return .regex(BSONRegex(pattern: pattern, options: options))
            }
            if let code = text("$code"), case .document(let scope)? = document["$scope"] {
                return .javascriptWithScope(code, scope)
            }
        default: break
        }
        return .document(document)
    }
}
