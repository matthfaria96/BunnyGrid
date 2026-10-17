import Foundation

/// Per-engine SQL generation: identifier quoting and the queries the data grid needs.
public struct SQLDialect: Sendable {
    public let kind: DatabaseKind

    public init(kind: DatabaseKind) {
        self.kind = kind
    }

    public func quoteIdentifier(_ name: String) -> String {
        switch kind {
        case .mysql, .mariadb:
            "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
        case .sqlserver:
            "[" + name.replacingOccurrences(of: "]", with: "]]") + "]"
        case .postgresql, .sqlite, .mongodb:
            "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }

    public func quoteLiteral(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "'", with: "''")
        if kind == .mysql || kind == .mariadb {
            escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        }
        // N'…' keeps characters outside the database's code page.
        return (kind == .sqlserver ? "N'" : "'") + escaped + "'"
    }

    public func qualifiedName(_ object: DatabaseObject) -> String {
        qualifiedName(table: object.name, schema: object.schema)
    }

    public func qualifiedName(table: String, schema: String?) -> String {
        guard let schema, !schema.isEmpty else { return quoteIdentifier(table) }
        return quoteIdentifier(schema) + "." + quoteIdentifier(table)
    }

    /// `SELECT * … LIMIT … OFFSET …` for one page of the data grid.
    /// `filter` is a raw WHERE clause typed by the user, as in Beekeeper's and Navicat's filter bars.
    public func selectPage(table: String, schema: String?, offset: Int, limit: Int, orderBy: [OrderBy] = [], filter: String? = nil) -> String {
        var sql = "SELECT * FROM \(qualifiedName(table: table, schema: schema))"
        if let filter = filter?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty {
            sql += " WHERE \(filter)"
        }
        if !orderBy.isEmpty {
            sql += " ORDER BY " + orderBy.map { "\(quoteIdentifier($0.column)) \($0.direction.rawValue)" }.joined(separator: ", ")
        }
        if kind == .sqlserver {
            // OFFSET … FETCH needs an ORDER BY; (SELECT NULL) keeps the server's order.
            if orderBy.isEmpty { sql += " ORDER BY (SELECT NULL)" }
            return sql + " OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        }
        sql += " LIMIT \(limit) OFFSET \(offset)"
        return sql
    }

    /// Renders a value as a SQL literal for this engine.
    public func literal(_ value: CellValue) -> String {
        switch value {
        case .null:
            return "NULL"
        case .integer(let v):
            return String(v)
        case .double(let v):
            return v.isFinite ? String(v) : quoteLiteral(String(v))
        case .text(let v):
            return quoteLiteral(v)
        case .bool(let v):
            if kind == .sqlite || kind == .sqlserver { return v ? "1" : "0" }
            return v ? "TRUE" : "FALSE"
        case .blob(let data):
            let hex = data.map { String(format: "%02x", $0) }.joined()
            if kind == .sqlserver { return "0x" + hex }
            return kind == .postgresql ? "decode('\(hex)', 'hex')" : "X'\(hex)'"
        }
    }

    /// The statement that applies one grid change to `table`.
    /// `columns` supplies SQLite's default expressions for values set back to DEFAULT.
    public func sql(for change: RowChange, table: String, schema: String?, columns: [TableColumn] = []) -> String {
        let target = qualifiedName(table: table, schema: schema)
        switch change {
        case .update(let key, let values):
            let assignments = values.map { part in
                let value = part.useDefault ? defaultKeyword(for: columns.first { $0.name == part.column }) : literal(part.value)
                return "\(quoteIdentifier(part.column)) = \(value)"
            }
            return "UPDATE \(target) SET \(assignments.joined(separator: ", ")) WHERE \(whereClause(key))"
        case .insert(let values) where values.contains(where: \.useDefault):
            return sql(for: .insert(values: values.filter { !$0.useDefault }), table: table, schema: schema)
        case .insert(let values) where values.isEmpty:
            return kind == .mysql || kind == .mariadb
                ? "INSERT INTO \(target) () VALUES ()"
                : "INSERT INTO \(target) DEFAULT VALUES"
        case .insert(let values):
            let columns = values.map { quoteIdentifier($0.column) }.joined(separator: ", ")
            let literals = values.map { literal($0.value) }.joined(separator: ", ")
            return "INSERT INTO \(target) (\(columns)) VALUES (\(literals))"
        case .delete(let key):
            return "DELETE FROM \(target) WHERE \(whereClause(key))"
        }
    }

    private func whereClause(_ key: [ColumnValue]) -> String {
        key.map { part in
            part.value.isNull
                ? "\(quoteIdentifier(part.column)) IS NULL"
                : "\(quoteIdentifier(part.column)) = \(literal(part.value))"
        }
        .joined(separator: " AND ")
    }

    public var beginTransaction: String {
        switch kind {
        case .mysql, .mariadb: "START TRANSACTION"
        case .sqlserver: "BEGIN TRANSACTION"
        default: "BEGIN"
        }
    }

    /// The statement that shows `sql`'s plan without running it: `EXPLAIN QUERY PLAN` on SQLite,
    /// `EXPLAIN (FORMAT JSON)` on PostgreSQL and `EXPLAIN FORMAT=JSON` on MySQL/MariaDB, which
    /// `QueryPlan.parse` turns into a tree. A statement that already starts with EXPLAIN is kept as typed.
    public func explain(_ sql: String) -> String {
        var statement = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while statement.hasSuffix(";") { statement = String(statement.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        if statement.prefix(while: { $0.isLetter }).uppercased() == "EXPLAIN" { return statement }
        if kind == .sqlserver, statement.uppercased().hasPrefix(Self.showplanPrefix) { return statement }
        return switch kind {
        case .sqlserver: Self.showplanPrefix + "\n" + statement
        case .sqlite: "EXPLAIN QUERY PLAN " + statement
        case .postgresql: "EXPLAIN (FORMAT JSON) " + statement
        case .mysql, .mariadb: "EXPLAIN FORMAT=JSON " + statement
        case .mongodb: statement
        }
    }

    /// SQL Server's estimated plan: SET SHOWPLAN_XML must run alone in its batch, so the driver splits this
    /// prefix off, runs the statement for its plan (not executed) and switches SHOWPLAN off again.
    public static let showplanPrefix = "SET SHOWPLAN_XML ON;"

    public func countRows(table: String, schema: String?, filter: String? = nil) -> String {
        var sql = "SELECT COUNT(*) FROM \(qualifiedName(table: table, schema: schema))"
        if let filter = filter?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty {
            sql += " WHERE \(filter)"
        }
        return sql
    }
}
