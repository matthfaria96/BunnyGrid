import Foundation

/// Model → SQL ("Generate SQL"): CREATE TABLE for each table, parents first, plus the foreign keys.
/// SQLite gets its keys inside CREATE TABLE (it can't add them later); the other engines get
/// ALTER TABLE … ADD CONSTRAINT … FOREIGN KEY after every table exists, so cycles work too.
extension ERModel {
    public struct SQLOptions: Sendable {
        /// Only these table ids (nil: all). Keys to tables left out are skipped.
        public var tables: Set<String>?
        public var includeDrop: Bool
        public var includeForeignKeys: Bool

        public init(tables: Set<String>? = nil, includeDrop: Bool = false, includeForeignKeys: Bool = true) {
            self.tables = tables
            self.includeDrop = includeDrop
            self.includeForeignKeys = includeForeignKeys
        }
    }

    public func generateSQL(for kind: DatabaseKind, options: SQLOptions = SQLOptions()) -> String {
        let dialect = SQLDialect(kind: kind)
        let included = tables.filter { options.tables?.contains($0.id) ?? true }
        let ids = Set(included.map(\.id))
        let ordered = creationOrder(included)
        let relations = options.includeForeignKeys
            ? relationships.filter { ids.contains($0.fromTable) && ids.contains($0.toTable) }
            : []
        // Only PostgreSQL keeps the model's schema; MySQL databases and SQLite files are the target itself.
        // SQL Server keeps the schema of a SQL Server model; other models land in the default schema (dbo).
        func schema(_ table: ERTable) -> String? {
            kind == .postgresql || (kind == .sqlserver && sourceKind == .sqlserver) ? table.schema : nil
        }
        func name(_ id: String) -> String { table(id)?.name ?? id }

        var statements: [String] = []
        if options.includeDrop {
            for table in ordered.reversed() {
                statements.append("DROP TABLE IF EXISTS \(dialect.qualifiedName(table: table.name, schema: schema(table)))\(kind == .postgresql ? " CASCADE" : "");")
            }
        }
        for table in ordered {
            var parts = table.columns.map { "  " + dialect.columnDefinition(portableColumn($0, in: table, to: kind)) + autoIncrement($0, in: table, to: kind) }
            let keys = table.primaryKey.map(dialect.quoteIdentifier)
            if !keys.isEmpty { parts.append("  PRIMARY KEY (\(keys.joined(separator: ", ")))") }
            if kind == .sqlite {
                for relation in relations where relation.fromTable == table.id {
                    parts.append("  " + foreignKeyClause(relation, dialect: dialect, parent: name(relation.toTable), parentSchema: nil))
                }
            }
            if parts.isEmpty { continue }
            statements.append("CREATE TABLE \(dialect.qualifiedName(table: table.name, schema: schema(table))) (\n\(parts.joined(separator: ",\n"))\n);")
        }
        if kind != .sqlite {
            for relation in relations {
                guard let child = table(relation.fromTable), let parent = table(relation.toTable) else { continue }
                let key = TableForeignKey(name: constraintName(relation), columns: relation.fromColumns, referencedSchema: schema(parent),
                                          referencedTable: parent.name, referencedColumns: relation.toColumns,
                                          onDelete: relation.onDelete.uppercased(), onUpdate: relation.onUpdate.uppercased())
                if let sql = try? dialect.addForeignKey(key, table: child.name, schema: schema(child)) {
                    statements.append(sql + ";")
                }
            }
        }
        let header = "-- \(included.count) table\(included.count == 1 ? "" : "s"), \(relations.count) relationship\(relations.count == 1 ? "" : "s")"
            + (kind == sourceKind ? " (\(kind.displayName))" : " (\(sourceKind.displayName) → \(kind.displayName))")
        return ([header] + statements).joined(separator: "\n\n") + "\n"
    }

    /// Parents before children (by name among equals); tables caught in a cycle follow in name order.
    func creationOrder(_ tables: [ERTable]) -> [ERTable] {
        let ids = Set(tables.map(\.id))
        var pending = tables.sorted { $0.id < $1.id }
        var created = Set<String>()
        var ordered: [ERTable] = []
        while !pending.isEmpty {
            let ready = pending.firstIndex { table in
                relationships.allSatisfy { $0.fromTable != table.id || $0.isSelfReference || !ids.contains($0.toTable) || created.contains($0.toTable) }
            } ?? 0
            let table = pending.remove(at: ready)
            created.insert(table.id)
            ordered.append(table)
        }
        return ordered
    }

    private func constraintName(_ relation: ERRelationship) -> String {
        if !relation.name.isEmpty { return relation.name }
        let child = table(relation.fromTable)?.name ?? relation.fromTable
        return "fk_\(child)_\(relation.fromColumns.joined(separator: "_"))"
    }

    private func foreignKeyClause(_ relation: ERRelationship, dialect: SQLDialect, parent: String, parentSchema: String?) -> String {
        var sql = "CONSTRAINT \(dialect.quoteIdentifier(constraintName(relation))) FOREIGN KEY (\(relation.fromColumns.map(dialect.quoteIdentifier).joined(separator: ", ")))"
            + " REFERENCES \(dialect.qualifiedName(table: parent, schema: parentSchema)) (\(relation.toColumns.map(dialect.quoteIdentifier).joined(separator: ", ")))"
        let onDelete = relation.onDelete.uppercased(), onUpdate = relation.onUpdate.uppercased()
        if onDelete != "NO ACTION" && !onDelete.isEmpty { sql += " ON DELETE \(onDelete)" }
        if onUpdate != "NO ACTION" && !onUpdate.isEmpty { sql += " ON UPDATE \(onUpdate)" }
        return sql
    }

    // MARK: - Types

    private func isSequence(_ column: ERColumn) -> Bool {
        sourceKind == .postgresql && (column.defaultValue?.lowercased().hasPrefix("nextval(") ?? false)
    }

    /// The column for the target engine: same engine keeps everything; another engine gets a translated type
    /// and only defaults that mean the same everywhere.
    func portableColumn(_ column: ERColumn, in table: ERTable, to kind: DatabaseKind) -> ColumnDesign {
        var design = ColumnDesign(name: column.name, type: column.dataType, nullable: column.nullable && !column.isPrimaryKey,
                                  defaultValue: column.defaultValue ?? "", isPrimaryKey: column.isPrimaryKey)
        if kind == sourceKind {
            if design.type.isEmpty { design.type = kind == .sqlite ? "TEXT" : "text" }
            return design
        }
        let isKey = column.isPrimaryKey || column.isForeignKey
        design.type = Self.translateType(column.dataType, from: sourceKind, to: kind, isKey: isKey)
        if isSequence(column) {
            design.defaultValue = ""
            if kind == .postgresql { design.type = design.type == "bigint" ? "bigserial" : "serial" }
        } else {
            design.defaultValue = Self.portableDefault(column.defaultValue)
        }
        return design
    }

    private func autoIncrement(_ column: ERColumn, in table: ERTable, to kind: DatabaseKind) -> String {
        guard kind == .mysql || kind == .mariadb || kind == .sqlserver, kind != sourceKind, column.isPrimaryKey, table.primaryKey.count == 1 else { return "" }
        let type = column.dataType.lowercased()
        let serial = type.hasPrefix("serial") || type.hasPrefix("bigserial") || isSequence(column)
            || column.defaultValue?.lowercased().contains("auto_increment") == true
        guard serial else { return "" }
        return kind == .sqlserver ? " IDENTITY(1,1)" : " AUTO_INCREMENT"
    }

    /// A default that every engine reads the same way, or "" to drop it.
    static func portableDefault(_ value: String?) -> String {
        guard var value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return "" }
        // PostgreSQL casts: 'abc'::character varying, 0::numeric.
        if let cast = value.range(of: "::", options: .backwards), !value[cast.upperBound...].contains("'") {
            value = String(value[..<cast.lowerBound])
        }
        if value.hasPrefix("(") && value.hasSuffix(")") { value = String(value.dropFirst().dropLast()) }
        let upper = value.uppercased()
        if ["NULL", "TRUE", "FALSE", "CURRENT_TIMESTAMP", "CURRENT_DATE", "CURRENT_TIME"].contains(upper) { return upper }
        if upper == "NOW()" || upper.hasPrefix("CURRENT_TIMESTAMP(") { return "CURRENT_TIMESTAMP" }
        if Double(value) != nil { return value }
        if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 { return value }
        return ""
    }

    /// Translates a column type between engines, keeping length and precision where the target has them.
    static func translateType(_ type: String, from source: DatabaseKind, to target: DatabaseKind, isKey: Bool) -> String {
        let trimmed = type.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
            .replacingOccurrences(of: " unsigned", with: "")
            .replacingOccurrences(of: " zerofill", with: "")
        let open = lower.firstIndex(of: "(")
        let base = String(lower[..<(open ?? lower.endIndex)]).trimmingCharacters(in: .whitespaces)
        let params = open.map { String(lower[$0...]).replacingOccurrences(of: " ", with: "") } ?? ""

        func family() -> String {
            switch base {
            case "int", "integer", "int4", "mediumint", "serial", "serial4": return "int"
            case "bigint", "int8", "bigserial", "serial8": return "bigint"
            case "smallint", "int2", "smallserial", "serial2": return "smallint"
            case "tinyint": return params == "(1)" ? "bool" : "smallint"
            case "bool", "boolean", "bit" where params.isEmpty || params == "(1)": return "bool"
            case "money", "smallmoney": return "decimal"
            case "ntext", "xml", "sysname": return "text"
            case "image": return "blob"
            case "datetime2", "smalldatetime", "datetimeoffset": return "timestamp"
            case "uniqueidentifier": return "uuid"
            case "nvarchar" where params == "(max)", "varchar" where params == "(max)": return "text"
            case "varbinary" where params == "(max)": return "blob"
            case "real" where source == .sqlite, "double", "double precision", "float8": return "double"
            case "real", "float", "float4": return "float"
            case "numeric", "decimal", "number", "dec": return "decimal"
            case "varchar", "character varying", "nvarchar", "varchar2": return "varchar"
            case "char", "character", "bpchar", "nchar": return "char"
            case "text", "tinytext", "mediumtext", "longtext", "clob", "string", "": return "text"
            case "blob", "tinyblob", "mediumblob", "longblob", "bytea", "binary", "varbinary": return "blob"
            case "date": return "date"
            case "datetime", "timestamp", "timestamp without time zone", "timestamptz", "timestamp with time zone": return "timestamp"
            case "time", "timetz", "time without time zone", "time with time zone": return "time"
            case "uuid": return "uuid"
            case "json", "jsonb": return "json"
            case "year": return "smallint"
            default: return base.hasPrefix("enum") || base.hasPrefix("set") ? "text" : "other"
            }
        }
        let kind = family()
        let precision = ["timestamp", "time"].contains(kind) ? params : ""

        switch target {
        case .sqlite:
            switch kind {
            case "int", "bigint", "smallint", "bool": return "INTEGER"
            case "double", "float": return "REAL"
            case "decimal": return "NUMERIC" + params
            case "varchar", "char": return kind.uppercased() + params
            case "text", "uuid", "json": return "TEXT"
            case "blob": return "BLOB"
            case "date": return "DATE"
            case "timestamp": return "DATETIME"
            case "time": return "TIME"
            default: return trimmed
            }
        case .postgresql:
            switch kind {
            case "int": return "integer"
            case "bigint": return "bigint"
            case "smallint": return "smallint"
            case "bool": return "boolean"
            case "double": return "double precision"
            case "float": return "real"
            case "decimal": return "numeric" + params
            case "varchar": return "varchar" + params
            case "char": return "char" + params
            case "text": return "text"
            case "blob": return "bytea"
            case "date": return "date"
            case "timestamp": return (base.contains("tz") || base.contains("with time zone") ? "timestamptz" : "timestamp") + precision
            case "time": return "time" + precision
            case "uuid": return "uuid"
            case "json": return base == "jsonb" ? "jsonb" : "json"
            default: return trimmed
            }
        case .mysql, .mariadb:
            switch kind {
            case "int": return "int"
            case "bigint": return "bigint"
            case "smallint": return "smallint"
            case "bool": return "tinyint(1)"
            case "double": return "double"
            case "float": return "float"
            case "decimal": return "decimal" + (params.isEmpty ? "(18,4)" : params)
            case "varchar": return "varchar" + (params.isEmpty ? "(255)" : params)
            case "char": return "char" + (params.isEmpty ? "(1)" : params)
            // MySQL can't index TEXT without a prefix length, so key columns become varchar.
            case "text": return isKey ? "varchar(255)" : "text"
            case "blob": return "longblob"
            case "date": return "date"
            case "timestamp": return "datetime" + precision
            case "time": return "time" + precision
            case "uuid": return "char(36)"
            case "json": return "json"
            default: return trimmed
            }
        case .sqlserver:
            switch kind {
            case "int": return "int"
            case "bigint": return "bigint"
            case "smallint": return "smallint"
            case "bool": return "bit"
            case "double": return "float"
            case "float": return "real"
            case "decimal": return "decimal" + (params.isEmpty ? "(18,4)" : params)
            case "varchar": return "nvarchar" + (params.isEmpty ? "(255)" : params)
            case "char": return "nchar" + (params.isEmpty ? "(1)" : params)
            // Index keys can't be nvarchar(max).
            case "text", "json": return isKey ? "nvarchar(450)" : "nvarchar(max)"
            case "blob": return "varbinary(max)"
            case "date": return "date"
            case "timestamp":
                return base.contains("tz") || base.contains("with time zone") || base == "datetimeoffset" ? "datetimeoffset" + precision : "datetime2" + precision
            case "time": return "time" + precision
            case "uuid": return "uniqueidentifier"
            default: return trimmed
            }
        }
    }
}
