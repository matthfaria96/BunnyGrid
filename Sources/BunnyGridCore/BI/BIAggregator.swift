import Foundation

/// The rows a chart draws: one per group, dimension keys as text and measures as numbers.
public struct BIResult: Hashable, Sendable {
    public struct Row: Hashable, Sendable {
        public var keys: [String]
        public var values: [Double?]

        public init(keys: [String], values: [Double?]) {
            self.keys = keys
            self.values = values
        }
    }

    public var rows: [Row]
    /// The statement that produced the rows, or nil when they were aggregated in memory.
    public var statement: String?
    public var duration: Duration

    public init(rows: [Row], statement: String? = nil, duration: Duration = .zero) {
        self.rows = rows
        self.statement = statement
        self.duration = duration
    }

    /// Reads a pushed-down result (`d0…, m0…`).
    public init(_ result: QueryResult, spec: BIAggregateSpec) {
        let dims = spec.dimensions.count
        rows = result.rows.map { cells in
            Row(keys: (0..<dims).map { cells.indices.contains($0) ? BIValue.key(cells[$0]) : "" },
                values: (0..<max(spec.measures.count, 1)).map { i in cells.indices.contains(dims + i) ? BIValue.number(cells[dims + i]) : nil })
        }
        statement = result.statement
        duration = result.duration
    }
}

enum BIValue {
    static let nullKey = "(Null)"

    static func key(_ value: CellValue) -> String {
        switch value {
        case .null: nullKey
        case .integer(let v): String(v)
        case .double(let v): v.rounded() == v && abs(v) < 1e15 ? String(Int64(v)) : String(v)
        case .text(let v): v
        case .bool(let v): v ? "true" : "false"
        case .blob(let d): "(\(d.count) bytes)"
        }
    }

    static func number(_ value: CellValue) -> Double? {
        switch value {
        case .null, .blob: nil
        case .integer(let v): Double(v)
        case .double(let v): v
        case .bool(let v): v ? 1 : 0
        case .text(let v): Double(v.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Parses ISO dates and timestamps ("2026-10-16", "2026-10-16 18:15:47", "2026-10-16T18:15:47Z").
    static func date(_ value: CellValue) -> DateComponents? {
        guard case .text(let text) = value else { return nil }
        return date(text)
    }

    static func date(_ text: String) -> DateComponents? {
        let parts = text.prefix(10).split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        return DateComponents(year: y, month: m, day: d)
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    static func bucket(_ value: CellValue, _ bucket: BIDateBucket) -> String {
        guard let c = date(value), let y = c.year, let m = c.month, let d = c.day else { return value == .null ? nullKey : key(value) }
        func text(_ y: Int, _ m: Int, _ d: Int) -> String { String(format: "%04d-%02d-%02d", y, m, d) }
        switch bucket {
        case .day: return text(y, m, d)
        case .month: return text(y, m, 1)
        case .quarter: return text(y, ((m - 1) / 3) * 3 + 1, 1)
        case .year: return text(y, 1, 1)
        case .week:
            let cal = calendar
            guard let date = cal.date(from: c) else { return text(y, m, d) }
            let weekday = cal.component(.weekday, from: date) // 1 = Sunday
            let back = (weekday + 5) % 7
            let start = cal.date(byAdding: .day, value: -back, to: date)!
            let s = cal.dateComponents([.year, .month, .day], from: start)
            return text(s.year!, s.month!, s.day!)
        }
    }
}

/// The in-memory engine: the same aggregation as `BIQueryBuilder`, over rows already fetched
/// (engines without GROUP BY push-down, or a result the user already has).
public enum BIAggregator {
    public static func aggregate(_ result: QueryResult, spec: BIAggregateSpec) -> BIResult {
        let index = Dictionary(result.columns.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        func cell(_ row: [CellValue], _ field: String?) -> CellValue {
            guard let field, let i = index[field], row.indices.contains(i) else { return .null }
            return row[i]
        }
        let rows = result.rows.filter { row in spec.filters.filter(\.isActive).allSatisfy { matches($0, cell(row, $0.field)) } }

        struct Accumulator {
            var count = 0
            var sum = 0.0
            var numeric = 0
            var min: Double?
            var max: Double?
            var distinct = Set<String>()
        }
        let measures = spec.measures.isEmpty ? [BIMeasure(field: nil, aggregation: .count)] : spec.measures
        var order: [[String]] = []
        var groups: [[String]: [Accumulator]] = [:]
        for row in rows {
            let keys = spec.dimensions.map { dim in
                let value = cell(row, dim.field)
                return dim.bucket.map { BIValue.bucket(value, $0) } ?? BIValue.key(value)
            }
            var accs = groups[keys] ?? {
                order.append(keys)
                return Array(repeating: Accumulator(), count: measures.count)
            }()
            for (i, measure) in measures.enumerated() {
                let value = cell(row, measure.field)
                if measure.field == nil { accs[i].count += 1; continue }
                if value == .null { continue }
                accs[i].count += 1
                switch measure.aggregation {
                case .countDistinct: accs[i].distinct.insert(BIValue.key(value))
                default:
                    if let n = BIValue.number(value) {
                        accs[i].sum += n
                        accs[i].numeric += 1
                        accs[i].min = Swift.min(accs[i].min ?? n, n)
                        accs[i].max = Swift.max(accs[i].max ?? n, n)
                    }
                }
            }
            groups[keys] = accs
        }
        if spec.dimensions.isEmpty && order.isEmpty {
            order = [[]]
            groups[[]] = Array(repeating: Accumulator(), count: measures.count)
        }
        var out: [BIResult.Row] = order.map { keys in
            let accs = groups[keys]!
            return BIResult.Row(keys: keys, values: zip(measures, accs).map { measure, acc in
                switch measure.aggregation {
                case .count: Double(acc.count)
                case .countDistinct: Double(acc.distinct.count)
                case .sum: acc.numeric > 0 ? acc.sum : nil
                case .avg: acc.numeric > 0 ? acc.sum / Double(acc.numeric) : nil
                case .min: acc.min
                case .max: acc.max
                }
            })
        }
        if let sort = spec.sort { out = sorted(out, by: sort) }
        if let limit = spec.limit, out.count > limit { out = Array(out.prefix(limit)) }
        return BIResult(rows: out, statement: nil, duration: result.duration)
    }

    static func sorted(_ rows: [BIResult.Row], by sort: BISort) -> [BIResult.Row] {
        rows.sorted { a, b in
            let ascending: Bool
            switch sort.key {
            case .dimension(let i):
                let x = a.keys.indices.contains(i) ? a.keys[i] : "", y = b.keys.indices.contains(i) ? b.keys[i] : ""
                if x == y { return false }
                if let nx = Double(x), let ny = Double(y) { ascending = nx < ny } else { ascending = x.localizedStandardCompare(y) == .orderedAscending }
            case .measure(let i):
                let x = a.values.indices.contains(i) ? a.values[i] ?? -.infinity : -.infinity
                let y = b.values.indices.contains(i) ? b.values[i] ?? -.infinity : -.infinity
                if x == y { return false }
                ascending = x < y
            }
            return sort.ascending ? ascending : !ascending
        }
    }

    static func matches(_ filter: BIFilter, _ value: CellValue) -> Bool {
        let text = BIValue.key(value)
        func compare(_ other: String) -> ComparisonResult? {
            if value == .null { return nil }
            if filter.numeric {
                guard let a = BIValue.number(value), let b = Double(other) else { return nil }
                return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
            }
            return text < other ? .orderedAscending : text > other ? .orderedDescending : .orderedSame
        }
        let values = filter.values
        switch filter.op {
        case .isIn: return value != .null && values.contains { compare($0) == .orderedSame }
        case .notIn: return value == .null || !values.contains { compare($0) == .orderedSame }
        case .equals: return compare(values[0]) == .orderedSame
        case .notEquals: return compare(values[0]).map { $0 != .orderedSame } ?? false
        case .greater: return compare(values[0]) == .orderedDescending
        case .greaterOrEqual: return compare(values[0]).map { $0 != .orderedAscending } ?? false
        case .less: return compare(values[0]) == .orderedAscending
        case .lessOrEqual: return compare(values[0]).map { $0 != .orderedDescending } ?? false
        case .between:
            return (compare(values[0]).map { $0 != .orderedAscending } ?? false) && (compare(values[1]).map { $0 != .orderedDescending } ?? false)
        case .contains: return value != .null && text.localizedCaseInsensitiveContains(values[0])
        }
    }
}

/// Field discovery: names and types from a sample of the source.
public enum BIFieldInference {
    public static func fields(_ sample: QueryResult, keeping previous: [BIField] = []) -> [BIField] {
        sample.columns.enumerated().map { i, name in
            let values = sample.rows.compactMap { $0.indices.contains(i) ? $0[i] : nil }.filter { $0 != .null }
            let type = infer(values, name: name)
            if let old = previous.first(where: { $0.name == name }), old.type == type { return old }
            return BIField(name: name, type: type, role: type == .number && isIdentifier(name) ? .dimension : nil)
        }
    }

    static func infer(_ values: [CellValue], name: String) -> BIFieldType {
        guard !values.isEmpty else { return .text }
        if values.allSatisfy({ if case .bool = $0 { true } else { false } }) { return .bool }
        if values.allSatisfy({ BIValue.number($0) != nil && !isText($0) }) { return .number }
        if values.allSatisfy({ BIValue.date($0) != nil }) { return .date }
        if values.allSatisfy({ BIValue.number($0) != nil }) { return .number }
        return .text
    }

    private static func isText(_ value: CellValue) -> Bool {
        if case .text = value { true } else { false }
    }

    /// `id`, `customer_id`: numbers that identify rather than measure.
    static func isIdentifier(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "id" || lower.hasSuffix("_id") || lower.hasSuffix("id") && lower.count <= 4
    }
}

/// Runs a chart's aggregation on a driver: pushed down as GROUP BY when the engine supports it, otherwise
/// (or when the pushed-down statement fails) the source rows are fetched, capped, and aggregated in memory.
public enum BIEngine {
    /// Rows read for the in-memory fallback.
    public static let fallbackRowCap = 200_000

    public static func run(_ spec: BIAggregateSpec, source: BIDataSource, driver: any DatabaseDriver) async throws -> BIResult {
        let dialect = SQLDialect(kind: driver.config.kind)
        let base = source.baseSQL(dialect)
        if dialect.supportsBIPushdown {
            let sql = BIQueryBuilder.sql(spec, source: base, dialect: dialect)
            do {
                let result = try await driver.executeStatement(sql, maxRows: spec.limit.map { $0 + 1 })
                return BIResult(result, spec: spec)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Fall through: a dialect gap (e.g. an odd date column) still gets a chart.
            }
        }
        let rows = try await driver.executeStatement(base, maxRows: fallbackRowCap)
        return BIAggregator.aggregate(rows, spec: spec)
    }

    public static func fields(for source: BIDataSource, driver: any DatabaseDriver) async throws -> [BIField] {
        let dialect = SQLDialect(kind: driver.config.kind)
        let sample = try await driver.executeStatement(BIQueryBuilder.sample(source: source.baseSQL(dialect)), maxRows: 200)
        return BIFieldInference.fields(sample, keeping: source.fields)
    }

    public static func distinctValues(field: String, source: BIDataSource, driver: any DatabaseDriver) async throws -> [String] {
        let dialect = SQLDialect(kind: driver.config.kind)
        let result = try await driver.executeStatement(
            BIQueryBuilder.distinctValues(field: field, source: source.baseSQL(dialect), dialect: dialect), maxRows: 200)
        return result.rows.compactMap { $0.first.map(BIValue.key) }
    }
}

/// The workspaces file (`bi-workspaces.json` in the data directory).
public struct BIWorkspaceStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> [BIWorkspace] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        return (try? decoder.decode([BIWorkspace].self, from: data)) ?? []
    }

    public func save(_ workspaces: [BIWorkspace]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(workspaces).write(to: fileURL, options: .atomic)
    }

    /// Inserts or replaces one workspace.
    public func upsert(_ workspace: BIWorkspace) throws {
        var all = load()
        if let i = all.firstIndex(where: { $0.id == workspace.id }) { all[i] = workspace } else { all.append(workspace) }
        try save(all)
    }

    public func delete(_ id: UUID) throws {
        try save(load().filter { $0.id != id })
    }
}
