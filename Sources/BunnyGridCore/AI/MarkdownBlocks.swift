import Foundation

/// Block-level Markdown, enough for assistant replies: headings, paragraphs, lists, quotes,
/// tables, rules and fenced code. Inline styles stay as Markdown inside each block's text.
public enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// `ordinal` is nil for bullets; `depth` counts indentation levels.
    case listItem(ordinal: Int?, depth: Int, text: String)
    case quote(String)
    case code(language: String, body: String, isClosed: Bool)
    case table(header: [String], rows: [[String]])
    case rule
}

public enum MarkdownParser {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
            quote = []
        }
        func flush() { flushParagraph(); flushQuote() }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code: everything up to the closing fence (or the end, while streaming).
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                var closed = false
                index += 1
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { closed = true; break }
                    body.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language, body: body.joined(separator: "\n"), isClosed: closed))
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flush()
                index += 1
                continue
            }

            if let heading = headingLevel(trimmed) {
                flush()
                blocks.append(.heading(level: heading, text: trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            }

            if isRule(trimmed) {
                flush()
                blocks.append(.rule)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var content = trimmed.dropFirst()
                if content.hasPrefix(" ") { content = content.dropFirst() }
                quote.append(String(content))
                index += 1
                continue
            }
            flushQuote()

            // Table: a pipe row followed by a delimiter row.
            if trimmed.contains("|"), index + 1 < lines.count, isTableDelimiter(lines[index + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard row.contains("|"), !row.isEmpty else { break }
                    var values = cells(row)
                    if values.count < header.count { values += Array(repeating: "", count: header.count - values.count) }
                    rows.append(Array(values.prefix(header.count)))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if let item = listItem(line) {
                flushParagraph()
                blocks.append(item)
                index += 1
                continue
            }

            // A continuation line of the previous list item.
            if paragraph.isEmpty, line.hasPrefix("  "), case .listItem(let ordinal, let depth, let text)? = blocks.last {
                blocks[blocks.count - 1] = .listItem(ordinal: ordinal, depth: depth, text: text + " " + trimmed)
                index += 1
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flush()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix(":") || trimmed.hasPrefix("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ row: String) -> [String] {
        var row = row
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop { $0 == " " || $0 == "\t" }
        let depth = indent / 2
        for bullet in ["- ", "* ", "+ ", "• "] where rest.hasPrefix(bullet) {
            return .listItem(ordinal: nil, depth: depth, text: String(rest.dropFirst(bullet.count)))
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                return .listItem(ordinal: Int(digits), depth: depth, text: String(after.dropFirst(2)))
            }
        }
        return nil
    }

    /// The bodies of the reply's code blocks whose language looks like SQL (or is unspecified).
    public static func sqlBlocks(in text: String) -> [String] {
        parse(text).compactMap { block in
            if case .code(let language, let body, _) = block, isSQL(language) { return body }
            return nil
        }
    }

    public static func isSQL(_ language: String) -> Bool {
        ["", "sql", "postgresql", "postgres", "pgsql", "plpgsql", "mysql", "mariadb", "sqlite", "tsql", "plsql"].contains(language.lowercased())
    }
}
