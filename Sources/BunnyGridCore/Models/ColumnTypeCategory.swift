import Foundation

/// What a declared column type holds, as far as editing and parameter binding care.
/// Picks the value editor (text, JSON, hex/image, date picker) and how an edited value is bound.
public enum ColumnTypeCategory: String, Sendable, CaseIterable {
    case integer
    case real
    /// numeric / decimal / money: kept as text so no precision is lost.
    case decimal
    case boolean
    case text
    case json
    case binary
    case date
    case time
    case timeWithTimeZone
    case dateTime
    case dateTimeWithTimeZone
    case uuid
    /// Arrays, enums of PostgreSQL, geometry, intervals, domains…: sent as text for the server to convert.
    case other

    public var isTemporal: Bool {
        switch self {
        case .date, .time, .timeWithTimeZone, .dateTime, .dateTimeWithTimeZone: true
        default: false
        }
    }

    public var isNumeric: Bool { self == .integer || self == .real || self == .decimal }

    /// Text-like values where "empty string" is a meaningful choice in the value editor.
    public var acceptsEmptyString: Bool {
        switch self {
        case .text, .json, .other: true
        default: false
        }
    }

    /// Classifies a declared type such as `int4`, `numeric(5,2)`, `varchar(40)`, `int(11) unsigned`,
    /// `timestamp(6)` or SQLite's free-form `DATETIME`.
    public static func classify(_ declaredType: String?, kind: DatabaseKind) -> ColumnTypeCategory {
        guard let declaredType else { return .other }
        let raw = declaredType.trimmingCharacters(in: .whitespaces).lowercased()
        if raw.isEmpty { return .other }
        // PostgreSQL arrays: `_int4` (udt_name) or `integer[]`.
        if raw.hasSuffix("]") || (kind == .postgresql && raw.hasPrefix("_")) { return .other }
        let base = normalize(raw)

        switch base {
        case "int", "integer", "smallint", "bigint", "tinyint", "mediumint", "int2", "int4", "int8",
             "serial", "smallserial", "bigserial", "serial2", "serial4", "serial8", "oid", "year":
            return .integer
        case "real", "float", "double", "double precision", "float4", "float8":
            return .real
        case "numeric", "decimal", "dec", "fixed", "money":
            return .decimal
        case "bool", "boolean":
            return .boolean
        case "text", "varchar", "char", "character", "character varying", "bpchar", "name", "nvarchar", "nchar",
             "tinytext", "mediumtext", "longtext", "clob", "string", "enum", "set", "varchar2", "nvarchar2":
            return .text
        case "json", "jsonb":
            return .json
        case "bytea", "blob", "tinyblob", "mediumblob", "longblob", "binary", "varbinary", "image":
            return .binary
        case "date":
            return .date
        case "time", "time without time zone":
            return .time
        case "timetz", "time with time zone":
            return .timeWithTimeZone
        case "timestamp", "datetime", "timestamp without time zone", "datetime2", "smalldatetime":
            return .dateTime
        case "timestamptz", "timestamp with time zone", "datetimeoffset":
            return .dateTimeWithTimeZone
        case "uuid", "uniqueidentifier":
            return .uuid
        default:
            break
        }
        guard kind == .sqlite else { return .other }
        // SQLite type affinity (https://sqlite.org/datatype3.html §3.1), checked in its order.
        if base.contains("int") { return .integer }
        if base.contains("char") || base.contains("clob") || base.contains("text") { return .text }
        if base.contains("blob") { return .binary }
        if base.contains("real") || base.contains("floa") || base.contains("doub") { return .real }
        if base.contains("bool") { return .boolean }
        if base.contains("json") { return .json }
        if base.contains("datetime") || base.contains("timestamp") { return .dateTime }
        if base.contains("date") { return .date }
        if base.contains("time") { return .time }
        return .decimal
    }

    /// Lowercased type without modifiers: `numeric(5,2)` → `numeric`, `int(11) unsigned` → `int`.
    private static func normalize(_ type: String) -> String {
        var result = ""
        var depth = 0
        for character in type {
            if character == "(" { depth += 1; continue }
            if character == ")" { depth = max(0, depth - 1); continue }
            if depth == 0 { result.append(character) }
        }
        let words = result.split(whereSeparator: \.isWhitespace)
            .filter { !["unsigned", "signed", "zerofill"].contains($0) }
        return words.joined(separator: " ")
    }
}
