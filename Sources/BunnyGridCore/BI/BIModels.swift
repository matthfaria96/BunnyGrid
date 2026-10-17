import Foundation

// Navicat BI: a workspace holds data sources, charts built from them and dashboards that arrange the charts.
// Everything here is plain Codable data; the aggregation SQL lives in `BIQueryBuilder`, the in-memory fallback
// in `BIAggregator`, and the file in `BIWorkspaceStore`.

/// The kind of value a field holds, inferred from a sample of the source's rows.
public enum BIFieldType: String, Codable, Sendable, CaseIterable {
    case text
    case number
    case date
    case bool

    /// Numbers are measures by default; everything else is a dimension.
    public var defaultRole: BIFieldRole { self == .number ? .measure : .dimension }
}

public enum BIFieldRole: String, Codable, Sendable {
    case dimension
    case measure
}

public struct BIField: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var type: BIFieldType
    public var role: BIFieldRole
    public var id: String { name }

    public init(name: String, type: BIFieldType, role: BIFieldRole? = nil) {
        self.name = name
        self.type = type
        self.role = role ?? type.defaultRole
    }
}

/// Where a chart's rows come from: a table or view, or custom SQL (a saved query's text), on one connection.
public struct BIDataSource: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var connectionID: UUID
    public var database: String
    public var schema: String?
    /// A table or view; nil when `sql` is set.
    public var table: String?
    /// Custom SQL (or the text of a saved query). Takes precedence over `table`.
    public var sql: String?
    /// Fields found by the last refresh, with any role the user changed.
    public var fields: [BIField]

    public init(id: UUID = UUID(), name: String, connectionID: UUID, database: String, schema: String? = nil,
                table: String? = nil, sql: String? = nil, fields: [BIField] = []) {
        self.id = id
        self.name = name
        self.connectionID = connectionID
        self.database = database
        self.schema = schema
        self.table = table
        self.sql = sql
        self.fields = fields
    }

    /// The SELECT the aggregation wraps as a derived table.
    public func baseSQL(_ dialect: SQLDialect) -> String {
        if let sql = sql?.trimmingCharacters(in: .whitespacesAndNewlines), !sql.isEmpty {
            var text = sql
            while text.hasSuffix(";") { text = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
            return text
        }
        return "SELECT * FROM \(dialect.qualifiedName(table: table ?? name, schema: schema))"
    }
}

public enum BIAggregation: String, Codable, Sendable, CaseIterable {
    case sum, avg, count, countDistinct, min, max

    public var title: String {
        switch self {
        case .sum: "Sum"
        case .avg: "Average"
        case .count: "Count"
        case .countDistinct: "Count Distinct"
        case .min: "Min"
        case .max: "Max"
        }
    }
}

public enum BIDateBucket: String, Codable, Sendable, CaseIterable {
    case day, week, month, quarter, year

    public var title: String { rawValue.capitalized }
}

public struct BIDimension: Codable, Hashable, Sendable {
    public var field: String
    /// For date fields: the period rows are grouped by.
    public var bucket: BIDateBucket?

    public init(field: String, bucket: BIDateBucket? = nil) {
        self.field = field
        self.bucket = bucket
    }

    public var label: String { bucket.map { "\(field) (\($0.title))" } ?? field }
}

public struct BIMeasure: Codable, Hashable, Sendable {
    /// Nil counts rows.
    public var field: String?
    public var aggregation: BIAggregation

    public init(field: String?, aggregation: BIAggregation) {
        self.field = field
        self.aggregation = field == nil ? .count : aggregation
    }

    public var label: String {
        guard let field else { return "Count of Rows" }
        return "\(aggregation.title) of \(field)"
    }
}

public struct BIFilter: Codable, Hashable, Sendable, Identifiable {
    public enum Operator: String, Codable, Sendable, CaseIterable {
        case isIn, notIn, equals, notEquals, greater, greaterOrEqual, less, lessOrEqual, contains, between

        public var title: String {
            switch self {
            case .isIn: "is any of"
            case .notIn: "is none of"
            case .equals: "="
            case .notEquals: "≠"
            case .greater: ">"
            case .greaterOrEqual: "≥"
            case .less: "<"
            case .lessOrEqual: "≤"
            case .contains: "contains"
            case .between: "between"
            }
        }
    }

    public var id: UUID
    public var field: String
    public var op: Operator
    public var values: [String]
    /// Compare as numbers (unquoted literals) instead of text.
    public var numeric: Bool

    public init(id: UUID = UUID(), field: String, op: Operator, values: [String], numeric: Bool = false) {
        self.id = id
        self.field = field
        self.op = op
        self.values = values
        self.numeric = numeric
    }

    /// A filter with nothing picked keeps every row.
    public var isActive: Bool {
        switch op {
        case .between: values.count == 2
        default: !values.isEmpty
        }
    }
}

public struct BISort: Codable, Hashable, Sendable {
    public enum Key: Codable, Hashable, Sendable {
        case dimension(Int)
        case measure(Int)
    }

    public var key: Key
    public var ascending: Bool

    public init(key: Key, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }
}

/// What to compute: GROUP BY `dimensions`, aggregate `measures`, after `filters`, ordered and cut to `limit`.
public struct BIAggregateSpec: Codable, Hashable, Sendable {
    public var dimensions: [BIDimension]
    public var measures: [BIMeasure]
    public var filters: [BIFilter]
    public var sort: BISort?
    public var limit: Int?

    public init(dimensions: [BIDimension] = [], measures: [BIMeasure] = [], filters: [BIFilter] = [], sort: BISort? = nil, limit: Int? = nil) {
        self.dimensions = dimensions
        self.measures = measures
        self.filters = filters
        self.sort = sort
        self.limit = limit
    }
}

public enum BIChartType: String, Codable, Sendable, CaseIterable {
    case bar, stackedBar, horizontalBar, line, area, pie, donut, scatter, kpi, table, heatmap

    public var title: String {
        switch self {
        case .bar: "Bar"
        case .stackedBar: "Stacked Bar"
        case .horizontalBar: "Horizontal Bar"
        case .line: "Line"
        case .area: "Area"
        case .pie: "Pie"
        case .donut: "Donut"
        case .scatter: "Scatter"
        case .kpi: "Value"
        case .table: "Pivot Table"
        case .heatmap: "Heatmap"
        }
    }

    public var systemImage: String {
        switch self {
        case .bar: "chart.bar.fill"
        case .stackedBar: "chart.bar.xaxis"
        case .horizontalBar: "align.horizontal.left.fill"
        case .line: "chart.xyaxis.line"
        case .area: "chart.line.uptrend.xyaxis"
        case .pie: "chart.pie.fill"
        case .donut: "circle.dashed"
        case .scatter: "chart.dots.scatter"
        case .kpi: "number.square"
        case .table: "tablecells"
        case .heatmap: "square.grid.3x3.fill"
        }
    }

    /// How many points a chart of this type draws at most, so rendering stays smooth.
    public var pointCap: Int {
        switch self {
        case .pie, .donut: 12
        case .kpi: 1
        case .scatter: 2000
        case .table: 1000
        case .heatmap: 600
        default: 500
        }
    }
}

public enum BIPalette: String, Codable, Sendable, CaseIterable {
    case standard, ocean, sunset, forest, mono
}

public enum BINumberFormat: String, Codable, Sendable, CaseIterable {
    case automatic, integer, decimal, percent, currency, compact

    public var title: String { rawValue.capitalized }

    public func format(_ value: Double) -> String {
        switch self {
        case .automatic:
            return value.rounded() == value && abs(value) < 1e15
                ? value.formatted(.number.precision(.fractionLength(0)))
                : value.formatted(.number.precision(.fractionLength(0...2)))
        case .integer: return value.formatted(.number.precision(.fractionLength(0)))
        case .decimal: return value.formatted(.number.precision(.fractionLength(2)))
        case .percent: return (value / 100).formatted(.percent.precision(.fractionLength(0...1)))
        case .currency: return value.formatted(.currency(code: "USD"))
        case .compact: return value.formatted(.number.notation(.compactName))
        }
    }
}

public struct BIChart: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var sourceID: UUID?
    public var type: BIChartType
    /// Axis (category) fields: the first is the X axis; a second becomes the series for bar/line/heatmap.
    public var dimensions: [BIDimension]
    /// Value fields: the first is Y, the second is the scatter's Y or the bubble size.
    public var measures: [BIMeasure]
    /// Splits the series by colour.
    public var color: BIDimension?
    /// Scatter bubble size.
    public var size: BIMeasure?
    public var filters: [BIFilter]
    public var sort: BISort?
    public var topN: Int?
    // Properties pane
    public var title: String
    public var showTitle: Bool
    public var showLegend: Bool
    public var showValues: Bool
    public var palette: BIPalette
    public var numberFormat: BINumberFormat
    public var xAxisTitle: String
    public var yAxisTitle: String

    public init(id: UUID = UUID(), name: String, sourceID: UUID?, type: BIChartType = .bar, dimensions: [BIDimension] = [],
                measures: [BIMeasure] = [], color: BIDimension? = nil, size: BIMeasure? = nil, filters: [BIFilter] = [],
                sort: BISort? = nil, topN: Int? = nil, title: String = "", showTitle: Bool = true, showLegend: Bool = true,
                showValues: Bool = false, palette: BIPalette = .standard, numberFormat: BINumberFormat = .automatic,
                xAxisTitle: String = "", yAxisTitle: String = "") {
        self.id = id
        self.name = name
        self.sourceID = sourceID
        self.type = type
        self.dimensions = dimensions
        self.measures = measures
        self.color = color
        self.size = size
        self.filters = filters
        self.sort = sort
        self.topN = topN
        self.title = title
        self.showTitle = showTitle
        self.showLegend = showLegend
        self.showValues = showValues
        self.palette = palette
        self.numberFormat = numberFormat
        self.xAxisTitle = xAxisTitle
        self.yAxisTitle = yAxisTitle
    }

    public var displayTitle: String { title.isEmpty ? name : title }

    /// The aggregation this chart needs, with extra filters (a dashboard's) applied on top of its own.
    /// Columns come out as: dimensions, then the colour dimension, then measures, then the size measure.
    public func spec(extraFilters: [BIFilter] = []) -> BIAggregateSpec {
        var dims = dimensions
        if let color, !dims.contains(color) { dims.append(color) }
        var values = measures
        if type == .scatter {
            // A scatter plots each group: X and Y are both measures.
            if let size { values.append(size) }
        }
        if values.isEmpty && type != .table { values = [BIMeasure(field: nil, aggregation: .count)] }
        let sort = self.sort ?? defaultSort(dimensionCount: dims.count, measureCount: values.count)
        let cap = type.pointCap
        let limit = topN.map { min($0, cap) } ?? cap
        return BIAggregateSpec(dimensions: dims, measures: values, filters: (filters + extraFilters).filter(\.isActive),
                               sort: sort, limit: limit)
    }

    private func defaultSort(dimensionCount: Int, measureCount: Int) -> BISort? {
        if dimensionCount == 0 { return nil }
        let isTime = dimensions.first?.bucket != nil
        switch type {
        case .pie, .donut, .horizontalBar where !isTime:
            return measureCount > 0 ? BISort(key: .measure(0), ascending: false) : nil
        case .bar where topN != nil && !isTime:
            return BISort(key: .measure(0), ascending: false)
        default:
            return BISort(key: .dimension(0), ascending: true)
        }
    }
}

/// A chart placed on a dashboard, in grid cells (12 columns wide).
public struct BIDashboardItem: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var chartID: UUID
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(id: UUID = UUID(), chartID: UUID, x: Int, y: Int, width: Int, height: Int) {
        self.id = id
        self.chartID = chartID
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct BIDashboard: Codable, Hashable, Sendable, Identifiable {
    public static let columns = 12

    public var id: UUID
    public var name: String
    public var items: [BIDashboardItem]
    /// Interactive filters: each applies to every chart whose source has the field.
    public var filters: [BIFilter]

    public init(id: UUID = UUID(), name: String, items: [BIDashboardItem] = [], filters: [BIFilter] = []) {
        self.id = id
        self.name = name
        self.items = items
        self.filters = filters
    }

    /// Where a new chart goes: the first gap of `width × height` scanning rows top to bottom.
    public func nextSlot(width: Int, height: Int) -> (x: Int, y: Int) {
        let w = min(width, Self.columns)
        var y = 0
        while true {
            for x in 0...(Self.columns - w) where !items.contains(where: { $0.overlaps(x: x, y: y, width: w, height: height) }) {
                return (x, y)
            }
            y += 1
        }
    }
}

extension BIDashboardItem {
    public func overlaps(x: Int, y: Int, width: Int, height: Int) -> Bool {
        x < self.x + self.width && self.x < x + width && y < self.y + self.height && self.y < y + height
    }
}

public struct BIWorkspace: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var sources: [BIDataSource]
    public var charts: [BIChart]
    public var dashboards: [BIDashboard]
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, sources: [BIDataSource] = [], charts: [BIChart] = [],
                dashboards: [BIDashboard] = [], updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sources = sources
        self.charts = charts
        self.dashboards = dashboards
        self.updatedAt = updatedAt
    }

    public func source(_ id: UUID?) -> BIDataSource? { sources.first { $0.id == id } }
    public func chart(_ id: UUID) -> BIChart? { charts.first { $0.id == id } }
}
