import Foundation

/// A value bound to a statement placeholder, typed for the driver.
/// Built from the grid's `CellValue` and the column's declared type, so `"42"` typed into an
/// integer column is sent as an integer and a blob as raw bytes, never as a quoted literal.
public enum SQLParameter: Hashable, Sendable {
    case null
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case text(String)
    case blob(Data)
    /// Text in the canonical form of a temporal or uuid type (`2026-10-17`, `2026-10-17 09:30:00`);
    /// drivers declare the type so the server parses it exactly.
    case typed(String, ColumnTypeCategory)
    /// Text of a type the app doesn't model (numeric, arrays, enums, geometry…): the server converts it,
    /// the same as a quoted literal would be.
    case untyped(String)

    /// The parameter for `value` stored in a column of `category`.
    /// Text that doesn't parse as the column's type is sent untyped, so the server reports the error.
    public init(_ value: CellValue, category: ColumnTypeCategory) {
        switch value {
        case .null: self = .null
        // A number shown in a text column (SQLite stores what it's given) is compared and stored as text.
        case .integer(let v): self = category == .boolean ? .bool(v != 0) : category == .text ? .text(String(v)) : .integer(v)
        case .double(let v): self = category == .text ? .text(String(v)) : .double(v)
        case .bool(let v): self = .bool(v)
        case .blob(let data): self = .blob(data)
        case .text(let text): self = Self.fromText(text, category: category)
        }
    }

    private static func fromText(_ text: String, category: ColumnTypeCategory) -> SQLParameter {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch category {
        case .integer:
            if let value = Int64(trimmed) { return .integer(value) }
        case .real:
            if let value = Double(trimmed), value.isFinite { return .double(value) }
        case .boolean:
            switch trimmed.lowercased() {
            case "1", "t", "true", "y", "yes", "on": return .bool(true)
            case "0", "f", "false", "n", "no", "off": return .bool(false)
            default: break
            }
        case .text, .json:
            return .text(text)
        case .binary:
            return .blob(HexFormatter.parse(trimmed) ?? Data(text.utf8))
        case .date, .time, .timeWithTimeZone, .dateTime, .dateTimeWithTimeZone, .uuid:
            if !trimmed.isEmpty { return .typed(trimmed, category) }
        case .decimal, .other:
            break
        }
        return .untyped(text)
    }
}

/// SQL with placeholders and the values bound to them, in order.
public struct BoundStatement: Hashable, Sendable {
    public var sql: String
    public var parameters: [SQLParameter]

    public init(sql: String, parameters: [SQLParameter]) {
        self.sql = sql
        self.parameters = parameters
    }
}

extension SQLDialect {
    /// The placeholder for the `index`-th parameter (1-based): `$1` on PostgreSQL, `?` elsewhere.
    public func placeholder(_ index: Int) -> String {
        switch kind {
        case .postgresql: "$\(index)"
        case .sqlserver: "@p\(index)"
        default: "?"
        }
    }

    /// The statement that applies one grid change, with every value bound as a typed parameter.
    /// `columns` gives each column's declared type (and, for SQLite, the default expression that
    /// `SET col = DEFAULT` falls back to); unknown columns are bound untyped.
    public func boundStatement(for change: RowChange, table: String, schema: String?, columns: [TableColumn] = []) -> BoundStatement {
        let target = qualifiedName(table: table, schema: schema)
        let byName = Dictionary(columns.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var parameters: [SQLParameter] = []
        func bind(_ part: ColumnValue) -> String {
            // A typeless NULL: an nvarchar NULL parameter couldn't be converted to varbinary and other types.
            if kind == .sqlserver, part.value.isNull { return "NULL" }
            parameters.append(SQLParameter(part.value, category: ColumnTypeCategory.classify(byName[part.column]?.dataType, kind: kind)))
            return placeholder(parameters.count)
        }
        func whereClause(_ key: [ColumnValue]) -> String {
            key.map { part in
                part.value.isNull ? "\(quoteIdentifier(part.column)) IS NULL" : "\(quoteIdentifier(part.column)) = \(bind(part))"
            }
            .joined(separator: " AND ")
        }

        switch change {
        case .update(let key, let values):
            let assignments = values.map { part in
                "\(quoteIdentifier(part.column)) = \(part.useDefault ? defaultKeyword(for: byName[part.column]) : bind(part))"
            }
            let sql = "UPDATE \(target) SET \(assignments.joined(separator: ", ")) WHERE \(whereClause(key))"
            return BoundStatement(sql: sql, parameters: parameters)
        case .insert(let values):
            let explicit = values.filter { !$0.useDefault }
            guard !explicit.isEmpty else { return BoundStatement(sql: sql(for: .insert(values: []), table: table, schema: schema), parameters: []) }
            let names = explicit.map { quoteIdentifier($0.column) }.joined(separator: ", ")
            let placeholders = explicit.map(bind).joined(separator: ", ")
            return BoundStatement(sql: "INSERT INTO \(target) (\(names)) VALUES (\(placeholders))", parameters: parameters)
        case .delete(let key):
            let sql = "DELETE FROM \(target) WHERE \(whereClause(key))"
            return BoundStatement(sql: sql, parameters: parameters)
        }
    }

    /// `DEFAULT` for an UPDATE's SET list. SQLite has no DEFAULT there, so it gets the column's
    /// default expression (or NULL when the column has none).
    func defaultKeyword(for column: TableColumn?) -> String {
        guard kind == .sqlite else { return "DEFAULT" }
        guard let expression = column?.defaultValue?.trimmingCharacters(in: .whitespaces), !expression.isEmpty else { return "NULL" }
        return "(\(expression))"
    }

    /// Renders a bound parameter as a literal, for drivers without native binding and for logs.
    public func literal(_ parameter: SQLParameter) -> String {
        switch parameter {
        case .null: literal(CellValue.null)
        case .integer(let v): literal(CellValue.integer(v))
        case .double(let v): literal(CellValue.double(v))
        case .bool(let v): literal(CellValue.bool(v))
        case .text(let v), .typed(let v, _), .untyped(let v): quoteLiteral(v)
        case .blob(let data): literal(CellValue.blob(data))
        }
    }
}
