import BunnyGridCore
import Charts
import SwiftUI

extension BIPalette {
    var colors: [Color] {
        switch self {
        case .standard:
            [Color(red: 0.16, green: 0.47, blue: 0.94), Color(red: 0.98, green: 0.58, blue: 0.13), Color(red: 0.20, green: 0.70, blue: 0.45),
             Color(red: 0.89, green: 0.27, blue: 0.36), Color(red: 0.55, green: 0.38, blue: 0.86), Color(red: 0.11, green: 0.69, blue: 0.78),
             Color(red: 0.93, green: 0.76, blue: 0.16), Color(red: 0.55, green: 0.55, blue: 0.60)]
        case .ocean:
            [Color(red: 0.05, green: 0.33, blue: 0.62), Color(red: 0.13, green: 0.55, blue: 0.80), Color(red: 0.36, green: 0.74, blue: 0.86),
             Color(red: 0.10, green: 0.62, blue: 0.60), Color(red: 0.55, green: 0.82, blue: 0.78), Color(red: 0.30, green: 0.40, blue: 0.75)]
        case .sunset:
            [Color(red: 0.95, green: 0.40, blue: 0.20), Color(red: 0.98, green: 0.65, blue: 0.20), Color(red: 0.85, green: 0.22, blue: 0.40),
             Color(red: 0.60, green: 0.20, blue: 0.50), Color(red: 0.99, green: 0.82, blue: 0.40), Color(red: 0.40, green: 0.15, blue: 0.40)]
        case .forest:
            [Color(red: 0.13, green: 0.55, blue: 0.33), Color(red: 0.45, green: 0.70, blue: 0.30), Color(red: 0.70, green: 0.80, blue: 0.35),
             Color(red: 0.25, green: 0.45, blue: 0.40), Color(red: 0.55, green: 0.45, blue: 0.25), Color(red: 0.35, green: 0.65, blue: 0.60)]
        case .mono:
            [Color(white: 0.25), Color(white: 0.45), Color(white: 0.6), Color(white: 0.72), Color(white: 0.82), Color(white: 0.35)]
        }
    }

    var title: String { rawValue.capitalized }
}

/// Formats a dimension key for display: bucketed dates read "Jan 2025", "Q1 2025", "2025", "Mar 3".
enum BIKeyFormat {
    static func label(_ key: String, bucket: BIDateBucket?) -> String {
        guard let bucket, key.count >= 10 else { return key }
        let parts = key.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return key }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .current
        let months = calendar.shortMonthSymbols
        let month = months[max(0, min(11, parts[1] - 1))]
        switch bucket {
        case .year: return "\(parts[0])"
        case .quarter: return "Q\((parts[1] - 1) / 3 + 1) \(parts[0])"
        case .month: return "\(month) \(parts[0])"
        case .week, .day: return "\(month) \(parts[2]), \(String(parts[0]).suffix(2))"
        }
    }
}

/// One plotted point: x category, optional series, values.
struct BIPoint: Identifiable, Hashable {
    let id: Int
    let x: String
    let series: String
    let y: Double
    let y2: Double
    let size: Double
}

/// Draws a chart from its aggregated rows with Swift Charts. Rows are already grouped and capped by the engine,
/// so this view only maps them to marks; changes animate.
struct BIChartView: View {
    let chart: BIChart
    let result: BIResult?
    var compact = false

    private var hasSeries: Bool { chart.dimensions.count > 1 || chart.color != nil }

    private var points: [BIPoint] {
        guard let result else { return [] }
        let xBucket = chart.dimensions.first?.bucket
        let seriesBucket = chart.color?.bucket ?? (chart.dimensions.count > 1 ? chart.dimensions[1].bucket : nil)
        return result.rows.enumerated().map { i, row in
            BIPoint(id: i,
                    x: row.keys.first.map { BIKeyFormat.label($0, bucket: xBucket) } ?? chart.measures.first?.label ?? "",
                    series: row.keys.count > 1 ? BIKeyFormat.label(row.keys[1], bucket: seriesBucket) : "",
                    y: row.values.first.flatMap { $0 } ?? 0,
                    y2: row.values.count > 1 ? row.values[1] ?? 0 : 0,
                    size: row.values.count > 2 ? row.values[2] ?? 1 : 1)
        }
    }

    private var xTitle: String { chart.xAxisTitle.isEmpty ? (chart.dimensions.first?.label ?? "") : chart.xAxisTitle }
    private var yTitle: String {
        chart.yAxisTitle.isEmpty ? (chart.measures.first?.label ?? BIMeasure(field: nil, aggregation: .count).label) : chart.yAxisTitle
    }

    var body: some View {
        Group {
            if let result, result.rows.isEmpty {
                ContentUnavailableView("No Data", systemImage: "chart.bar.xaxis", description: Text("No rows match the filters."))
            } else {
                switch chart.type {
                case .kpi: kpi
                case .table: BIPivotView(chart: chart, result: result)
                case .pie, .donut: pie
                case .heatmap: heatmap
                case .scatter: scatter
                default: cartesian
                }
            }
        }
        .animation(.smooth(duration: 0.35), value: result)
        .animation(.smooth(duration: 0.35), value: chart.type)
    }

    private var palette: [Color] { chart.palette.colors }

    private func format(_ value: Double) -> String { chart.numberFormat.format(value) }

    // MARK: Cartesian

    private var cartesian: some View {
        let points = points
        let series = hasSeries
        return Chart(points) { point in
            switch chart.type {
            case .line:
                LineMark(x: .value(xTitle, point.x), y: .value(yTitle, point.y))
                    .foregroundStyle(by: .value("Series", series ? point.series : yTitle))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.2))
                if points.count <= 60 {
                    PointMark(x: .value(xTitle, point.x), y: .value(yTitle, point.y))
                        .foregroundStyle(by: .value("Series", series ? point.series : yTitle))
                        .symbolSize(compact ? 14 : 22)
                }
            case .area:
                AreaMark(x: .value(xTitle, point.x), y: .value(yTitle, point.y), stacking: .standard)
                    .foregroundStyle(by: .value("Series", series ? point.series : yTitle))
                    .interpolationMethod(.monotone)
                    .opacity(0.85)
            case .horizontalBar:
                BarMark(x: .value(yTitle, point.y), y: .value(xTitle, point.x))
                    .foregroundStyle(by: .value("Series", series ? point.series : yTitle))
                    .cornerRadius(3)
                    .annotation(position: .trailing, alignment: .leading) {
                        if chart.showValues { valueLabel(point.y) }
                    }
            case .bar where series:
                BarMark(x: .value(xTitle, point.x), y: .value(yTitle, point.y))
                    .foregroundStyle(by: .value("Series", point.series))
                    .position(by: .value("Series", point.series))
                    .cornerRadius(3)
            default:
                BarMark(x: .value(xTitle, point.x), y: .value(yTitle, point.y))
                    .foregroundStyle(by: .value("Series", series ? point.series : yTitle))
                    .cornerRadius(3)
                    .annotation(position: .top) {
                        if chart.showValues && !series { valueLabel(point.y) }
                    }
            }
        }
        .chartForegroundStyleScale(range: palette)
        .chartLegend(chart.showLegend && series ? .visible : .hidden)
        .chartLegend(position: .top, alignment: .leading)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel {
                    if let number = value.as(Double.self) { Text(format(number)) } else if let text = value.as(String.self) { Text(text) }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel(collisionResolution: .greedy) {
                    if let number = value.as(Double.self) { Text(format(number)) } else if let text = value.as(String.self) { Text(text) }
                }
            }
        }
        .chartXAxisLabel(compact ? "" : (chart.type == .horizontalBar ? yTitle : xTitle))
        .chartYAxisLabel(compact ? "" : (chart.type == .horizontalBar ? xTitle : yTitle))
        .font(.system(size: 10.5))
    }

    private func valueLabel(_ value: Double) -> some View {
        Text(format(value)).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
    }

    // MARK: Pie

    private var pie: some View {
        let points = points
        let total = points.reduce(0) { $0 + $1.y }
        return Chart(points) { point in
            SectorMark(angle: .value(yTitle, point.y), innerRadius: .ratio(chart.type == .donut ? 0.58 : 0), angularInset: 1.2)
                .cornerRadius(3)
                .foregroundStyle(by: .value(xTitle, point.x))
                .annotation(position: .overlay) {
                    if chart.showValues || !compact, total > 0, point.y / total > 0.06 {
                        Text((point.y / total).formatted(.percent.precision(.fractionLength(0))))
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                    }
                }
        }
        .chartForegroundStyleScale(range: palette)
        .chartLegend(chart.showLegend ? .visible : .hidden)
        .chartLegend(position: compact ? .bottom : .trailing, alignment: .center)
        .chartBackground { proxy in
            GeometryReader { geo in
                if chart.type == .donut, let frame = proxy.plotFrame {
                    let rect = geo[frame]
                    VStack(spacing: 0) {
                        Text(format(total)).font(.system(size: compact ? 15 : 20, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("Total").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }

    // MARK: Scatter

    private var scatter: some View {
        let xLabel = chart.measures.first?.label ?? "X"
        let yLabel = chart.measures.count > 1 ? chart.measures[1].label : "Y"
        let hasSize = chart.size != nil
        return Chart(points) { point in
            PointMark(x: .value(xLabel, point.y), y: .value(yLabel, point.y2))
                .foregroundStyle(by: .value("Series", hasSeries ? point.series : point.x))
                .symbolSize(by: .value("Size", hasSize ? point.size : 1))
                .opacity(0.8)
        }
        .chartForegroundStyleScale(range: palette)
        .chartSymbolSizeScale(range: hasSize ? 20...400 : 40...40)
        .chartLegend(chart.showLegend && hasSeries ? .visible : .hidden)
        .chartXAxisLabel(compact ? "" : xLabel)
        .chartYAxisLabel(compact ? "" : yLabel)
        .font(.system(size: 10.5))
    }

    // MARK: Heatmap

    private var heatmap: some View {
        let points = points
        let colors = palette
        return Chart(points) { point in
            RectangleMark(x: .value(xTitle, point.x), y: .value(chart.dimensions.count > 1 ? chart.dimensions[1].label : "", point.series), width: .ratio(1), height: .ratio(1))
                .foregroundStyle(by: .value(yTitle, point.y))
                .annotation(position: .overlay) {
                    if chart.showValues || !compact { Text(format(point.y)).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white) }
                }
        }
        .chartForegroundStyleScale(range: Gradient(colors: [colors[0].opacity(0.25), colors[0]]))
        .chartLegend(chart.showLegend ? .visible : .hidden)
        .font(.system(size: 10.5))
    }

    // MARK: KPI

    private var kpi: some View {
        let value = result?.rows.first?.values.first.flatMap { $0 }
        return VStack(spacing: 4) {
            Text(value.map(format) ?? "—")
                .font(.system(size: compact ? 30 : 46, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(palette[0])
                .contentTransition(.numericText())
                .minimumScaleFactor(0.4)
                .lineLimit(1)
            Text(chart.measures.first?.label ?? "Count of Rows")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Table / pivot: with two dimensions, the second becomes columns.
struct BIPivotView: View {
    let chart: BIChart
    let result: BIResult?

    var body: some View {
        let rows = result?.rows ?? []
        let pivot = chart.dimensions.count >= 2
        let rowKeys = ordered(rows.map { $0.keys.first ?? "" })
        let colKeys = pivot ? ordered(rows.map { $0.keys.count > 1 ? $0.keys[1] : "" }) : []
        var cells: [String: Double] = [:]
        for row in rows {
            cells[(row.keys.first ?? "") + "\u{1}" + (pivot && row.keys.count > 1 ? row.keys[1] : "")] = row.values.first ?? nil
        }
        let measureTitles = chart.measures.isEmpty ? [BIMeasure(field: nil, aggregation: .count).label] : chart.measures.map(\.label)
        let headers = pivot ? colKeys.map { BIKeyFormat.label($0, bucket: chart.dimensions[1].bucket) } + ["Total"] : measureTitles
        let width: CGFloat = 96
        return ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    header(chart.dimensions.first?.label ?? "", width: 130, leading: true)
                    ForEach(Array(headers.enumerated()), id: \.offset) { header($0.element, width: width, leading: false) }
                }
                ForEach(Array(rowKeys.enumerated()), id: \.offset) { index, key in
                    GridRow {
                        cell(BIKeyFormat.label(key, bucket: chart.dimensions.first?.bucket), width: 130, leading: true, bold: true)
                        if pivot {
                            let values = colKeys.map { cells[key + "\u{1}" + $0] }
                            ForEach(Array(values.enumerated()), id: \.offset) { cell($0.element.map(chart.numberFormat.format) ?? "", width: width) }
                            cell(chart.numberFormat.format(values.compactMap { $0 }.reduce(0, +)), width: width, bold: true)
                        } else if let row = rows.first(where: { ($0.keys.first ?? "") == key }) {
                            ForEach(Array(row.values.enumerated()), id: \.offset) { cell($0.element.map(chart.numberFormat.format) ?? "", width: width) }
                        }
                    }
                    .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035))
                }
            }
            .font(.system(size: 11.5))
        }
    }

    private func ordered(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    private func header(_ text: String, width: CGFloat, leading: Bool) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            .frame(width: width, alignment: leading ? .leading : .trailing)
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(Color.primary.opacity(0.06))
    }

    private func cell(_ text: String, width: CGFloat, leading: Bool = false, bold: Bool = false) -> some View {
        Text(text).fontWeight(bold ? .medium : .regular).monospacedDigit().lineLimit(1)
            .frame(width: width, alignment: leading ? .leading : .trailing)
            .padding(.horizontal, 6).padding(.vertical, 4)
    }
}
