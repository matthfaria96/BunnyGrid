import Foundation

/// The SELECT a visual Query Builder edits (Navicat's Query Builder): tables with aliases, joins,
/// output columns, a WHERE tree, GROUP BY, HAVING, ORDER BY, LIMIT/OFFSET and DISTINCT.
/// `QueryBuilderSQL` turns it into SQL for one dialect and `QueryBuilderParser` reads simple SELECTs back.
public struct BuilderQuery: Hashable, Sendable {
    public var tables: [BuilderTable] = []
    public var joins: [BuilderJoin] = []
    public var columns: [BuilderColumn] = []
    public var distinct = false
    public var whereClause = BuilderGroup()
    public var groupBy: [BuilderOperand] = []
    public var having = BuilderGroup()
    public var orderBy: [BuilderOrder] = []
    public var limit: Int?
    public var offset: Int?

    public init() {}

    /// Adds a table (with a unique alias when it is already in the query) and returns its id.
    @discardableResult
    public mutating func addTable(name: String, schema: String? = nil, alias: String? = nil) -> Int {
        let id = (tables.map(\.id).max() ?? 0) + 1
        var alias = alias
        if alias == nil, tables.contains(where: { $0.reference.caseInsensitiveCompare(name) == .orderedSame }) {
            var n = 2
            while tables.contains(where: { $0.reference.caseInsensitiveCompare("\(name)\(n)") == .orderedSame }) { n += 1 }
            alias = "\(name)\(n)"
        }
        tables.append(BuilderTable(id: id, schema: schema, name: name, alias: alias))
        return id
    }

    /// Removes a table with its joins, columns and the conditions that use it.
    public mutating func removeTable(_ id: Int) {
        tables.removeAll { $0.id == id }
        joins.removeAll { $0.leftTable == id || $0.rightTable == id }
        columns.removeAll { $0.tableID == id }
        groupBy.removeAll { $0.tableID == id }
        orderBy.removeAll { $0.operand.tableID == id }
        whereClause.removeReferences(to: id)
        having.removeReferences(to: id)
    }

    public func table(_ id: Int?) -> BuilderTable? {
        tables.first { $0.id == id }
    }

    /// Whether `column` of table `id` is an output column (a plain, non-aggregated reference).
    public func isSelected(table id: Int, column: String) -> Bool {
        columns.contains { $0.tableID == id && $0.column == column && $0.aggregate == nil }
    }

    public mutating func setSelected(_ selected: Bool, table id: Int, column: String) {
        if selected {
            guard !isSelected(table: id, column: column) else { return }
            columns.append(BuilderColumn(tableID: id, column: column))
        } else {
            columns.removeAll { $0.tableID == id && $0.column == column && $0.aggregate == nil }
        }
    }

    /// Joins `table` to the tables before it along foreign keys between them (`keys` maps a table id to its keys).
    /// Returns how many joins were added.
    @discardableResult
    public mutating func addForeignKeyJoins(for id: Int, keys: [Int: [TableForeignKey]]) -> Int {
        guard let table = table(id) else { return 0 }
        var added = 0
        for other in tables where other.id != id {
            // table → other
            for key in keys[id] ?? [] where key.referencedTable.caseInsensitiveCompare(other.name) == .orderedSame {
                for (column, referenced) in zip(key.columns, key.referencedColumns) {
                    added += addJoin(BuilderJoin(kind: .inner, leftTable: other.id, leftColumn: referenced, rightTable: id, rightColumn: column)) ? 1 : 0
                }
            }
            // other → table
            for key in keys[other.id] ?? [] where key.referencedTable.caseInsensitiveCompare(table.name) == .orderedSame {
                for (column, referenced) in zip(key.columns, key.referencedColumns) {
                    added += addJoin(BuilderJoin(kind: .inner, leftTable: other.id, leftColumn: column, rightTable: id, rightColumn: referenced)) ? 1 : 0
                }
            }
        }
        return added
    }

    /// Adds a join unless the same column pair is already joined.
    @discardableResult
    public mutating func addJoin(_ join: BuilderJoin) -> Bool {
        guard join.leftTable != join.rightTable else { return false }
        let exists = joins.contains {
            ($0.leftTable == join.leftTable && $0.leftColumn == join.leftColumn && $0.rightTable == join.rightTable && $0.rightColumn == join.rightColumn)
                || ($0.leftTable == join.rightTable && $0.leftColumn == join.rightColumn && $0.rightTable == join.leftTable && $0.rightColumn == join.leftColumn)
        }
        guard !exists else { return false }
        joins.append(join)
        return true
    }
}

public struct BuilderTable: Hashable, Sendable, Identifiable {
    public var id: Int
    public var schema: String?
    public var name: String
    public var alias: String?

    public init(id: Int, schema: String? = nil, name: String, alias: String? = nil) {
        self.id = id
        self.schema = schema
        self.name = name
        self.alias = alias
    }

    /// The name columns are qualified with: the alias, otherwise the table name.
    public var reference: String {
        if let alias, !alias.isEmpty { return alias }
        return name
    }
}

public enum BuilderJoinKind: String, CaseIterable, Hashable, Sendable {
    case inner = "INNER JOIN"
    case left = "LEFT JOIN"
    case right = "RIGHT JOIN"
    case full = "FULL OUTER JOIN"

    /// The same join seen from the other table.
    public var mirrored: BuilderJoinKind {
        switch self {
        case .left: .right
        case .right: .left
        default: self
        }
    }

    public var title: String {
        switch self {
        case .inner: "Inner Join"
        case .left: "Left Join"
        case .right: "Right Join"
        case .full: "Full Outer Join"
        }
    }
}

/// `leftTable.leftColumn = rightTable.rightColumn`, joined with `kind` (LEFT keeps every row of the left table).
public struct BuilderJoin: Hashable, Sendable, Identifiable {
    public var id: String { "\(leftTable).\(leftColumn)=\(rightTable).\(rightColumn)" }
    public var kind: BuilderJoinKind
    public var leftTable: Int
    public var leftColumn: String
    public var rightTable: Int
    public var rightColumn: String

    public init(kind: BuilderJoinKind = .inner, leftTable: Int, leftColumn: String, rightTable: Int, rightColumn: String) {
        self.kind = kind
        self.leftTable = leftTable
        self.leftColumn = leftColumn
        self.rightTable = rightTable
        self.rightColumn = rightColumn
    }
}

public enum BuilderAggregate: String, CaseIterable, Hashable, Sendable {
    case count = "COUNT"
    case countDistinct = "COUNT DISTINCT"
    case sum = "SUM"
    case avg = "AVG"
    case min = "MIN"
    case max = "MAX"
}

/// One output column: `table.column`, `table.*`, `*`, optionally aggregated and aliased.
public struct BuilderColumn: Hashable, Sendable, Identifiable {
    public var id: String { "\(tableID ?? 0).\(column).\(aggregate?.rawValue ?? "").\(alias ?? "")" }
    public var tableID: Int?
    /// A column name or `*`.
    public var column: String
    public var aggregate: BuilderAggregate?
    public var alias: String?

    public init(tableID: Int?, column: String, aggregate: BuilderAggregate? = nil, alias: String? = nil) {
        self.tableID = tableID
        self.column = column
        self.aggregate = aggregate
        self.alias = alias
    }

    public var operand: BuilderOperand {
        aggregate.map { .aggregate($0, tableID: tableID, column: column) } ?? .column(tableID: tableID, name: column)
    }
}

/// A value in a condition, GROUP BY or ORDER BY.
public enum BuilderOperand: Hashable, Sendable {
    case column(tableID: Int?, name: String)
    case aggregate(BuilderAggregate, tableID: Int?, column: String)
    /// A string literal (quoted on output).
    case text(String)
    /// A number, written as is.
    case number(String)
    /// A placeholder written as typed: `:name`, `?`, `$1`, `@name`.
    case parameter(String)
    case null

    public var tableID: Int? {
        switch self {
        case .column(let id, _), .aggregate(_, let id, _): id
        default: nil
        }
    }

    /// Reads what the user typed into a value field: a number, a placeholder, NULL, or text.
    public static func value(_ typed: String) -> BuilderOperand {
        let text = typed.trimmingCharacters(in: .whitespaces)
        if text.uppercased() == "NULL" { return .null }
        if Double(text) != nil, !text.isEmpty, text.first != "+" { return .number(text) }
        if text == "?" || (text.count > 1 && [":", "$", "@"].contains(text.first!) && text.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }) {
            return .parameter(text)
        }
        if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") {
            return .text(String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'"))
        }
        return .text(typed)
    }
}

public enum BuilderOperator: String, CaseIterable, Hashable, Sendable {
    case equal = "="
    case notEqual = "<>"
    case less = "<"
    case lessOrEqual = "<="
    case greater = ">"
    case greaterOrEqual = ">="
    case like = "LIKE"
    case notLike = "NOT LIKE"
    case isIn = "IN"
    case notIn = "NOT IN"
    case between = "BETWEEN"
    case notBetween = "NOT BETWEEN"
    case isNull = "IS NULL"
    case isNotNull = "IS NOT NULL"

    /// How many right-hand values the operator takes (nil: a list of one or more).
    public var valueCount: Int? {
        switch self {
        case .isNull, .isNotNull: 0
        case .between, .notBetween: 2
        case .isIn, .notIn: nil
        default: 1
        }
    }
}

public struct BuilderPredicate: Hashable, Sendable {
    public var left: BuilderOperand
    public var op: BuilderOperator
    public var values: [BuilderOperand]

    public init(left: BuilderOperand, op: BuilderOperator = .equal, values: [BuilderOperand] = [.text("")]) {
        self.left = left
        self.op = op
        self.values = values
    }
}

public enum BuilderConjunction: String, Hashable, Sendable {
    case and = "AND"
    case or = "OR"
}

public indirect enum BuilderCondition: Hashable, Sendable {
    case predicate(BuilderPredicate)
    case group(BuilderGroup)
}

/// Conditions joined with AND or OR; `negated` wraps the group in NOT (…).
public struct BuilderGroup: Hashable, Sendable {
    public var conjunction: BuilderConjunction
    public var negated: Bool
    public var items: [BuilderCondition]

    public init(conjunction: BuilderConjunction = .and, negated: Bool = false, items: [BuilderCondition] = []) {
        self.conjunction = conjunction
        self.negated = negated
        self.items = items
    }

    public var isEmpty: Bool { items.isEmpty }

    mutating func removeReferences(to table: Int) {
        items = items.compactMap { item in
            switch item {
            case .predicate(let p):
                return p.left.tableID == table || p.values.contains { $0.tableID == table } ? nil : item
            case .group(var g):
                g.removeReferences(to: table)
                return g.isEmpty ? nil : .group(g)
            }
        }
    }
}

public struct BuilderOrder: Hashable, Sendable {
    public var operand: BuilderOperand
    public var descending: Bool

    public init(_ operand: BuilderOperand, descending: Bool = false) {
        self.operand = operand
        self.descending = descending
    }
}
