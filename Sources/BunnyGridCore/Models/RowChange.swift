import Foundation

/// A column name paired with a value, used for keys and assignments in row changes.
public struct ColumnValue: Hashable, Sendable {
    public var column: String
    public var value: CellValue

    public init(_ column: String, _ value: CellValue) {
        self.column = column
        self.value = value
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
