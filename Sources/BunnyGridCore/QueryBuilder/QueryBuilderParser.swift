import Foundation

public struct QueryBuilderParseError: LocalizedError, Equatable, Sendable {
    public let reason: String
    public var errorDescription: String? { "This statement can't be shown in the Query Builder: \(reason)." }
}

/// Reads a simple SELECT back into a `BuilderQuery`: what the builder itself writes, plus the
/// usual hand-written variations (any quoting, `!=`, `LIMIT o, n`, `TOP`, `OFFSET … FETCH`, comments).
/// Anything else (subqueries, expressions, UNION, CTEs, window functions) throws `QueryBuilderParseError`.
public enum QueryBuilderParser {
    public static func parse(_ sql: String) throws -> BuilderQuery {
        var parser = Parser(tokens: try tokenize(sql))
        return try parser.parseQuery()
    }

    /// Whether `sql` is something the builder can open.
    public static func canParse(_ sql: String) -> Bool {
        (try? parse(sql)) != nil
    }

    // MARK: - Tokens

    enum Token: Equatable {
        case word(String)          // unquoted identifier or keyword
        case quoted(String)        // quoted identifier
        case string(String)
        case number(String)
        case parameter(String)
        case symbol(String)
    }

    static func tokenize(_ sql: String) throws -> [Token] {
        let chars = Array(sql)
        var tokens: [Token] = []
        var i = 0
        func fail(_ reason: String) -> QueryBuilderParseError { QueryBuilderParseError(reason: reason) }
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c == "-", i + 1 < chars.count, chars[i + 1] == "-" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "#" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            // N'…' (SQL Server) and plain '…' strings.
            if c == "'" || ((c == "N" || c == "n") && i + 1 < chars.count && chars[i + 1] == "'" && (i == 0 || !isWordChar(chars[i - 1]))) {
                if c != "'" { i += 1 }
                i += 1
                var value = ""
                while true {
                    guard i < chars.count else { throw fail("unterminated string") }
                    if chars[i] == "\\", i + 1 < chars.count { value.append(chars[i + 1]); i += 2; continue }
                    if chars[i] == "'" {
                        if i + 1 < chars.count, chars[i + 1] == "'" { value.append("'"); i += 2; continue }
                        i += 1
                        break
                    }
                    value.append(chars[i]); i += 1
                }
                tokens.append(.string(value))
                continue
            }
            if c == "\"" || c == "`" || c == "[" {
                let close: Character = c == "[" ? "]" : c
                i += 1
                var value = ""
                while true {
                    guard i < chars.count else { throw fail("unterminated identifier") }
                    if chars[i] == close {
                        if i + 1 < chars.count, chars[i + 1] == close { value.append(close); i += 2; continue }
                        i += 1
                        break
                    }
                    value.append(chars[i]); i += 1
                }
                tokens.append(.quoted(value))
                continue
            }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var value = ""
                while i < chars.count, chars[i].isNumber || chars[i] == "." || chars[i] == "e" || chars[i] == "E" { value.append(chars[i]); i += 1 }
                tokens.append(.number(value))
                continue
            }
            if c == "?" { tokens.append(.parameter("?")); i += 1; continue }
            if (c == ":" || c == "$" || c == "@"), i + 1 < chars.count, isWordChar(chars[i + 1]) {
                var value = String(c)
                i += 1
                while i < chars.count, isWordChar(chars[i]) { value.append(chars[i]); i += 1 }
                tokens.append(.parameter(value))
                continue
            }
            if isWordChar(c) {
                var value = ""
                while i < chars.count, isWordChar(chars[i]) || chars[i] == "$" { value.append(chars[i]); i += 1 }
                tokens.append(.word(value))
                continue
            }
            let two = i + 1 < chars.count ? String([c, chars[i + 1]]) : ""
            if ["<=", ">=", "<>", "!="].contains(two) { tokens.append(.symbol(two)); i += 2; continue }
            if "=<>(),.*;-".contains(c) { tokens.append(.symbol(String(c))); i += 1; continue }
            throw fail("unexpected “\(c)”")
        }
        while tokens.last == .symbol(";") { tokens.removeLast() }
        if tokens.contains(.symbol(";")) { throw fail("more than one statement") }
        return tokens
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    static let clauseWords: Set<String> = [
        "FROM", "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "OFFSET", "FETCH", "INNER", "LEFT", "RIGHT", "FULL", "JOIN",
        "CROSS", "ON", "OUTER", "UNION", "EXCEPT", "INTERSECT", "AS", "AND", "OR", "NOT", "ASC", "DESC", "WINDOW", "FOR", "INTO",
        "NATURAL", "USING", "LATERAL", "RETURNING",
    ]

    // MARK: - Parser

    struct Parser {
        let tokens: [Token]
        var position = 0
        var query = BuilderQuery()
        /// Qualifier (alias or name, upper-cased) → table id.
        var references: [String: Int] = [:]

        init(tokens: [Token]) { self.tokens = tokens }

        func fail(_ reason: String) -> QueryBuilderParseError { QueryBuilderParseError(reason: reason) }

        var current: Token? { position < tokens.count ? tokens[position] : nil }

        func isWord(_ word: String, at offset: Int = 0) -> Bool {
            guard position + offset < tokens.count, case .word(let w) = tokens[position + offset] else { return false }
            return w.uppercased() == word
        }

        mutating func accept(_ word: String) -> Bool {
            guard isWord(word) else { return false }
            position += 1
            return true
        }

        mutating func expect(_ word: String) throws {
            guard accept(word) else { throw fail("expected \(word)") }
        }

        mutating func acceptSymbol(_ symbol: String) -> Bool {
            guard current == .symbol(symbol) else { return false }
            position += 1
            return true
        }

        mutating func expectSymbol(_ symbol: String) throws {
            guard acceptSymbol(symbol) else { throw fail("expected “\(symbol)”") }
        }

        mutating func identifier() throws -> String {
            switch current {
            case .quoted(let name):
                position += 1
                return name
            case .word(let name) where !QueryBuilderParser.clauseWords.contains(name.uppercased()) && name.uppercased() != "SELECT":
                position += 1
                return name
            default:
                throw fail("expected a name")
            }
        }

        mutating func integer() throws -> Int {
            var negative = false
            if acceptSymbol("-") { negative = true }
            guard case .number(let text) = current, let value = Int(text) else {
                if case .number(let text) = current, text == "18446744073709551615" { position += 1; return -1 }
                throw fail("expected a number")
            }
            position += 1
            return negative ? -value : value
        }

        // MARK: Statement

        mutating func parseQuery() throws -> BuilderQuery {
            if isWord("WITH") { throw fail("common table expressions are not supported") }
            try expect("SELECT")
            if accept("DISTINCT") { query.distinct = true } else { _ = accept("ALL") }
            if accept("TOP") {
                let parenthesized = acceptSymbol("(")
                query.limit = try integer()
                if parenthesized { try expectSymbol(")") }
                if isWord("PERCENT") || isWord("WITH") { throw fail("TOP PERCENT / WITH TIES are not supported") }
            }
            // Output columns are read as raw items and resolved after FROM.
            var items: [(qualifier: String?, column: String, aggregate: BuilderAggregate?, alias: String?)] = []
            repeat {
                items.append(try selectItem())
            } while acceptSymbol(",")

            if accept("FROM") {
                try fromClause()
            }
            for item in items {
                let id = try resolve(item.qualifier)
                if item.column == "*", item.qualifier == nil, item.aggregate == nil, items.count == 1 {
                    continue // SELECT * is the builder's empty column list
                }
                query.columns.append(BuilderColumn(tableID: id, column: item.column, aggregate: item.aggregate, alias: item.alias))
            }
            if accept("WHERE") { query.whereClause = try topGroup() }
            if accept("GROUP") {
                try expect("BY")
                repeat { query.groupBy.append(try operand()) } while acceptSymbol(",")
            }
            if accept("HAVING") { query.having = try topGroup() }
            if accept("ORDER") {
                try expect("BY")
                if current == .symbol("("), isWord("SELECT", at: 1) {
                    // SQL Server's ORDER BY (SELECT NULL) before OFFSET … FETCH.
                    position += 1
                    try expect("SELECT")
                    try expect("NULL")
                    try expectSymbol(")")
                } else {
                    repeat {
                        let value = try operand()
                        let descending = accept("DESC")
                        if !descending { _ = accept("ASC") }
                        query.orderBy.append(BuilderOrder(value, descending: descending))
                    } while acceptSymbol(",")
                }
            }
            if accept("LIMIT") {
                let first = try integer()
                if acceptSymbol(",") {
                    query.offset = first
                    query.limit = try integer()
                } else {
                    query.limit = first < 0 ? nil : first
                    if accept("OFFSET") { query.offset = try integer() }
                }
            }
            if accept("OFFSET") {
                query.offset = try integer()
                _ = accept("ROWS") || accept("ROW")
                if accept("FETCH") {
                    guard accept("NEXT") || accept("FIRST") else { throw fail("expected NEXT") }
                    query.limit = try integer()
                    guard accept("ROWS") || accept("ROW") else { throw fail("expected ROWS") }
                    try expect("ONLY")
                }
            }
            if let token = current {
                if case .word(let word) = token { throw fail("\(word.uppercased()) is not supported") }
                throw fail("unexpected text after the query")
            }
            return query
        }

        mutating func selectItem() throws -> (qualifier: String?, column: String, aggregate: BuilderAggregate?, alias: String?) {
            let (qualifier, column, aggregate) = try columnOrAggregate()
            var alias: String?
            if accept("AS") {
                alias = try identifier()
            } else if case .quoted = current {
                alias = try identifier()
            } else if case .word(let word) = current, !QueryBuilderParser.clauseWords.contains(word.uppercased()) {
                alias = try identifier()
            } else if case .string(let text) = current {
                position += 1
                alias = text
            }
            return (qualifier, column, aggregate, alias)
        }

        /// `*`, `t.*`, `col`, `t.col`, `COUNT(*)`, `SUM(t.col)`, `COUNT(DISTINCT t.col)`.
        mutating func columnOrAggregate() throws -> (String?, String, BuilderAggregate?) {
            if acceptSymbol("*") { return (nil, "*", nil) }
            if case .word(let word) = current, let function = BuilderAggregate(rawValue: word.uppercased()), function != .countDistinct,
               position + 1 < tokens.count, tokens[position + 1] == .symbol("(") {
                position += 2
                var aggregate = function
                if accept("DISTINCT") {
                    guard function == .count else { throw fail("DISTINCT inside \(function.rawValue) is not supported") }
                    aggregate = .countDistinct
                }
                let (qualifier, column) = try columnReference(allowStar: true)
                try expectSymbol(")")
                return (qualifier, column, aggregate)
            }
            if case .word = current, position + 1 < tokens.count, tokens[position + 1] == .symbol("(") {
                throw fail("functions and expressions are not supported")
            }
            let (qualifier, column) = try columnReference(allowStar: true)
            return (qualifier, column, nil)
        }

        mutating func columnReference(allowStar: Bool) throws -> (String?, String) {
            if allowStar, acceptSymbol("*") { return (nil, "*") }
            var parts = [try identifier()]
            while acceptSymbol(".") {
                if allowStar, acceptSymbol("*") { parts.append("*"); break }
                parts.append(try identifier())
            }
            if let token = current, token == .symbol("(") { throw fail("functions and expressions are not supported") }
            guard parts.count <= 2 else { throw fail("schema-qualified columns are not supported") }
            return parts.count == 2 ? (parts[0], parts[1]) : (nil, parts[0])
        }

        mutating func resolve(_ qualifier: String?) throws -> Int? {
            guard let qualifier else { return query.tables.count == 1 ? query.tables[0].id : nil }
            guard let id = references[qualifier.uppercased()] else { throw fail("unknown table “\(qualifier)”") }
            return id
        }

        // MARK: FROM

        mutating func tableSource() throws -> Int {
            if current == .symbol("(") { throw fail("subqueries are not supported") }
            var name = try identifier()
            var schema: String?
            if acceptSymbol(".") {
                schema = name
                name = try identifier()
                if acceptSymbol(".") { throw fail("three-part names are not supported") }
            }
            if current == .symbol("(") { throw fail("table functions are not supported") }
            var alias: String?
            if accept("AS") {
                alias = try identifier()
            } else if case .quoted = current {
                alias = try identifier()
            } else if case .word(let word) = current, !QueryBuilderParser.clauseWords.contains(word.uppercased()) {
                alias = try identifier()
            }
            let key = (alias ?? name).uppercased()
            guard references[key] == nil else { throw fail("“\(alias ?? name)” is used twice") }
            let id = (query.tables.map(\.id).max() ?? 0) + 1
            query.tables.append(BuilderTable(id: id, schema: schema, name: name, alias: alias))
            references[key] = id
            return id
        }

        mutating func fromClause() throws {
            _ = try tableSource()
            while true {
                if acceptSymbol(",") {
                    _ = try tableSource()
                    continue
                }
                var kind: BuilderJoinKind?
                if accept("CROSS") {
                    try expect("JOIN")
                    _ = try tableSource()
                    continue
                }
                if accept("INNER") { kind = .inner } else if accept("LEFT") { kind = .left } else if accept("RIGHT") { kind = .right } else if accept("FULL") { kind = .full }
                if kind != nil, kind != .inner { _ = accept("OUTER") }
                if kind == nil, isWord("JOIN") { kind = .inner }
                guard let kind else { break }
                try expect("JOIN")
                let id = try tableSource()
                if isWord("USING") { throw fail("JOIN … USING is not supported") }
                try expect("ON")
                repeat {
                    let (lq, lc) = try columnReference(allowStar: false)
                    try expectSymbol("=")
                    let (rq, rc) = try columnReference(allowStar: false)
                    guard let lq, let rq, let a = references[lq.uppercased()], let b = references[rq.uppercased()], a != b, a == id || b == id else {
                        throw fail("join conditions must compare columns of two tables")
                    }
                    // Stored with the earlier table on the left, so the kind reads the same.
                    let join = a == id
                        ? BuilderJoin(kind: kind, leftTable: b, leftColumn: rc, rightTable: a, rightColumn: lc)
                        : BuilderJoin(kind: kind, leftTable: a, leftColumn: lc, rightTable: b, rightColumn: rc)
                    query.joins.append(join)
                } while accept("AND")
            }
        }

        // MARK: Conditions

        mutating func topGroup() throws -> BuilderGroup {
            switch try orExpression() {
            case .group(let group): return group
            case .predicate(let p): return BuilderGroup(items: [.predicate(p)])
            }
        }

        mutating func orExpression() throws -> BuilderCondition {
            var items = [try andExpression()]
            while accept("OR") { items.append(try andExpression()) }
            return items.count == 1 ? items[0] : .group(BuilderGroup(conjunction: .or, items: items))
        }

        mutating func andExpression() throws -> BuilderCondition {
            var items = [try notExpression()]
            while accept("AND") { items.append(try notExpression()) }
            return items.count == 1 ? items[0] : .group(BuilderGroup(conjunction: .and, items: items))
        }

        mutating func notExpression() throws -> BuilderCondition {
            if accept("NOT") {
                switch try notExpression() {
                case .group(var group) where !group.negated:
                    group.negated = true
                    return .group(group)
                case let other:
                    return .group(BuilderGroup(negated: true, items: [other]))
                }
            }
            if acceptSymbol("(") {
                if isWord("SELECT") { throw fail("subqueries are not supported") }
                let inner = try orExpression()
                try expectSymbol(")")
                if case .predicate = inner { return .group(BuilderGroup(items: [inner])) }
                return inner
            }
            return .predicate(try predicate())
        }

        mutating func predicate() throws -> BuilderPredicate {
            let left = try operand()
            if accept("IS") {
                let not = accept("NOT")
                try expect("NULL")
                return BuilderPredicate(left: left, op: not ? .isNotNull : .isNull, values: [])
            }
            let not = accept("NOT")
            if accept("LIKE") { return BuilderPredicate(left: left, op: not ? .notLike : .like, values: [try operand()]) }
            if accept("IN") {
                try expectSymbol("(")
                if isWord("SELECT") { throw fail("subqueries are not supported") }
                var values: [BuilderOperand] = []
                repeat { values.append(try operand()) } while acceptSymbol(",")
                try expectSymbol(")")
                return BuilderPredicate(left: left, op: not ? .notIn : .isIn, values: values)
            }
            if accept("BETWEEN") {
                let low = try operand()
                try expect("AND")
                return BuilderPredicate(left: left, op: not ? .notBetween : .between, values: [low, try operand()])
            }
            if not { throw fail("expected LIKE, IN or BETWEEN after NOT") }
            guard case .symbol(let symbol) = current, let op = BuilderOperator(rawValue: symbol == "!=" ? "<>" : symbol) else {
                throw fail("unsupported condition")
            }
            position += 1
            return BuilderPredicate(left: left, op: op, values: [try operand()])
        }

        mutating func operand() throws -> BuilderOperand {
            switch current {
            case .string(let text):
                position += 1
                return .text(text)
            case .number(let text):
                position += 1
                return .number(text)
            case .parameter(let text):
                position += 1
                return .parameter(text)
            case .symbol("-"):
                position += 1
                guard case .number(let text) = current else { throw fail("expressions are not supported") }
                position += 1
                return .number("-" + text)
            case .word(let word) where word.uppercased() == "NULL":
                position += 1
                return .null
            default:
                let (qualifier, column, aggregate) = try columnOrAggregate()
                let id = try resolve(qualifier)
                if let token = current, case .symbol(let s) = token, ["+", "-", "*", "/", "||"].contains(s) {
                    throw fail("expressions are not supported")
                }
                return aggregate.map { .aggregate($0, tableID: id, column: column) } ?? .column(tableID: id, name: column)
            }
        }
    }
}
