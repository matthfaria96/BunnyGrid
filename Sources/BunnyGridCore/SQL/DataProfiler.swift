import Foundation

/// Statistics for one column, shown by Data Profiling.
public struct ColumnProfile: Identifiable, Sendable, Equatable {
    public struct TopValue: Sendable, Equatable, Identifiable {
        public var value: String
        public var count: Int
        public var id: String { value }
    }

    public var name: String
    public var type: String
    public var total: Int
    public var nonNull: Int
    public var distinct: Int?
    public var minimum: String?
    public var maximum: String?
    public var average: String?
    public var topValues: [TopValue]
    /// Set when a statistic couldn't be computed for this column's type.
    public var note: String?

    public var id: String { name }
    public var nullCount: Int { total - nonNull }
    public var nullRatio: Double { total == 0 ? 0 : Double(nullCount) / Double(total) }
}

/// Per-table numbers for the Objects tab (row estimate, size, comment).
public struct TableStatistics: Sendable, Equatable {
    public var rows: Int?
    public var sizeBytes: Int?
    public var comment: String?
    public var engine: String?

    public init(rows: Int? = nil, sizeBytes: Int? = nil, comment: String? = nil, engine: String? = nil) {
        self.rows = rows
        self.sizeBytes = sizeBytes
        self.comment = comment
        self.engine = engine
    }
}

public enum DataProfiler {
    private enum Category { case numeric, temporal, text, other }

    private static func category(_ type: String) -> Category {
        let t = type.lowercased()
        if ["int", "numeric", "decimal", "real", "float", "double", "serial", "money"].contains(where: t.contains) { return .numeric }
        if ["date", "time", "year"].contains(where: t.contains) { return .temporal }
        if ["char", "text", "clob", "enum", "uuid", "citext", "name"].contains(where: t.contains) || t.isEmpty { return .text }
        return .other
    }

    /// Profiles each column with its own queries, so one unsupported type doesn't fail the rest.
    public static func profile(driver: any DatabaseDriver, table: String, schema: String?, columns: [TableColumn], topCount: Int = 5) async -> [ColumnProfile] {
        let dialect = driver.dialect
        let target = dialect.qualifiedName(table: table, schema: schema)
        var profiles: [ColumnProfile] = []
        for column in columns {
            if Task.isCancelled { break }
            let c = dialect.quoteIdentifier(column.name)
            let kind = category(column.dataType)
            var profile = ColumnProfile(name: column.name, type: column.dataType, total: 0, nonNull: 0, topValues: [])

            if let counts = try? await driver.executeStatement("SELECT COUNT(*), COUNT(\(c)) FROM \(target)").rows.first, counts.count == 2 {
                profile.total = intValue(counts[0])
                profile.nonNull = intValue(counts[1])
            }
            if kind != .other, let row = try? await driver.executeStatement("SELECT COUNT(DISTINCT \(c)), MIN(\(c)), MAX(\(c)) FROM \(target)").rows.first, row.count == 3 {
                profile.distinct = intValue(row[0])
                profile.minimum = row[1].isNull ? nil : row[1].displayString
                profile.maximum = row[2].isNull ? nil : row[2].displayString
            } else if kind == .other {
                profile.note = "Min, max and distinct aren't computed for \(column.dataType)."
            }
            if kind == .numeric, let row = try? await driver.executeStatement("SELECT AVG(\(c)) FROM \(target)").rows.first, let value = row.first, !value.isNull {
                profile.average = formatAverage(value)
            }
            if kind != .other, let rows = try? await driver.executeStatement(
                "SELECT \(c), COUNT(*) FROM \(target) WHERE \(c) IS NOT NULL GROUP BY \(c) ORDER BY COUNT(*) DESC, 1 LIMIT \(topCount)"
            ).rows {
                profile.topValues = rows.compactMap { row in
                    row.count == 2 ? ColumnProfile.TopValue(value: row[0].displayString, count: intValue(row[1])) : nil
                }
            }
            profiles.append(profile)
        }
        return profiles
    }

    private static func intValue(_ value: CellValue) -> Int {
        switch value {
        case .integer(let v): Int(v)
        case .double(let v): Int(v)
        case .text(let s): Int(s) ?? Int(Double(s) ?? 0)
        default: 0
        }
    }

    private static func formatAverage(_ value: CellValue) -> String {
        let number: Double? = switch value {
        case .integer(let v): Double(v)
        case .double(let v): v
        case .text(let s): Double(s)
        default: nil
        }
        guard let number else { return value.displayString }
        return number.formatted(.number.precision(.fractionLength(0...4)))
    }
}

/// How Data Masking hides a column's values in the grid and in exports.
public enum MaskRule: String, CaseIterable, Codable, Sendable, Identifiable {
    case none = "No Masking"
    case full = "Full (*****)"
    case partial = "Partial (a***z)"
    case email = "Email (a***@domain)"
    case lastFour = "Last 4 (****1234)"

    public var id: String { rawValue }

    public func apply(to value: CellValue) -> CellValue {
        guard self != .none, !value.isNull else { return value }
        let text = value.displayString
        switch self {
        case .none:
            return value
        case .full:
            return .text(String(repeating: "*", count: max(5, min(text.count, 10))))
        case .partial:
            guard text.count > 2 else { return .text(String(repeating: "*", count: text.count)) }
            return .text("\(text.first!)\(String(repeating: "*", count: min(text.count - 2, 8)))\(text.last!)")
        case .email:
            guard let at = text.firstIndex(of: "@"), at > text.startIndex else { return MaskRule.partial.apply(to: value) }
            return .text("\(text.first!)***\(text[at...])")
        case .lastFour:
            guard text.count > 4 else { return .text(String(repeating: "*", count: text.count)) }
            return .text(String(repeating: "*", count: min(text.count - 4, 8)) + text.suffix(4))
        }
    }
}

/// A saved view of a table: filter, sort, hidden columns and masks (Navicat's Table Profile).
public struct TableProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var connectionID: UUID
    public var database: String
    public var schema: String?
    public var table: String
    public var name: String
    public var filter: String
    public var sortColumn: String?
    public var sortDescending: Bool
    public var hiddenColumns: [String]
    public var masks: [String: MaskRule]

    public init(id: UUID = UUID(), connectionID: UUID, database: String, schema: String?, table: String, name: String,
                filter: String = "", sortColumn: String? = nil, sortDescending: Bool = false,
                hiddenColumns: [String] = [], masks: [String: MaskRule] = [:]) {
        self.id = id
        self.connectionID = connectionID
        self.database = database
        self.schema = schema
        self.table = table
        self.name = name
        self.filter = filter
        self.sortColumn = sortColumn
        self.sortDescending = sortDescending
        self.hiddenColumns = hiddenColumns
        self.masks = masks
    }
}
