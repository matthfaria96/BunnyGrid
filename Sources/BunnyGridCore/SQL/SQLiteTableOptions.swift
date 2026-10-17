import Foundation

/// Navicat's SQLite table Options: Primary Key ON CONFLICT, AUTOINCREMENT and WITHOUT ROWID.
public struct SQLiteTableOptions: Equatable, Sendable {
    public static let conflictResolutions = ["ROLLBACK", "ABORT", "FAIL", "IGNORE", "REPLACE"]

    public var withoutRowID = false
    /// AUTOINCREMENT on a single INTEGER primary key.
    public var autoincrement = false
    /// One of `conflictResolutions`, or nil for SQLite's default (ABORT).
    public var primaryKeyOnConflict: String?

    public init(withoutRowID: Bool = false, autoincrement: Bool = false, primaryKeyOnConflict: String? = nil) {
        self.withoutRowID = withoutRowID
        self.autoincrement = autoincrement
        self.primaryKeyOnConflict = primaryKeyOnConflict
    }

    /// Reads the options from a stored CREATE TABLE (quoted names and literals are ignored).
    public init(sql: String) {
        let bare = Self.blankQuoted(sql).uppercased()
        withoutRowID = bare.contains(/\bWITHOUT\s+ROWID\b/)
        autoincrement = bare.contains(/\bAUTOINCREMENT\b/)
        if let match = bare.firstMatch(of: Self.primaryKeyConflict) {
            primaryKeyOnConflict = String(match.output.1)
        }
    }

    /// `PRIMARY KEY [ (cols) ] [ASC|DESC] ON CONFLICT x`, in a column or as a table constraint.
    nonisolated(unsafe) static let primaryKeyConflict = /PRIMARY\s+KEY\s*(?:\([^)]*\))?\s*(?:ASC|DESC)?\s*ON\s+CONFLICT\s+(ROLLBACK|ABORT|FAIL|IGNORE|REPLACE)/

    /// The SQL with the primary key's ON CONFLICT removed, so other ON CONFLICT clauses can still be detected.
    static func removingPrimaryKeyConflict(_ sql: String) -> String {
        sql.replacing(/(?i)(PRIMARY\s+KEY\s*(?:\([^)]*\))?\s*(?:ASC|DESC)?)\s*ON\s+CONFLICT\s+\w+/) { $0.output.1 }
    }

    /// `UNIQUE ("a", "b") ON CONFLICT x` for a unique written as a table constraint.
    static func uniqueConstraint(_ index: IndexDesign, dialect d: SQLDialect) -> String {
        "UNIQUE (\(index.columns.map(d.quoteIdentifier).joined(separator: ", ")))" + (index.onConflict.map { " ON CONFLICT \($0)" } ?? "")
    }

    /// Sets `onConflict` on the uniques that `sql` (the stored CREATE TABLE) declares with ON CONFLICT.
    public static func applyingUniqueConflicts(from sql: String?, to indexes: [IndexDesign]) -> [IndexDesign] {
        guard let sql else { return indexes }
        let conflicts = uniqueConflicts(in: sql)
        guard !conflicts.isEmpty else { return indexes }
        return indexes.map { index in
            var index = index
            if index.unique, index.name.hasPrefix("sqlite_autoindex_") { index.onConflict = conflicts[index.columns.map { $0.lowercased() }] }
            return index
        }
    }

    /// The SQL with the ON CONFLICT of UNIQUE constraints removed (the designer models those on the Uniques tab).
    static func removingUniqueConflict(_ sql: String) -> String {
        sql.replacing(/(?i)(\bUNIQUE\s*(?:\([^)]*\))?)\s*ON\s+CONFLICT\s+\w+/) { $0.output.1 }
    }

    /// UNIQUE constraints with an ON CONFLICT clause in a stored CREATE TABLE, by their lowercased field list:
    /// table constraints (`UNIQUE (a, b) ON CONFLICT REPLACE`) and column ones (`email TEXT UNIQUE ON CONFLICT IGNORE`).
    public static func uniqueConflicts(in sql: String) -> [[String]: String] {
        var result: [[String]: String] = [:]
        for definition in columnDefinitions(in: sql) {
            let bare = blankQuoted(definition).uppercased()
            if let table = definition.firstMatch(of: /(?is)^\s*(?:CONSTRAINT\s+(?:"(?:[^"]|"")*"|`[^`]*`|\[[^\]]*\]|\S+)\s+)?UNIQUE\s*\((.*)\)\s*ON\s+CONFLICT\s+(\w+)/) {
                let columns = splitTopLevel(String(table.output.1)).map { identifierName($0).lowercased() }
                result[columns] = String(table.output.2).uppercased()
            } else if !bare.hasPrefix("CONSTRAINT"), !bare.hasPrefix("PRIMARY"), !bare.hasPrefix("FOREIGN"), !bare.hasPrefix("CHECK"),
                      let column = bare.firstMatch(of: /\bUNIQUE\s+ON\s+CONFLICT\s+(ROLLBACK|ABORT|FAIL|IGNORE|REPLACE)\b/) {
                result[[identifierName(definition).lowercased()]] = String(column.output.1)
            }
        }
        return result
    }

    /// The comma-separated definitions between the outer parentheses of a CREATE TABLE.
    static func columnDefinitions(in sql: String) -> [String] {
        guard let open = sql.firstIndex(of: "("), let close = sql.lastIndex(of: ")"), open < close else { return [] }
        return splitTopLevel(String(sql[sql.index(after: open)..<close]))
    }

    /// Splits on commas outside parentheses, quotes and brackets.
    static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = [], current = "", depth = 0
        var quote: Character?
        for ch in text {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
                continue
            }
            switch ch {
            case "'", "\"", "`": quote = ch; current.append(ch)
            case "[": quote = "]"; current.append(ch)
            case "(": depth += 1; current.append(ch)
            case ")": depth -= 1; current.append(ch)
            case "," where depth == 0: parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines)); current = ""
            default: current.append(ch)
            }
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    /// The first name of a definition, unquoted: `"my col" TEXT` → `my col`.
    static func identifierName(_ definition: String) -> String {
        let text = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first else { return "" }
        let closing: Character? = switch first {
        case "\"": "\""
        case "`": "`"
        case "[": "]"
        default: nil
        }
        guard let closing else { return String(text.prefix { !$0.isWhitespace && $0 != "(" }) }
        var name = "", index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let ch = text[index]
            let next = text.index(after: index)
            if ch == closing {
                if closing != "]", next < text.endIndex, text[next] == closing { name.append(ch); index = text.index(after: next); continue }
                break
            }
            name.append(ch)
            index = next
        }
        return name
    }

    static func blankQuoted(_ sql: String) -> String {
        sql.replacing(/'(?:[^']|'')*'|"(?:[^"]|"")*"|`(?:[^`]|``)*`|\[[^\]]*\]/, with: "''")
    }

    var conflictClause: String {
        primaryKeyOnConflict.map { " ON CONFLICT \($0)" } ?? ""
    }

    /// SQLite rejects a WITHOUT ROWID table without a primary key.
    func validate(_ columns: [ColumnDesign]) throws {
        if withoutRowID && !columns.contains(where: \.isPrimaryKey) {
            throw TableDesignError.invalid("A WITHOUT ROWID table needs a primary key.")
        }
    }

    /// Whether AUTOINCREMENT can apply: SQLite allows it only on one INTEGER PRIMARY KEY of a rowid table.
    public func autoincrementApplies(to keys: [ColumnDesign]) -> Bool {
        autoincrement && !withoutRowID && keys.count == 1
            && keys[0].type.trimmingCharacters(in: .whitespaces).uppercased() == "INTEGER"
    }

    /// The column lines and constraint lines for the key, plus the text after the closing parenthesis.
    func tableParts(columns: [ColumnDesign], dialect d: SQLDialect) -> (columns: [String], primaryKey: String?, suffix: String) {
        let keys = columns.filter(\.isPrimaryKey)
        let inline = autoincrementApplies(to: keys)
        let lines = columns.map { column in
            inline && column.isPrimaryKey
                ? "  " + d.columnDefinition(column).replacingOccurrences(of: " NOT NULL", with: "") + " PRIMARY KEY\(conflictClause) AUTOINCREMENT"
                : "  " + d.columnDefinition(column)
        }
        let key = !keys.isEmpty && !inline
            ? "  PRIMARY KEY (\(keys.map { d.quoteIdentifier($0.name) }.joined(separator: ", ")))\(conflictClause)"
            : nil
        return (lines, key, withoutRowID ? " WITHOUT ROWID" : "")
    }
}
