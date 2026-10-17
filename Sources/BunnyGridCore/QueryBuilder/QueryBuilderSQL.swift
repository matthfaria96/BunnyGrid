import Foundation

/// Writes a `BuilderQuery` as SQL for one engine: identifier quoting, string literals,
/// `TOP` / `LIMIT … OFFSET` / `OFFSET … FETCH`, laid out one clause per line like Navicat's builder.
public struct QueryBuilderSQL: Sendable {
    public let dialect: SQLDialect

    public init(kind: DatabaseKind) {
        dialect = SQLDialect(kind: kind)
    }

    private var kind: DatabaseKind { dialect.kind }
    private let indent = "  "

    public func sql(_ query: BuilderQuery) -> String {
        var lines: [String] = []
        var head = "SELECT"
        if query.distinct { head += " DISTINCT" }
        let useTop = kind == .sqlserver && query.offset == nil && query.limit != nil
        if useTop, let limit = query.limit { head += " TOP \(limit)" }
        lines.append(head)
        let columns = query.columns.isEmpty ? ["*"] : query.columns.map { column(query, $0) }
        lines.append(list(columns))

        if !query.tables.isEmpty {
            lines.append("FROM")
            lines.append(contentsOf: from(query).map { indent + $0 })
        }
        if !query.whereClause.isEmpty {
            lines.append("WHERE")
            lines.append(indent + condition(query, .group(query.whereClause), top: true))
        }
        if !query.groupBy.isEmpty {
            lines.append("GROUP BY")
            lines.append(list(query.groupBy.map { operand(query, $0) }))
        }
        if !query.having.isEmpty {
            lines.append("HAVING")
            lines.append(indent + condition(query, .group(query.having), top: true))
        }
        var orders = query.orderBy.map { operand(query, $0.operand) + ($0.descending ? " DESC" : "") }
        if kind == .sqlserver, query.offset != nil, orders.isEmpty {
            orders = ["(SELECT NULL)"] // OFFSET … FETCH needs an ORDER BY
        }
        if !orders.isEmpty {
            lines.append("ORDER BY")
            lines.append(list(orders))
        }
        lines.append(contentsOf: limitLines(query, useTop: useTop))
        return lines.joined(separator: "\n")
    }

    private func list(_ items: [String]) -> String {
        items.map { indent + $0 }.joined(separator: ",\n")
    }

    private func limitLines(_ query: BuilderQuery, useTop: Bool) -> [String] {
        switch (query.limit, query.offset) {
        case (nil, nil): return []
        case (let limit?, nil): return useTop ? [] : ["LIMIT \(limit)"]
        case (let limit, let offset?):
            switch kind {
            case .sqlserver:
                var lines = ["OFFSET \(offset) ROWS"]
                if let limit { lines.append("FETCH NEXT \(limit) ROWS ONLY") }
                return lines
            case .postgresql:
                return (limit.map { ["LIMIT \($0)"] } ?? []) + ["OFFSET \(offset)"]
            case .mysql, .mariadb:
                return ["LIMIT \(limit.map(String.init) ?? "18446744073709551615") OFFSET \(offset)"]
            default:
                return ["LIMIT \(limit ?? -1) OFFSET \(offset)"]
            }
        }
    }

    private func from(_ query: BuilderQuery) -> [String] {
        var placed: [Int] = []
        var used = Set<String>()
        var lines: [String] = []
        var remaining = query.tables
        while !remaining.isEmpty {
            // The next table joined to one already placed, otherwise the next in order.
            let index = placed.isEmpty ? 0 : remaining.firstIndex { table in
                query.joins.contains { ($0.leftTable == table.id && placed.contains($0.rightTable)) || ($0.rightTable == table.id && placed.contains($0.leftTable)) }
            } ?? 0
            let table = remaining.remove(at: index)
            let source = tableSource(table)
            defer { placed.append(table.id) }
            guard !placed.isEmpty else {
                lines.append(source)
                continue
            }
            let links = query.joins.filter { join in
                !used.contains(join.id) && ((join.leftTable == table.id && placed.contains(join.rightTable)) || (join.rightTable == table.id && placed.contains(join.leftTable)))
            }
            guard let first = links.first else {
                lines.append("CROSS JOIN " + source)
                continue
            }
            links.forEach { used.insert($0.id) }
            let joinKind = first.rightTable == table.id ? first.kind : first.kind.mirrored
            let on = links.map { join -> String in
                // Placed table first, as written by hand.
                let (a, ac, b, bc) = join.rightTable == table.id
                    ? (join.leftTable, join.leftColumn, join.rightTable, join.rightColumn)
                    : (join.rightTable, join.rightColumn, join.leftTable, join.leftColumn)
                return operand(query, .column(tableID: a, name: ac), qualify: true) + " = " + operand(query, .column(tableID: b, name: bc), qualify: true)
            }
            lines.append("\(joinKind.rawValue) \(source) ON \(on.joined(separator: " AND "))")
        }
        return lines
    }

    private func tableSource(_ table: BuilderTable) -> String {
        var source = table.schema.map { identifier($0) + "." } ?? ""
        source += identifier(table.name)
        if let alias = table.alias, !alias.isEmpty {
            source += " AS " + identifier(alias)
        }
        return source
    }

    private func column(_ query: BuilderQuery, _ column: BuilderColumn) -> String {
        var text = operand(query, column.operand)
        if let alias = column.alias, !alias.isEmpty { text += " AS " + identifier(alias) }
        return text
    }

    func operand(_ query: BuilderQuery, _ operand: BuilderOperand, qualify: Bool? = nil) -> String {
        switch operand {
        case .column(let id, let name):
            return columnReference(query, tableID: id, name: name, qualify: qualify)
        case .aggregate(let function, let id, let column):
            let inner = columnReference(query, tableID: id, name: column, qualify: qualify)
            return function == .countDistinct ? "COUNT(DISTINCT \(inner))" : "\(function.rawValue)(\(inner))"
        case .text(let value): return dialect.quoteLiteral(value)
        case .number(let value), .parameter(let value): return value
        case .null: return "NULL"
        }
    }

    private func columnReference(_ query: BuilderQuery, tableID: Int?, name: String, qualify: Bool?) -> String {
        let column = name == "*" ? "*" : identifier(name)
        guard let table = query.table(tableID), qualify ?? (query.tables.count > 1) else { return column }
        return identifier(table.reference) + "." + column
    }

    private func condition(_ query: BuilderQuery, _ condition: BuilderCondition, top: Bool = false) -> String {
        switch condition {
        case .predicate(let p): return predicate(query, p)
        case .group(let group):
            let inner = group.items.map { item -> String in
                if case .group(let child) = item, child.items.count == 1, !child.negated {
                    return self.condition(query, child.items[0])
                }
                return self.condition(query, item)
            }
            .joined(separator: " \(group.conjunction.rawValue) ")
            if group.negated { return "NOT (\(inner))" }
            return top || group.items.count < 2 ? inner : "(\(inner))"
        }
    }

    private func predicate(_ query: BuilderQuery, _ p: BuilderPredicate) -> String {
        let left = operand(query, p.left)
        let values = p.values.map { operand(query, $0) }
        switch p.op {
        case .isNull, .isNotNull:
            return "\(left) \(p.op.rawValue)"
        case .between, .notBetween:
            return "\(left) \(p.op.rawValue) \(values.first ?? "NULL") AND \(values.dropFirst().first ?? "NULL")"
        case .isIn, .notIn:
            return "\(left) \(p.op.rawValue) (\(values.isEmpty ? "NULL" : values.joined(separator: ", ")))"
        default:
            return "\(left) \(p.op.rawValue) \(values.first ?? "NULL")"
        }
    }

    /// Quotes a name only when it needs it (not a plain identifier, a keyword, or upper case on PostgreSQL).
    public func identifier(_ name: String) -> String {
        let plain = name.first.map { $0.isLetter || $0 == "_" } == true
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            && !QueryBuilderSQL.reserved.contains(name.uppercased())
            && !(kind == .postgresql && name != name.lowercased())
        return plain ? name : dialect.quoteIdentifier(name)
    }

    static let reserved: Set<String> = [
        "ALL", "AND", "ANY", "AS", "ASC", "BETWEEN", "BY", "CASE", "CHECK", "COLUMN", "CONSTRAINT", "CREATE", "CROSS",
        "CURRENT", "DEFAULT", "DELETE", "DESC", "DISTINCT", "DROP", "ELSE", "END", "EXISTS", "FETCH", "FOR", "FOREIGN",
        "FROM", "FULL", "GROUP", "HAVING", "IN", "INDEX", "INNER", "INSERT", "INTO", "IS", "JOIN", "KEY", "LEFT", "LIKE",
        "LIMIT", "NOT", "NULL", "OFFSET", "ON", "OR", "ORDER", "OUTER", "PRIMARY", "REFERENCES", "RIGHT", "ROWS", "SELECT",
        "SET", "TABLE", "THEN", "TO", "TOP", "UNION", "UNIQUE", "UPDATE", "USER", "USING", "VALUES", "WHEN", "WHERE", "WITH",
    ]
}
