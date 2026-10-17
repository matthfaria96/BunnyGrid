import Foundation

/// Kinds of objects shown in the object browser.
public enum DatabaseObjectKind: String, Codable, Sendable, CaseIterable {
    case table
    case view
    case materializedView
    case routine

    public var displayName: String {
        switch self {
        case .table: "Tables"
        case .view: "Views"
        case .materializedView: "Materialized Views"
        case .routine: "Functions"
        }
    }
}

/// A table, view or routine inside a schema (or database, for engines without schemas).
public struct DatabaseObject: Hashable, Identifiable, Sendable {
    public var schema: String?
    public var name: String
    public var kind: DatabaseObjectKind

    public init(schema: String?, name: String, kind: DatabaseObjectKind) {
        self.schema = schema
        self.name = name
        self.kind = kind
    }

    public var id: String { "\(kind.rawValue):\(schema ?? ""):\(name)" }

    public var qualifiedName: String {
        if let schema, !schema.isEmpty { return "\(schema).\(name)" }
        return name
    }
}

public struct TableColumn: Hashable, Identifiable, Sendable {
    public var name: String
    public var dataType: String
    public var nullable: Bool
    public var defaultValue: String?
    public var isPrimaryKey: Bool
    public var ordinal: Int

    public init(name: String, dataType: String, nullable: Bool, defaultValue: String? = nil, isPrimaryKey: Bool = false, ordinal: Int) {
        self.name = name
        self.dataType = dataType
        self.nullable = nullable
        self.defaultValue = defaultValue
        self.isPrimaryKey = isPrimaryKey
        self.ordinal = ordinal
    }

    public var id: String { name }
}

public struct TableIndex: Hashable, Identifiable, Sendable {
    public var name: String
    public var columns: [String]
    public var unique: Bool
    public var primary: Bool

    public init(name: String, columns: [String], unique: Bool, primary: Bool) {
        self.name = name
        self.columns = columns
        self.unique = unique
        self.primary = primary
    }

    public var id: String { name }
}

public enum SortDirection: String, Sendable {
    case ascending = "ASC"
    case descending = "DESC"
}

public struct OrderBy: Hashable, Sendable {
    public var column: String
    public var direction: SortDirection

    public init(column: String, direction: SortDirection) {
        self.column = column
        self.direction = direction
    }
}

/// A single cell value, decoded into a small set of display-friendly cases.
public enum CellValue: Hashable, Sendable {
    case null
    case integer(Int64)
    case double(Double)
    case text(String)
    case bool(Bool)
    case blob(Data)

    public var displayString: String {
        switch self {
        case .null: "NULL"
        case .integer(let v): String(v)
        case .double(let v): String(v)
        case .text(let v): v
        case .bool(let v): v ? "true" : "false"
        case .blob(let d): "<\(d.count) bytes>"
        }
    }

    public var isNull: Bool { self == .null }
}

/// Result of one executed statement.
public struct QueryResult: Identifiable, Sendable {
    public let id = UUID()
    public var statement: String
    public var columns: [String]
    public var rows: [[CellValue]]
    /// Rows changed by a DML statement, when the driver reports it.
    public var affectedRows: Int?
    public var duration: Duration
    /// More rows exist than were read (the statement ran with a row cap).
    public var isTruncated: Bool

    public init(statement: String, columns: [String], rows: [[CellValue]], affectedRows: Int? = nil, duration: Duration = .zero, isTruncated: Bool = false) {
        self.statement = statement
        self.columns = columns
        self.rows = rows
        self.affectedRows = affectedRows
        self.duration = duration
        self.isTruncated = isTruncated
    }

    public var isResultSet: Bool { !columns.isEmpty }

    /// `result` with at most `maxRows` rows, marked truncated when rows were dropped.
    public static func capped(_ result: QueryResult, maxRows: Int?) -> QueryResult {
        guard let maxRows, result.rows.count > max(maxRows, 0) else { return result }
        var capped = result
        capped.rows.removeSubrange(max(maxRows, 0)...)
        capped.isTruncated = true
        return capped
    }
}

/// A page of rows from a table, as shown in the data grid.
public struct TablePage: Sendable {
    public var columns: [String]
    public var rows: [[CellValue]]
    public var offset: Int
    public var limit: Int

    public init(columns: [String], rows: [[CellValue]], offset: Int, limit: Int) {
        self.columns = columns
        self.rows = rows
        self.offset = offset
        self.limit = limit
    }

    public var hasMore: Bool { rows.count == limit }
}
