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
