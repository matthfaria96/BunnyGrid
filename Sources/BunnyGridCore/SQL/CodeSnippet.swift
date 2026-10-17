import Foundation

/// A reusable piece of SQL for the query editor's Code Snippet pane.
public struct CodeSnippet: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Grouping shown after the name ("DML", "DDL", "Comment"…); the label filter lists these.
    public var label: String
    public var detail: String
    public var code: String
    /// Built-in snippets can't be edited or deleted.
    public var isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, label: String, detail: String, code: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.label = label
        self.detail = detail
        self.code = code
        self.isBuiltIn = isBuiltIn
    }

    /// Stable ids so built-ins keep their identity across launches.
    private static func builtIn(_ index: Int, _ name: String, _ label: String, _ detail: String, _ code: String) -> CodeSnippet {
        CodeSnippet(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!, name: name, label: label, detail: detail, code: code, isBuiltIn: true)
    }

    public static let builtIns: [CodeSnippet] = [
        builtIn(1, "COMMENTS", "Comment", "Create a comment", "/* comment */"),
        builtIn(2, "SELECT Syntax", "DML", "Retrieve rows selected from one or more tables", "SELECT column1, column2\nFROM table_name\nWHERE condition\nORDER BY column1;"),
        builtIn(3, "INSERT Syntax", "DML", "Insert new rows into an existing table", "INSERT INTO table_name (column1, column2)\nVALUES (value1, value2);"),
        builtIn(4, "UPDATE Syntax", "DML", "Updates columns of existing rows in the named table with new values", "UPDATE table_name\nSET column1 = value1\nWHERE condition;"),
        builtIn(5, "DELETE Syntax", "DML", "Delete rows that match a condition", "DELETE FROM table_name\nWHERE condition;"),
        builtIn(6, "JOIN Syntax", "DML", "Combine rows from two tables on a related column", "SELECT a.column1, b.column2\nFROM table_a AS a\nJOIN table_b AS b ON b.a_id = a.id;"),
        builtIn(7, "CTE (WITH)", "DML", "Name a subquery and reuse it in the main query", "WITH recent AS (\n  SELECT *\n  FROM table_name\n  WHERE created_at > CURRENT_DATE - 7\n)\nSELECT *\nFROM recent;"),
        builtIn(8, "CASE Expression", "DML", "Return a value depending on conditions", "CASE\n  WHEN condition THEN result\n  ELSE other_result\nEND"),
        builtIn(9, "CREATE TABLE Syntax", "DDL", "Create a new table", "CREATE TABLE table_name (\n  id INTEGER PRIMARY KEY,\n  name TEXT NOT NULL\n);"),
        builtIn(10, "CREATE INDEX Syntax", "DDL", "Create an index on one or more columns", "CREATE INDEX index_name ON table_name (column1);"),
        builtIn(11, "ALTER TABLE Syntax", "DDL", "Add a column to an existing table", "ALTER TABLE table_name ADD COLUMN column_name TEXT;"),
    ]
}
