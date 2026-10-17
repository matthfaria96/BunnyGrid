import Foundation

public enum SQLKeywords {
    public static let all = [
        "select", "from", "where", "and", "or", "not", "null", "is", "in", "like", "ilike", "between",
        "insert", "into", "values", "update", "set", "delete", "create", "table", "view", "index",
        "drop", "alter", "add", "column", "primary", "key", "foreign", "references", "unique", "default",
        "join", "inner", "left", "right", "full", "outer", "cross", "on", "using", "as", "distinct",
        "group", "by", "order", "having", "limit", "offset", "union", "all", "exists", "case", "when",
        "then", "else", "end", "asc", "desc", "with", "returning", "begin", "commit", "rollback",
        "transaction", "if", "true", "false", "function", "procedure", "trigger", "schema", "database",
        "grant", "revoke", "explain", "analyze", "show", "describe", "pragma", "truncate", "cascade",
        "constraint", "check", "materialized", "replace", "return", "returns", "language", "declare",
        "count", "sum", "avg", "min", "max", "coalesce", "cast",
    ]
}

/// Names the completion engine can suggest, gathered by the session from the object tree.
public struct CompletionCatalog: Sendable {
    public var schemas: [String]
    public var tables: [DatabaseObject]
    /// Column names keyed by lowercased table name.
    public var columns: [String: [String]]

    public init(schemas: [String] = [], tables: [DatabaseObject] = [], columns: [String: [String]] = [:]) {
        self.schemas = schemas
        self.tables = tables
        self.columns = columns
    }
}

public enum SQLCompletion {
    public struct TableReference: Hashable, Sendable {
        public var schema: String?
        public var table: String
        public var alias: String?

        public init(schema: String?, table: String, alias: String?) {
            self.schema = schema
            self.table = table
            self.alias = alias
        }
    }

    private static let referencePattern: NSRegularExpression = {
        let identifier = #"(?:"[^"]+"|`[^`]+`|[A-Za-z_][\w$]*)"#
        let stop = "on|where|join|left|right|inner|outer|cross|full|natural|group|order|limit|set|values|using|having|union|window"
        let pattern = #"\b(?:from|join|update|into)\s+("# + identifier + #"(?:\."# + identifier + #")?)(?:\s+(?:as\s+)?(?!(?:"# + stop + #")\b)([A-Za-z_]\w*))?"#
        // The pattern is a constant; failing to compile it is a programming error.
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    /// Tables named after FROM / JOIN / UPDATE / INTO, with their aliases.
    public static func tableReferences(in sql: String) -> [TableReference] {
        let ns = sql as NSString
        var seen = Set<TableReference>()
        var references: [TableReference] = []
        for match in referencePattern.matches(in: sql, range: NSRange(location: 0, length: ns.length)) {
            let path = splitQualified(ns.substring(with: match.range(at: 1)))
            let aliasRange = match.range(at: 2)
            let alias = aliasRange.location == NSNotFound ? nil : ns.substring(with: aliasRange)
            let reference = TableReference(schema: path.count > 1 ? path[0] : nil, table: path.last ?? "", alias: alias)
            if seen.insert(reference).inserted { references.append(reference) }
        }
        return references
    }

    /// Suggestions for the word being typed. `qualifier` is the identifier before a `.`, if any.
    public static func suggestions(prefix: String, qualifier: String?, sql: String, catalog: CompletionCatalog) -> [String] {
        let references = tableReferences(in: sql)
        let lowerPrefix = prefix.lowercased()
        func matches(_ name: String) -> Bool { lowerPrefix.isEmpty || name.lowercased().hasPrefix(lowerPrefix) }

        if let qualifier = qualifier.map(unquote) {
            let q = qualifier.lowercased()
            // Aliases win, then schemas (`sales.` while typing a table), then table names.
            if let reference = references.first(where: { $0.alias?.lowercased() == q }) {
                return (catalog.columns[reference.table.lowercased()] ?? []).filter(matches)
            }
            if catalog.schemas.contains(where: { $0.lowercased() == q }) {
                return catalog.tables.filter { $0.schema?.lowercased() == q && $0.kind != .routine }.map(\.name).filter(matches)
            }
            return (catalog.columns[q] ?? []).filter(matches)
        }

        var results: [String] = []
        var seen = Set<String>()
        func add(_ names: [String]) {
            for name in names where matches(name) && seen.insert(name.lowercased()).inserted {
                results.append(name)
            }
        }
        for reference in references {
            add(catalog.columns[reference.table.lowercased()] ?? [])
        }
        add(catalog.tables.filter { $0.kind != .routine }.map(\.name))
        add(catalog.schemas)
        add(SQLKeywords.all.map { $0.uppercased() })
        return results
    }

    private static func splitQualified(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for c in text {
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
            } else if c == "\"" || c == "`" {
                quote = c
            } else if c == "." {
                parts.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        parts.append(current)
        return parts
    }

    private static func unquote(_ text: String) -> String {
        splitQualified(text).joined(separator: ".")
    }
}
