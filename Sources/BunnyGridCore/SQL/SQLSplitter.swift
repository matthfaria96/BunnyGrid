import Foundation

/// Splits a script into individual statements on `;`, ignoring semicolons inside
/// string literals, quoted identifiers, comments, PostgreSQL dollar-quoted bodies and the
/// BEGIN … END body of a CREATE TRIGGER (SQLite, MySQL).
public enum SQLSplitter {
    public static func split(_ script: String) -> [String] {
        let chars = Array(script)
        var statements: [String] = []
        var current = ""
        var i = 0
        // Words of the current statement, to recognize CREATE … TRIGGER and its BEGIN/CASE … END nesting.
        var word = ""
        var isTrigger = false
        var sawCreate = false
        var blockDepth = 0

        func endWord() {
            guard !word.isEmpty else { return }
            let upper = word.uppercased()
            if upper == "CREATE", current.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("CREATE") { sawCreate = true }
            if sawCreate, upper == "TRIGGER" { isTrigger = true }
            if isTrigger {
                if upper == "BEGIN" || upper == "CASE" { blockDepth += 1 }
                if upper == "END", blockDepth > 0 { blockDepth -= 1 }
            }
            word = ""
        }

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !isOnlyComments(trimmed) { statements.append(trimmed) }
            current = ""
            isTrigger = false
            sawCreate = false
            blockDepth = 0
        }

        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil

            if c.isLetter || c == "_" {
                word.append(c)
            } else {
                endWord()
            }

            switch c {
            case "'", "\"", "`":
                let end = scanQuoted(chars, from: i, quote: c)
                current.append(contentsOf: chars[i..<end])
                i = end
            case "-" where next == "-":
                let end = scanLineComment(chars, from: i)
                current.append(contentsOf: chars[i..<end])
                i = end
            case "/" where next == "*":
                let end = scanBlockComment(chars, from: i)
                current.append(contentsOf: chars[i..<end])
                i = end
            case "$":
                if let tag = dollarTag(chars, at: i) {
                    let end = scanDollarQuoted(chars, from: i, tag: tag)
                    current.append(contentsOf: chars[i..<end])
                    i = end
                } else {
                    current.append(c)
                    i += 1
                }
            case ";" where blockDepth > 0:
                current.append(c)
                i += 1
            case ";":
                flush()
                i += 1
            default:
                current.append(c)
                i += 1
            }
        }
        flush()
        return statements
    }

    /// Returns the index just past the closing quote. Doubled quotes are an escape.
    private static func scanQuoted(_ chars: [Character], from start: Int, quote: Character) -> Int {
        var i = start + 1
        while i < chars.count {
            if chars[i] == "\\" && quote == "'" {
                i += 2
                continue
            }
            if chars[i] == quote {
                if i + 1 < chars.count && chars[i + 1] == quote {
                    i += 2
                    continue
                }
                return i + 1
            }
            i += 1
        }
        return chars.count
    }

    private static func scanLineComment(_ chars: [Character], from start: Int) -> Int {
        var i = start
        while i < chars.count && chars[i] != "\n" { i += 1 }
        return i
    }

    private static func scanBlockComment(_ chars: [Character], from start: Int) -> Int {
        var i = start + 2
        while i + 1 < chars.count {
            if chars[i] == "*" && chars[i + 1] == "/" { return i + 2 }
            i += 1
        }
        return chars.count
    }

    /// Recognizes `$$` or `$tag$` at `index`.
    private static func dollarTag(_ chars: [Character], at index: Int) -> String? {
        var i = index + 1
        while i < chars.count {
            let c = chars[i]
            if c == "$" { return String(chars[index...i]) }
            guard c.isLetter || c == "_" || (c.isNumber && i > index + 1) else { return nil }
            i += 1
        }
        return nil
    }

    private static func scanDollarQuoted(_ chars: [Character], from start: Int, tag: String) -> Int {
        let tagChars = Array(tag)
        var i = start + tagChars.count
        while i + tagChars.count <= chars.count {
            if Array(chars[i..<i + tagChars.count]) == tagChars { return i + tagChars.count }
            i += 1
        }
        return chars.count
    }

    private static func isOnlyComments(_ text: String) -> Bool {
        var stripped = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "-" && i + 1 < chars.count && chars[i + 1] == "-" {
                i = scanLineComment(chars, from: i)
            } else if chars[i] == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
                i = scanBlockComment(chars, from: i)
            } else {
                stripped.append(chars[i])
                i += 1
            }
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
