import Foundation

/// Local SQL formatter for the editor's Beautify SQL button: uppercase keywords, one clause per line,
/// indented select lists and conditions. Strings, quoted identifiers and comments are left untouched.
public enum SQLBeautifier {
    /// Clauses that start a new line at the statement's indentation.
    private static let clauses: [[String]] = [
        ["SELECT"], ["FROM"], ["WHERE"], ["GROUP", "BY"], ["HAVING"], ["ORDER", "BY"], ["LIMIT"], ["OFFSET"],
        ["UNION", "ALL"], ["UNION"], ["INTERSECT"], ["EXCEPT"], ["VALUES"], ["SET"], ["RETURNING"],
        ["INSERT", "INTO"], ["UPDATE"], ["DELETE", "FROM"], ["WINDOW"], ["WITH"],
        ["LEFT", "OUTER", "JOIN"], ["RIGHT", "OUTER", "JOIN"], ["FULL", "OUTER", "JOIN"],
        ["LEFT", "JOIN"], ["RIGHT", "JOIN"], ["FULL", "JOIN"], ["INNER", "JOIN"], ["CROSS", "JOIN"], ["JOIN"],
    ]
    /// Clauses whose comma-separated items go one per line.
    private static let listClauses: Set<String> = ["SELECT", "GROUP BY", "ORDER BY", "SET"]

    enum Token: Equatable {
        case word(String)
        case symbol(String)
        case literal(String)   // strings, quoted identifiers, comments
        case newlineComment(String)
    }

    public static func format(_ sql: String) -> String {
        let statements = SQLSplitter.split(sql).map(formatStatement)
        let terminated = sql.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(";")
        return statements.enumerated().map { index, statement in
            index < statements.count - 1 || terminated ? statement + ";" : statement
        }.joined(separator: "\n\n")
    }

    static func tokenize(_ sql: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(sql)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c == "-", i + 1 < chars.count, chars[i + 1] == "-" {
                var j = i
                while j < chars.count, chars[j] != "\n" { j += 1 }
                tokens.append(.newlineComment(String(chars[i..<j])))
                i = j
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                var j = i + 2
                while j + 1 < chars.count, !(chars[j] == "*" && chars[j + 1] == "/") { j += 1 }
                j = min(j + 2, chars.count)
                tokens.append(.literal(String(chars[i..<j])))
                i = j
                continue
            }
            if c == "'" || c == "\"" || c == "`" {
                var j = i + 1
                while j < chars.count {
                    if chars[j] == c {
                        if j + 1 < chars.count, chars[j + 1] == c { j += 2; continue }
                        break
                    }
                    j += 1
                }
                j = min(j + 1, chars.count)
                tokens.append(.literal(String(chars[i..<j])))
                i = j
                continue
            }
            if c.isLetter || c == "_" || c.isNumber || c == "$" || c == "@" || c == ":" && i + 1 < chars.count && chars[i + 1].isLetter {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "$" || chars[j] == "." && j + 1 < chars.count && chars[j + 1] != " " {
                    j += 1
                }
                tokens.append(.word(String(chars[i..<j])))
                i = j
                continue
            }
            // Multi-character operators.
            let two = i + 1 < chars.count ? String(chars[i...i + 1]) : ""
            if ["<=", ">=", "<>", "!=", "::", "||"].contains(two) {
                tokens.append(.symbol(two))
                i += 2
                continue
            }
            tokens.append(.symbol(String(c)))
            i += 1
        }
        return tokens
    }

    private static func isKeyword(_ word: String) -> Bool {
        SQLKeywords.all.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
    }

    static func formatStatement(_ sql: String) -> String {
        let tokens = tokenize(sql)
        var out = ""
        var depth = 0               // parenthesis depth
        var clauseDepth: [Int] = [0] // indentation of the clause per open parenthesis
        var currentClause = ""
        var i = 0
        var lineStart = true

        func indent(_ level: Int) -> String { String(repeating: "  ", count: max(level, 0)) }
        func newline(_ level: Int) {
            while out.hasSuffix(" ") { out.removeLast() }
            if !out.isEmpty { out += "\n" }
            out += indent(level)
            lineStart = true
        }
        func emit(_ text: String, spaceBefore: Bool = true) {
            if !lineStart, spaceBefore, !out.hasSuffix(" "), !out.hasSuffix("(") { out += " " }
            out += text
            lineStart = false
        }

        while i < tokens.count {
            let token = tokens[i]
            switch token {
            case .newlineComment(let text):
                emit(text)
                newline(clauseDepth.last ?? 0)
            case .literal(let text):
                emit(text)
            case .symbol(let s):
                switch s {
                case ",":
                    out += ","
                    lineStart = false
                    if listClauses.contains(currentClause), depth == clauseDepth.count - 1 {
                        newline((clauseDepth.last ?? 0) + 1)
                    }
                case "(":
                    emit("(", spaceBefore: !(out.last?.isLetter ?? false) && !(out.last?.isNumber ?? false) || lineStart)
                    depth += 1
                    // A subquery gets its own indentation level.
                    if case .word(let next)? = tokens[safe: i + 1], next.uppercased() == "SELECT" {
                        clauseDepth.append((clauseDepth.last ?? 0) + 2)
                    } else {
                        clauseDepth.append(clauseDepth.last ?? 0)
                    }
                case ")":
                    let wasSubquery = clauseDepth.count > 1 && clauseDepth.last! > clauseDepth[clauseDepth.count - 2]
                    depth = max(depth - 1, 0)
                    if clauseDepth.count > 1 { clauseDepth.removeLast() }
                    if wasSubquery { newline((clauseDepth.last ?? 0) + 1) }
                    while out.hasSuffix(" ") { out.removeLast() }
                    out += ")"
                    lineStart = false
                case ";":
                    while out.hasSuffix(" ") { out.removeLast() }
                    out += ";"
                case ".", "::":
                    while out.hasSuffix(" ") { out.removeLast() }
                    out += s
                    lineStart = true // no space after
                default:
                    emit(s)
                }
            case .word(let word):
                // Multi-word clause at this position?
                var matched: [String]?
                for clause in clauses {
                    guard i + clause.count <= tokens.count else { continue }
                    let words = (0..<clause.count).compactMap { offset -> String? in
                        if case .word(let w) = tokens[i + offset] { return w.uppercased() } else { return nil }
                    }
                    if words == clause { matched = clause; break }
                }
                if let clause = matched {
                    let level = clauseDepth.last ?? 0
                    let name = clause.joined(separator: " ")
                    if !(out.isEmpty || out.hasSuffix("(")) { newline(level) } else if out.hasSuffix("(") { newline(level) }
                    emit(name)
                    currentClause = name
                    if listClauses.contains(name) || name == "FROM" || name == "WHERE" || name == "HAVING" {
                        newline(level + 1)
                    }
                    i += clause.count
                    continue
                }
                let upper = word.uppercased()
                if (upper == "AND" || upper == "OR"), currentClause == "WHERE" || currentClause == "HAVING" || currentClause.hasSuffix("JOIN"), depth == clauseDepth.count - 1 {
                    newline((clauseDepth.last ?? 0) + 1)
                    emit(upper)
                } else if upper == "ON", currentClause.hasSuffix("JOIN") {
                    emit("ON")
                } else {
                    emit(isKeyword(word) && !word.contains(".") ? upper : word)
                }
            }
            i += 1
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
