import Foundation

extension SQLDialect {
    /// An expression that truncates `column` (a date, timestamp or ISO date text) to the start of `bucket`,
    /// as `YYYY-MM-DD` text on every engine so charts and the in-memory engine see the same keys.
    /// Weeks start on Monday.
    public func dateBucket(_ column: String, _ bucket: BIDateBucket) -> String {
        switch kind {
        case .sqlite:
            switch bucket {
            case .day: return "strftime('%Y-%m-%d', \(column))"
            case .week: return "date(\(column), '-' || ((CAST(strftime('%w', \(column)) AS INTEGER) + 6) % 7) || ' days')"
            case .month: return "strftime('%Y-%m-01', \(column))"
            case .quarter:
                return "(strftime('%Y', \(column)) || '-' || printf('%02d', ((CAST(strftime('%m', \(column)) AS INTEGER) - 1) / 3) * 3 + 1) || '-01')"
            case .year: return "strftime('%Y-01-01', \(column))"
            }
        case .postgresql:
            return "to_char(date_trunc('\(bucket.rawValue)', CAST(\(column) AS timestamp)), 'YYYY-MM-DD')"
        case .mysql, .mariadb:
            switch bucket {
            case .day: return "DATE_FORMAT(\(column), '%Y-%m-%d')"
            case .week: return "DATE_FORMAT(DATE_SUB(\(column), INTERVAL WEEKDAY(\(column)) DAY), '%Y-%m-%d')"
            case .month: return "DATE_FORMAT(\(column), '%Y-%m-01')"
            case .quarter: return "CONCAT(YEAR(\(column)), '-', LPAD((QUARTER(\(column)) - 1) * 3 + 1, 2, '0'), '-01')"
            case .year: return "DATE_FORMAT(\(column), '%Y-01-01')"
            }
        case .mongodb, .redis:
            return column
        }
    }

    /// `SUM(x)`, `COUNT(DISTINCT x)`, `COUNT(*)`… Averages are taken over doubles so integer columns don't truncate.
    public func aggregate(_ measure: BIMeasure) -> String {
        guard let field = measure.field else { return "COUNT(*)" }
        let column = quoteIdentifier(field)
        switch measure.aggregation {
        case .sum: return "SUM(\(column))"
        case .avg:
            return kind == .postgresql ? "AVG(CAST(\(column) AS double precision))" : "AVG(\(column))"
        case .count: return "COUNT(\(column))"
        case .countDistinct: return "COUNT(DISTINCT \(column))"
        case .min: return "MIN(\(column))"
        case .max: return "MAX(\(column))"
        }
    }

    /// Whether GROUP BY can be pushed down to this engine.
    public var supportsBIPushdown: Bool {
        switch kind {
        case .sqlite, .postgresql, .mysql, .mariadb: true
        case .mongodb, .redis: false
        }
    }
}

/// Builds the aggregation statement for a chart: the source becomes a derived table, dimensions are grouped
/// (date buckets included), measures aggregated, filters become WHERE, then ORDER BY and LIMIT.
/// Output columns are named `d0, d1…` for dimensions and `m0, m1…` for measures.
public enum BIQueryBuilder {
    public static func sql(_ spec: BIAggregateSpec, source: String, dialect: SQLDialect) -> String {
        var select: [String] = []
        for (i, dim) in spec.dimensions.enumerated() {
            select.append("\(expression(dim, dialect)) AS \(dialect.quoteIdentifier("d\(i)"))")
        }
        for (i, measure) in spec.measures.enumerated() {
            select.append("\(dialect.aggregate(measure)) AS \(dialect.quoteIdentifier("m\(i)"))")
        }
        if select.isEmpty { select = ["COUNT(*) AS \(dialect.quoteIdentifier("m0"))"] }
        var sql = "SELECT \(select.joined(separator: ", ")) FROM (\(source)) AS bi_src"
        let conditions = spec.filters.filter(\.isActive).map { condition($0, dialect) }
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        if !spec.dimensions.isEmpty {
            sql += " GROUP BY " + spec.dimensions.indices.map { String($0 + 1) }.joined(separator: ", ")
        }
        if let sort = spec.sort {
            let position: Int? = switch sort.key {
            case .dimension(let i): spec.dimensions.indices.contains(i) ? i + 1 : nil
            case .measure(let i): spec.measures.indices.contains(i) ? spec.dimensions.count + i + 1 : nil
            }
            if let position { sql += " ORDER BY \(position) \(sort.ascending ? "ASC" : "DESC")" }
        }
        if let limit = spec.limit { sql += " LIMIT \(limit)" }
        return sql
    }

    /// The distinct values of one field (for a dashboard filter's value list), most frequent first.
    public static func distinctValues(field: String, source: String, dialect: SQLDialect, bucket: BIDateBucket? = nil, limit: Int = 200) -> String {
        let column = expression(BIDimension(field: field, bucket: bucket), dialect)
        return "SELECT \(column) AS v, COUNT(*) AS n FROM (\(source)) AS bi_src WHERE \(dialect.quoteIdentifier(field)) IS NOT NULL GROUP BY 1 ORDER BY 2 DESC, 1 LIMIT \(limit)"
    }

    /// A sample of the source to infer field types from.
    public static func sample(source: String, limit: Int = 200) -> String {
        "SELECT * FROM (\(source)) AS bi_src LIMIT \(limit)"
    }

    static func expression(_ dim: BIDimension, _ dialect: SQLDialect) -> String {
        let column = dialect.quoteIdentifier(dim.field)
        guard let bucket = dim.bucket else { return column }
        return dialect.dateBucket(column, bucket)
    }

    static func condition(_ filter: BIFilter, _ dialect: SQLDialect) -> String {
        let column = dialect.quoteIdentifier(filter.field)
        func literal(_ value: String) -> String {
            if filter.numeric, let number = Double(value), number.isFinite {
                return number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
            }
            return dialect.quoteLiteral(value)
        }
        let values = filter.values
        switch filter.op {
        case .isIn: return "\(column) IN (\(values.map(literal).joined(separator: ", ")))"
        case .notIn: return "(\(column) IS NULL OR \(column) NOT IN (\(values.map(literal).joined(separator: ", "))))"
        case .equals: return "\(column) = \(literal(values[0]))"
        case .notEquals: return "\(column) <> \(literal(values[0]))"
        case .greater: return "\(column) > \(literal(values[0]))"
        case .greaterOrEqual: return "\(column) >= \(literal(values[0]))"
        case .less: return "\(column) < \(literal(values[0]))"
        case .lessOrEqual: return "\(column) <= \(literal(values[0]))"
        case .between: return "\(column) BETWEEN \(literal(values[0])) AND \(literal(values[1]))"
        case .contains:
            let pattern = "%" + values[0].replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "_", with: "") + "%"
            let lhs = dialect.kind == .postgresql ? "CAST(\(column) AS text)" : column
            return dialect.kind == .postgresql ? "\(lhs) ILIKE \(dialect.quoteLiteral(pattern))" : "\(lhs) LIKE \(dialect.quoteLiteral(pattern))"
        }
    }
}
