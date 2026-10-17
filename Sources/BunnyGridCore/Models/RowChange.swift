import Foundation

/// A column name paired with a value, used for keys and assignments in row changes.
public struct ColumnValue: Hashable, Sendable {
    public var column: String
    public var value: CellValue
    /// Assign the column's DEFAULT instead of `value` (UPDATE … SET col = DEFAULT; left out of INSERTs).
    public var useDefault: Bool

    public init(_ column: String, _ value: CellValue, useDefault: Bool = false) {
        self.column = column
        self.value = value
        self.useDefault = useDefault
    }

    /// The column set back to its DEFAULT.
    public static func defaultValue(_ column: String) -> ColumnValue {
        ColumnValue(column, .null, useDefault: true)
    }
}

/// One pending edit from the data grid. Rows are identified by their primary-key values
/// as they were when loaded, like Beekeeper's `TableChanges`.
public enum RowChange: Hashable, Sendable {
    case update(key: [ColumnValue], values: [ColumnValue])
    case insert(values: [ColumnValue])
    case delete(key: [ColumnValue])

    /// Whether the statement must touch exactly one row to be considered successful.
    var targetsSingleRow: Bool {
        if case .insert = self { false } else { true }
    }
}
