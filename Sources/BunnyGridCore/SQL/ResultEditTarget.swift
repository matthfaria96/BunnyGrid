import Foundation

/// Navicat's "Edit Result": whether a query result came straight from one table, so its rows can be edited
/// through the table's primary key. Only a plain `SELECT … FROM table [WHERE …] [ORDER BY …] [LIMIT …]`
/// qualifies: no joins, grouping, DISTINCT, set operations, CTEs or subqueries in FROM. The select list may
/// mix `*`, bare columns (optionally qualified, or aliased to their own name) and expressions; expressions and
/// renamed columns stay read-only.
public struct ResultEditTarget: Equatable, Sendable {
    /// One item of the select list.
    public enum Item: Equatable, Sendable {
        /// `*` or `t.*`: every column of the table, in table order.
        case star
        /// A column of the table, returned under its own name.
        case column(String)
        /// Anything else (an expression, a literal, a column under another name).
        case other
    }

    public var table: String
    /// The schema (PostgreSQL, SQL Server) or database (MySQL, SQLite attached alias) named in FROM, if any.
    public var schema: String?
    public var items: [Item]

    public init(table: String, schema: String?, items: [Item]) {
        self.table = table
        self.schema = schema
        self.items = items
    }

    /// Why a statement's result can't be edited, for the Edit Result tooltip.
    public enum Refusal: Error, Equatable, Sendable {
        case notSelect
        case notSingleTable
        case grouped

        public var message: String {
            switch self {
            case .notSelect: "Only SELECT results can be edited"
            case .notSingleTable: "Only results from a single table can be edited (no joins, subqueries or set operations)"
            case .grouped: "Grouped, aggregated or DISTINCT results can't be edited"
            }
        }
    }

    /// The table a statement reads, or why its result isn't editable.
    public static func detect(_ sql: String) -> Result<ResultEditTarget, Refusal> {
        let tokens = Token.scan(sql)
        var i = 0
        func word(_ index: Int) -> String? {
            guard tokens.indices.contains(index), case .word(let w) = tokens[index] else { return nil }
            return w.uppercased()
        }
        guard word(0) == "SELECT" else { return .failure(.notSelect) }
        i = 1
        // SELECT ALL / TOP n (SQL Server) are fine; DISTINCT isn't.
        if word(i) == "DISTINCT" || word(i) == "DISTINCTROW" { return .failure(.grouped) }
        if word(i) == "ALL" { i += 1 }
        if word(i) == "TOP" {
            i += 1
            if tokens.indices.contains(i), case .number = tokens[i] { i += 1 } else if tokens.indices.contains(i), tokens[i] == .open {
                guard let close = matching(tokens, from: i) else { return .failure(.notSelect) }
                i = close + 1
            }
        }
        // The select list runs to the FROM at depth 0.
        var listEnd = i, depth = 0
        while listEnd < tokens.count {
            if tokens[listEnd] == .open {
                depth += 1
            } else if tokens[listEnd] == .close {
                depth -= 1
            } else if depth == 0, case .word(let w) = tokens[listEnd], w.uppercased() == "FROM" {
                break
            }
            listEnd += 1
        }
        guard listEnd < tokens.count else { return .failure(.notSingleTable) }
        let list = Array(tokens[i..<listEnd])
        // FROM name[.name[.name]] [AS] [alias]
        var p = listEnd + 1
        var parts: [String] = []
        while tokens.indices.contains(p) {
            guard let name = tokens[p].identifier else { return .failure(.notSingleTable) }
            parts.append(name)
            p += 1
            if tokens.indices.contains(p), tokens[p] == .dot { p += 1 } else { break }
        }
        guard !parts.isEmpty, parts.count <= 3 else { return .failure(.notSingleTable) }
        var alias: String?
        if word(p) == "AS" { p += 1; alias = tokens.indices.contains(p) ? tokens[p].identifier : nil; p += 1 }
        else if tokens.indices.contains(p), let candidate = tokens[p].identifier,
                !(tokens[p].isBareWord && clauseWords.contains(candidate.uppercased())) {
            alias = candidate
            p += 1
        }
        // What follows may only be WHERE / ORDER BY / LIMIT / OFFSET / FETCH / FOR (no second table, join or grouping).
        depth = 0
        var q = p
        while q < tokens.count {
            let token = tokens[q]
            switch token {
            case .open: depth += 1
            case .close: depth -= 1
            case .comma where depth == 0: return .failure(.notSingleTable)
            case .word(let w) where depth == 0:
                let upper = w.uppercased()
                if joinWords.contains(upper) || setWords.contains(upper) { return .failure(.notSingleTable) }
                if ["GROUP", "HAVING", "WINDOW"].contains(upper) { return .failure(.grouped) }
            default: break
            }
            q += 1
        }
        let table = parts[parts.count - 1]
        let schema = parts.count >= 2 ? parts[parts.count - 2] : nil
        let qualifiers = Set([table.lowercased(), alias?.lowercased()].compactMap { $0 })
        var items: [Item] = []
        for item in splitTopLevel(list) {
            if item.contains(where: { $0.isAggregateCall }) { return .failure(.grouped) }
            items.append(classify(item, qualifiers: qualifiers))
        }
        guard !items.isEmpty else { return .failure(.notSelect) }
        return .success(ResultEditTarget(table: table, schema: schema, items: items))
    }

    /// The table column behind each result column (nil for read-only ones), given the table's columns in order;
    /// nil when the select list doesn't line up with `resultColumns` (e.g. a star and a different column count).
    public func sourceColumns(resultColumns: [String], tableColumns: [String]) -> [String?]? {
        let lowered = Dictionary(tableColumns.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var sources: [String?] = []
        for item in items {
            switch item {
            case .star: sources += tableColumns.map { Optional($0) }
            case .column(let name): sources.append(lowered[name.lowercased()])
            case .other: sources.append(nil)
            }
        }
        guard sources.count == resultColumns.count else { return nil }
        // A source counts only when the result column carries its name (the server may rename duplicates).
        return zip(sources, resultColumns).map { source, column in
            guard let source, source.lowercased() == column.lowercased() else { return nil }
            return column
        }
    }

    // MARK: - Parsing

    static let clauseWords: Set<String> = ["WHERE", "ORDER", "LIMIT", "OFFSET", "FETCH", "FOR", "GROUP", "HAVING", "WINDOW",
                                           "UNION", "INTERSECT", "EXCEPT", "MINUS", "JOIN", "INNER", "LEFT", "RIGHT", "FULL",
                                           "CROSS", "NATURAL", "STRAIGHT_JOIN", "OUTER", "LATERAL", "TABLESAMPLE", "WITH", "INTO", "PROCEDURE", "LOCK"]
    static let joinWords: Set<String> = ["JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL", "STRAIGHT_JOIN", "OUTER", "LATERAL", "APPLY"]
    static let setWords: Set<String> = ["UNION", "INTERSECT", "EXCEPT", "MINUS", "INTO"]
    static let aggregates: Set<String> = ["COUNT", "SUM", "AVG", "MIN", "MAX", "GROUP_CONCAT", "STRING_AGG", "ARRAY_AGG", "JSON_AGG",
                                          "JSONB_AGG", "BOOL_AND", "BOOL_OR", "EVERY", "JSON_ARRAYAGG", "JSON_OBJECTAGG", "TOTAL", "STDDEV", "VARIANCE"]

    private static func classify(_ tokens: [Token], qualifiers: Set<String>) -> Item {
        var t = tokens
        if t == [.star] { return .star }
        if t.count == 3, let q = t[0].identifier, t[1] == .dot, t[2] == .star { return qualifiers.contains(q.lowercased()) ? .star : .other }
        // Drop a qualifier that names the table or its alias.
        if t.count >= 3, let q = t[0].identifier, t[1] == .dot, t[2].identifier != nil {
            guard qualifiers.contains(q.lowercased()) else { return .other }
            t.removeFirst(2)
        }
        guard let name = t.first?.identifier else { return .other }
        switch t.count {
        case 1: return .column(name)
        case 2: return t[1].identifier.map { $0.lowercased() == name.lowercased() ? .column(name) : .other } ?? .other
        case 3:
            guard case .word(let w) = t[1], w.uppercased() == "AS", let alias = t[2].identifier else { return .other }
            return alias.lowercased() == name.lowercased() ? .column(name) : .other
        default: return .other
        }
    }

    private static func splitTopLevel(_ tokens: [Token]) -> [[Token]] {
        var items: [[Token]] = [[]], depth = 0
        for token in tokens {
            switch token {
            case .open: depth += 1
            case .close: depth -= 1
            case .comma where depth == 0: items.append([]); continue
            default: break
            }
            items[items.count - 1].append(token)
        }
        return items.filter { !$0.isEmpty }
    }

    private static func matching(_ tokens: [Token], from open: Int) -> Int? {
        var depth = 0
        for index in open..<tokens.count {
            if tokens[index] == .open { depth += 1 }
            if tokens[index] == .close { depth -= 1; if depth == 0 { return index } }
        }
        return nil
    }

    enum Token: Equatable {
        case word(String)
        /// `"name"`, `` `name` ``, `[name]`, unquoted.
        case quoted(String)
        case string
        case number
        case open, close, comma, dot, star
        case symbol
        /// A word followed by `(`: a function call.
        case call(String)

        var identifier: String? {
            switch self {
            case .word(let w): w
            case .quoted(let q): q
            default: nil
            }
        }

        var isBareWord: Bool { if case .word = self { true } else { false } }

        var isAggregateCall: Bool {
            if case .call(let name) = self { ResultEditTarget.aggregates.contains(name.uppercased()) } else { false }
        }

        static func scan(_ sql: String) -> [Token] {
            let chars = Array(sql.unicodeScalars)
            var tokens: [Token] = []
            var i = 0
            func peek(_ k: Int) -> Unicode.Scalar? { i + k < chars.count ? chars[i + k] : nil }
            while i < chars.count {
                let c = chars[i]
                if c.properties.isWhitespace { i += 1; continue }
                if c == "-", peek(1) == "-" { while i < chars.count, chars[i] != "\n" { i += 1 }; continue }
                if c == "#" { while i < chars.count, chars[i] != "\n" { i += 1 }; continue }
                if c == "/", peek(1) == "*" {
                    i += 2
                    while i < chars.count, !(chars[i] == "*" && peek(1) == "/") { i += 1 }
                    i += 2
                    continue
                }
                if c == "'" {
                    i += 1
                    while i < chars.count {
                        if chars[i] == "'" { if peek(1) == "'" { i += 2; continue }; break }
                        if chars[i] == "\\" { i += 1 }
                        i += 1
                    }
                    i += 1
                    tokens.append(.string)
                    continue
                }
                if c == "\"" || c == "`" || c == "[" {
                    let close: Unicode.Scalar = c == "[" ? "]" : c
                    var name = ""
                    i += 1
                    while i < chars.count {
                        if chars[i] == close {
                            if close != "]", peek(1) == close { name.unicodeScalars.append(close); i += 2; continue }
                            break
                        }
                        name.unicodeScalars.append(chars[i])
                        i += 1
                    }
                    i += 1
                    tokens.append(.quoted(name))
                    continue
                }
                if c.properties.isAlphabetic || c == "_" || c == "@" || c == "$" {
                    var w = ""
                    while i < chars.count, chars[i].properties.isAlphabetic || chars[i].properties.numericType != nil || chars[i] == "_" || chars[i] == "$" || chars[i] == "@" {
                        w.unicodeScalars.append(chars[i])
                        i += 1
                    }
                    var j = i
                    while j < chars.count, chars[j].properties.isWhitespace { j += 1 }
                    tokens.append(j < chars.count && chars[j] == "(" ? .call(w) : .word(w))
                    continue
                }
                if c.properties.numericType != nil {
                    while i < chars.count, chars[i].properties.numericType != nil || chars[i] == "." || chars[i] == "e" || chars[i] == "E" { i += 1 }
                    tokens.append(.number)
                    continue
                }
                switch c {
                case "(": tokens.append(.open)
                case ")": tokens.append(.close)
                case ",": tokens.append(.comma)
                case ".": tokens.append(.dot)
                case "*": tokens.append(.star)
                case ";": i = chars.count; continue
                default: tokens.append(.symbol)
                }
                i += 1
            }
            return tokens
        }
    }
}
