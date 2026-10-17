import AppKit
import BunnyGridCore
import Charts
import SwiftUI
import UniformTypeIdentifiers

/// The BI workspace tab, laid out like Navicat BI: the workspace navigator and field list on the left, the chart
/// designer (shelves + canvas) or dashboard in the middle, and the chart properties on the right.
struct BIWorkspaceView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: BIWorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                BISidebar(model: model)
                    .frame(minWidth: 190, idealWidth: 210, maxWidth: 340)
                Group {
                    if let chart = model.selectedChart {
                        BIChartEditor(model: model, chart: chart)
                    } else if let board = model.selectedDashboard {
                        BIDashboardView(model: model, dashboard: board)
                    } else if case .source(let id)? = model.selection, let source = model.workspace.source(id) {
                        BISourceDetail(model: model, source: source)
                    } else {
                        ContentUnavailableView {
                            Label("BI Workspace", systemImage: "chart.pie")
                        } description: {
                            Text("Add a data source, then build charts and arrange them on a dashboard.")
                        } actions: {
                            Button("New Chart") { model.addChart() }.disabled(model.workspace.sources.isEmpty)
                            Button("New Dashboard") { model.addDashboard() }
                        }
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                if let chart = model.selectedChart {
                    BIPropertiesPane(model: model, chart: chart)
                        .frame(minWidth: 210, idealWidth: 230, maxWidth: 320)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            #if DEBUG
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--bi-export"), args.indices.contains(i + 1) {
                try? await Task.sleep(for: .seconds(2))
                try? BIExport.write(model: model, to: URL(fileURLWithPath: args[i + 1]))
            }
            #endif
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 2) {
            BIDataSourceMenu(model: model)
            ToolbarChip(title: "New Chart", systemImage: "chart.bar.xaxis", tint: .blue, isEnabled: !model.workspace.sources.isEmpty,
                        help: "Design a chart from a data source") { model.addChart() }
            ToolbarChip(title: "New Dashboard", systemImage: "rectangle.3.group", tint: .purple, help: "Arrange charts on a dashboard") {
                model.addDashboard()
            }
            Divider().frame(height: 16).padding(.horizontal, 6)
            ToolbarChip(title: "Refresh", systemImage: "arrow.clockwise", tint: .green, help: "Read the data sources again and redraw") {
                model.refreshAll()
            }
            Menu {
                Button("PNG Image…") { export(.png) }
                Button("PDF Document…") { export(.pdf) }
            } label: {
                ToolbarChip(title: "Export", systemImage: "square.and.arrow.up", tint: .orange, showsMenuIndicator: true)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .disabled(model.selectedChart == nil && model.selectedDashboard == nil)
            Spacer()
            if !model.loading.isEmpty { ProgressView().controlSize(.small).padding(.trailing, 6) }
            TextField("Workspace", text: $model.workspace.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }

    private func export(_ format: BIExport.Format) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .png ? .png : .pdf]
        let name = model.selectedChart?.displayTitle ?? model.selectedDashboard?.name ?? model.workspace.name
        panel.nameFieldStringValue = "\(name).\(format == .png ? "png" : "pdf")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try BIExport.write(model: model, to: url) } catch { NSAlert(error: error).runModal() }
    }
}

// MARK: - Data source menu

struct BIDataSourceMenu: View {
    @Environment(AppModel.self) private var app
    let model: BIWorkspaceModel
    @State private var customSQL: SQLDraft?

    struct SQLDraft: Identifiable {
        let id = UUID()
        var context: DatabaseContext
        var name = "Custom Query"
        var sql = "SELECT "
    }

    private var contexts: [DatabaseContext] {
        app.sessions.values.flatMap { $0.contexts.values }.filter { $0.isOpen && !$0.kind.isDocumentStore && $0.kind != .redis }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        Menu {
            if contexts.isEmpty { Text("Open a SQL connection first") }
            ForEach(contexts) { context in
                Menu("\(context.session?.config.name ?? "") · \(context.name)") {
                    Section("Tables and Views") {
                        ForEach((context.objects(in: context.defaultSchema) ?? []).filter { $0.kind == .table || $0.kind == .view }, id: \.self) { object in
                            Button(object.name) { add(object, context) }
                        }
                    }
                    if let id = context.session?.id {
                        let saved = app.savedQueries(connectionID: id, database: context.name)
                        if !saved.isEmpty {
                            Section("Saved Queries") {
                                ForEach(saved) { query in
                                    Button(query.name) {
                                        model.addSource(name: query.name, connectionID: id, database: context.name, schema: nil, table: nil, sql: query.sql)
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Custom SQL…") { customSQL = SQLDraft(context: context) }
                }
            }
        } label: {
            ToolbarChip(title: "Data Source", systemImage: "cylinder.split.1x2", tint: .teal, showsMenuIndicator: true)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .sheet(item: $customSQL) { draft in
            BICustomSQLSheet(draft: draft) { name, sql in
                guard let id = draft.context.session?.id else { return }
                model.selection = .source(model.addSource(name: name, connectionID: id, database: draft.context.name, schema: nil, table: nil, sql: sql))
            }
        }
    }

    private func add(_ object: DatabaseObject, _ context: DatabaseContext) {
        guard let id = context.session?.id else { return }
        let source = model.addSource(name: object.name, connectionID: id, database: context.name, schema: object.schema, table: object.name, sql: nil)
        model.selection = .source(source)
    }
}

struct BICustomSQLSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: BIDataSourceMenu.SQLDraft
    let done: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Data Source").font(.headline)
            TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder)
            TextEditor(text: $draft.sql)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Text("Any SELECT on \(draft.context.name). Charts group and filter on top of it.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { done(draft.name, draft.sql); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520)
    }
}

// MARK: - Sidebar

private extension BIFieldType {
    var systemImage: String {
        switch self {
        case .text: "textformat.abc"
        case .number: "number"
        case .date: "calendar"
        case .bool: "checkmark.square"
        }
    }
}

extension BIFieldRole {
    var tint: Color { self == .dimension ? Color(red: 0.16, green: 0.47, blue: 0.94) : Color(red: 0.18, green: 0.62, blue: 0.40) }
}

struct BISidebar: View {
    @Bindable var model: BIWorkspaceModel

    var body: some View {
        VSplitView {
            List(selection: $model.selection) {
                Section("Dashboards") {
                    ForEach(model.workspace.dashboards) { board in
                        Label(board.name, systemImage: "rectangle.3.group").tag(BIWorkspaceModel.Selection.dashboard(board.id))
                            .contextMenu { Button("Delete Dashboard", role: .destructive) { model.removeDashboard(board.id) } }
                    }
                }
                Section("Charts") {
                    ForEach(model.workspace.charts) { chart in
                        Label(chart.name, systemImage: chart.type.systemImage).tag(BIWorkspaceModel.Selection.chart(chart.id))
                            .draggable("bi-chart:\(chart.id.uuidString)")
                            .contextMenu {
                                Button("Duplicate") { model.duplicateChart(chart.id) }
                                Menu("Add to Dashboard") {
                                    ForEach(model.workspace.dashboards) { board in Button(board.name) { model.place(chart.id, on: board.id) } }
                                }
                                Divider()
                                Button("Delete Chart", role: .destructive) { model.removeChart(chart.id) }
                            }
                    }
                }
                Section("Data Sources") {
                    ForEach(model.workspace.sources) { source in
                        Label(source.name, systemImage: source.sql == nil ? "tablecells" : "doc.text.magnifyingglass")
                            .tag(BIWorkspaceModel.Selection.source(source.id))
                            .contextMenu { Button("Delete Data Source", role: .destructive) { model.removeSource(source.id) } }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minHeight: 160)
            if let chart = model.selectedChart {
                BIFieldList(model: model, chart: chart)
                    .frame(minHeight: 180)
            }
        }
    }
}

/// Dimensions and measures of the chart's source; drag one onto a shelf (or use its menu).
struct BIFieldList: View {
    let model: BIWorkspaceModel
    let chart: BIChart

    var body: some View {
        let fields = model.fields(of: chart)
        let source = model.workspace.source(chart.sourceID)
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                if fields.isEmpty {
                    Text(source == nil ? "Choose a data source in Properties." : "Reading fields…")
                        .font(.caption).foregroundStyle(.secondary).padding(8)
                }
                section("Dimensions", fields.filter { $0.role == .dimension }, source: source)
                section("Measures", [BIField(name: "Count of Rows", type: .number, role: .measure)] + fields.filter { $0.role == .measure },
                        source: source, countRow: true)
            }
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func section(_ title: String, _ fields: [BIField], source: BIDataSource?, countRow: Bool = false) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 3)
        ForEach(Array(fields.enumerated()), id: \.element.name) { index, field in
            let isCount = countRow && index == 0
            HStack(spacing: 6) {
                Image(systemName: isCount ? "number.circle" : field.type.systemImage)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(field.role.tint)
                    .frame(width: 16)
                Text(isCount ? "Count of Rows" : field.name).font(.system(size: 12)).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 3)
            .contentShape(Rectangle())
            .draggable(isCount ? "bi-count:" : "bi-field:\(field.name)") {
                BIPill(text: isCount ? "Count of Rows" : field.name, role: field.role).fixedSize()
            }
            .onTapGesture(count: 2) { add(field, isCount: isCount) }
            .contextMenu {
                Button("Add to Axis") { model.updateChart(chart.id) { $0.dimensions.append(dimension(field)) } }.disabled(isCount)
                Button("Add to Values") { model.updateChart(chart.id) { $0.measures.append(measure(field, isCount: isCount)) } }
                Button("Color by") { model.updateChart(chart.id) { $0.color = dimension(field) } }.disabled(isCount)
                Button("Filter") {
                    model.updateChart(chart.id) { $0.filters.append(BIFilter(field: field.name, op: field.type == .number ? .greater : .isIn, values: [], numeric: field.type == .number)) }
                }.disabled(isCount)
                if !isCount, let source {
                    Divider()
                    Button(field.role == .dimension ? "Convert to Measure" : "Convert to Dimension") {
                        model.setRole(field.role == .dimension ? .measure : .dimension, field: field.name, source: source.id)
                    }
                }
            }
        }
    }

    private func dimension(_ field: BIField) -> BIDimension {
        BIDimension(field: field.name, bucket: field.type == .date ? .month : nil)
    }

    private func measure(_ field: BIField, isCount: Bool) -> BIMeasure {
        isCount ? BIMeasure(field: nil, aggregation: .count)
            : BIMeasure(field: field.name, aggregation: field.type == .number ? .sum : .countDistinct)
    }

    private func add(_ field: BIField, isCount: Bool) {
        model.updateChart(chart.id) { chart in
            if field.role == .dimension && !isCount { chart.dimensions.append(dimension(field)) } else { chart.measures.append(measure(field, isCount: isCount)) }
        }
    }
}

struct BIPill: View {
    let text: String
    let role: BIFieldRole
    var showsChevron = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text).lineLimit(1)
            if showsChevron { Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).opacity(0.8) }
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 9).padding(.vertical, 3.5)
        .background(Capsule().fill(role.tint.gradient))
    }
}

// MARK: - Chart editor

struct BIChartEditor: View {
    let model: BIWorkspaceModel
    let chart: BIChart

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                shelf(chart.type == .scatter ? "Group By" : "Axis", systemImage: "arrow.left.and.right", items: chart.dimensions.indices.map { i in
                    AnyView(dimensionPill(chart.dimensions[i]) { c in c.dimensions.remove(at: i) } update: { c, d in c.dimensions[i] = d })
                }) { name, isCount in
                    guard !isCount else { return }
                    model.updateChart(chart.id) { $0.dimensions.append(dim(name)) }
                }
                Divider()
                shelf(chart.type == .scatter ? "X / Y" : "Values", systemImage: "arrow.up.and.down", items: chart.measures.indices.map { i in
                    AnyView(measurePill(chart.measures[i]) { c in c.measures.remove(at: i) } update: { c, m in c.measures[i] = m })
                }) { name, isCount in
                    model.updateChart(chart.id) { $0.measures.append(measure(name, isCount: isCount)) }
                }
                Divider()
                HStack(spacing: 0) {
                    shelf("Color", systemImage: "paintpalette", items: chart.color.map { color in
                        [AnyView(dimensionPill(color) { c in c.color = nil } update: { c, d in c.color = d })]
                    } ?? []) { name, isCount in
                        guard !isCount else { return }
                        model.updateChart(chart.id) { $0.color = dim(name) }
                    }
                    Divider()
                    shelf("Size", systemImage: "circle.circle", items: chart.size.map { size in
                        [AnyView(measurePill(size) { c in c.size = nil } update: { c, m in c.size = m })]
                    } ?? []) { name, isCount in
                        model.updateChart(chart.id) { $0.size = measure(name, isCount: isCount) }
                    }
                }
                .frame(height: 32)
                Divider()
                shelf("Filters", systemImage: "line.3.horizontal.decrease", items: chart.filters.indices.map { i in
                    AnyView(BIFilterChip(model: model, filter: chart.filters[i], fieldType: model.fieldType(chart.filters[i].field, in: chart)) { f in
                        model.updateChart(chart.id) { if let f { $0.filters[i] = f } else { $0.filters.remove(at: i) } }
                    })
                }) { name, isCount in
                    guard !isCount else { return }
                    let numeric = model.fieldType(name, in: chart) == .number
                    model.updateChart(chart.id) { $0.filters.append(BIFilter(field: name, op: numeric ? .greater : .isIn, values: [], numeric: numeric)) }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            BIChartCard(model: model, chart: chart, key: chart.id, compact: false)
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
        }
        .task(id: chart.id) {
            if model.results[chart.id] == nil { model.refreshChart(chart.id) }
        }
    }

    private func dim(_ name: String) -> BIDimension {
        BIDimension(field: name, bucket: model.fieldType(name, in: chart) == .date ? .month : nil)
    }

    private func measure(_ name: String, isCount: Bool) -> BIMeasure {
        if isCount { return BIMeasure(field: nil, aggregation: .count) }
        return BIMeasure(field: name, aggregation: model.fieldType(name, in: chart) == .number ? .sum : .countDistinct)
    }

    private func shelf(_ title: String, systemImage: String, items: [AnyView], drop: @escaping (String, Bool) -> Void) -> some View {
        BIShelf(title: title, systemImage: systemImage, items: items, drop: drop)
    }

    private func dimensionPill(_ d: BIDimension, remove: @escaping (inout BIChart) -> Void, update: @escaping (inout BIChart, BIDimension) -> Void) -> some View {
        Menu {
            if model.fieldType(d.field, in: chart) == .date {
                Picker("Date Grouping", selection: Binding(get: { d.bucket }, set: { b in model.updateChart(chart.id) { update(&$0, BIDimension(field: d.field, bucket: b)) } })) {
                    Text("Exact Value").tag(BIDateBucket?.none)
                    ForEach(BIDateBucket.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
                .pickerStyle(.inline)
                Divider()
            }
            Button("Sort Ascending") { model.updateChart(chart.id) { $0.sort = BISort(key: .dimension(0), ascending: true) } }
            Button("Sort Descending") { model.updateChart(chart.id) { $0.sort = BISort(key: .dimension(0), ascending: false) } }
            Divider()
            Button("Remove", role: .destructive) { model.updateChart(chart.id) { remove(&$0) } }
        } label: {
            BIPill(text: d.label, role: .dimension, showsChevron: true)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private func measurePill(_ m: BIMeasure, remove: @escaping (inout BIChart) -> Void, update: @escaping (inout BIChart, BIMeasure) -> Void) -> some View {
        Menu {
            if m.field != nil {
                Picker("Aggregation", selection: Binding(get: { m.aggregation }, set: { a in model.updateChart(chart.id) { update(&$0, BIMeasure(field: m.field, aggregation: a)) } })) {
                    ForEach(BIAggregation.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
            }
            Button("Sort Largest First") { model.updateChart(chart.id) { $0.sort = BISort(key: .measure(0), ascending: false) } }
            Button("Sort Smallest First") { model.updateChart(chart.id) { $0.sort = BISort(key: .measure(0), ascending: true) } }
            Divider()
            Button("Remove", role: .destructive) { model.updateChart(chart.id) { remove(&$0) } }
        } label: {
            BIPill(text: m.label, role: .measure, showsChevron: true)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

/// A drop target row of the chart designer ("Axis", "Values", "Color"…).
struct BIShelf: View {
    let title: String
    let systemImage: String
    let items: [AnyView]
    let drop: (String, Bool) -> Void
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(items.indices, id: \.self) { items[$0] }
                    if items.isEmpty {
                        Text("Drop fields here").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(isTargeted ? Color.accentColor.opacity(0.12) : .clear)
        .overlay {
            if isTargeted { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])).padding(2) }
        }
        .animation(.easeOut(duration: 0.12), value: isTargeted)
        .dropDestination(for: String.self) { payloads, _ in
            var accepted = false
            for payload in payloads {
                if payload.hasPrefix("bi-field:") { drop(String(payload.dropFirst(9)), false); accepted = true }
                if payload == "bi-count:" { drop("", true); accepted = true }
            }
            return accepted
        } isTargeted: { isTargeted = $0 }
    }
}

/// A filter on a shelf or a dashboard: a value list for text/date dimensions, a comparison for numbers.
struct BIFilterChip: View {
    let model: BIWorkspaceModel
    let filter: BIFilter
    let fieldType: BIFieldType
    let change: (BIFilter?) -> Void
    @State private var showing = false

    private var summary: String {
        guard filter.isActive else { return "\(filter.field): All" }
        switch filter.op {
        case .isIn, .notIn:
            let list = filter.values.prefix(2).joined(separator: ", ") + (filter.values.count > 2 ? " +\(filter.values.count - 2)" : "")
            return "\(filter.field)\(filter.op == .notIn ? " ≠" : ":") \(list)"
        case .between: return "\(filter.field): \(filter.values[0])–\(filter.values[1])"
        default: return "\(filter.field) \(filter.op.title) \(filter.values[0])"
        }
    }

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill").font(.system(size: 10.5))
                Text(summary).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).opacity(0.7)
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 9).padding(.vertical, 3.5)
            .background(Capsule().fill(filter.isActive ? Color.orange.opacity(0.18) : Color.primary.opacity(0.07)))
            .overlay(Capsule().strokeBorder(filter.isActive ? Color.orange.opacity(0.6) : Color.primary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            BIFilterEditor(model: model, filter: filter, fieldType: fieldType, change: change)
        }
    }
}

struct BIFilterEditor: View {
    let model: BIWorkspaceModel
    @State var filter: BIFilter
    let fieldType: BIFieldType
    let change: (BIFilter?) -> Void
    @State private var values: [String]?
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(filter.field).font(.headline)
                Spacer()
                Button("Remove", role: .destructive) { change(nil) }.controlSize(.small)
            }
            if fieldType == .number {
                Picker("Condition", selection: $filter.op) {
                    ForEach([BIFilter.Operator.greater, .greaterOrEqual, .less, .lessOrEqual, .equals, .notEquals, .between], id: \.self) { Text($0.title).tag($0) }
                }
                HStack {
                    TextField("Value", text: binding(0)).textFieldStyle(.roundedBorder)
                    if filter.op == .between { Text("and"); TextField("Value", text: binding(1)).textFieldStyle(.roundedBorder) }
                }
                Button("Apply") { filter.numeric = true; change(filter) }.keyboardShortcut(.defaultAction)
            } else {
                Picker("", selection: $filter.op) {
                    Text("Include").tag(BIFilter.Operator.isIn)
                    Text("Exclude").tag(BIFilter.Operator.notIn)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: filter.op) { change(filter) }
                TextField("Search", text: $search).textFieldStyle(.roundedBorder)
                if let values {
                    List {
                        ForEach(values.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { value in
                            Toggle(isOn: Binding(get: { filter.values.contains(value) }, set: { on in
                                if on { filter.values.append(value) } else { filter.values.removeAll { $0 == value } }
                                change(filter)
                            })) { Text(value).lineLimit(1) }
                        }
                    }
                    .listStyle(.plain)
                    .frame(height: 200)
                    HStack {
                        Button("All") { filter.values = []; change(filter) }
                        Spacer()
                        Text("\(filter.values.count) selected").font(.caption).foregroundStyle(.secondary)
                    }
                    .controlSize(.small)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
                }
            }
        }
        .padding(12)
        .frame(width: 260)
        .task { if fieldType != .number { values = await model.values(for: filter.field) } }
    }

    private func binding(_ i: Int) -> Binding<String> {
        Binding(get: { filter.values.indices.contains(i) ? filter.values[i] : "" }, set: { v in
            while filter.values.count <= i { filter.values.append("") }
            filter.values[i] = v
            filter.values = filter.op == .between ? Array(filter.values.prefix(2)) : Array(filter.values.prefix(1))
        })
    }
}

/// A chart with its title and status, as a card (editor canvas and dashboard tiles).
struct BIChartCard<Header: View>: View {
    let model: BIWorkspaceModel
    let chart: BIChart
    let key: UUID
    let compact: Bool
    @ViewBuilder var header: () -> Header

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack(spacing: 6) {
                if chart.showTitle {
                    Text(chart.displayTitle).font(.system(size: compact ? 12.5 : 15, weight: .semibold)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if model.loading.contains(key) { ProgressView().controlSize(.mini) }
                header()
            }
            ZStack {
                if let error = model.errors[key] {
                    ContentUnavailableView {
                        Label("Can't Draw This Chart", systemImage: "exclamationmark.triangle")
                    } description: { Text(error).font(.caption) }
                } else if model.results[key] == nil {
                    ProgressView().controlSize(.small)
                } else {
                    BIChartView(chart: chart, result: model.results[key], compact: compact)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !compact, let result = model.results[key] {
                HStack(spacing: 6) {
                    Image(systemName: result.statement == nil ? "memorychip" : "bolt.horizontal.circle")
                    Text("\(result.rows.count) group(s)\(result.rows.count >= chart.spec().limit ?? .max ? " (capped)" : "") · \(result.statement == nil ? "aggregated in memory" : "aggregated by the database") · \(result.duration.formatted(.units(allowed: [.milliseconds])))")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .help(result.statement ?? "")
            }
        }
        .padding(compact ? 10 : 16)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.09)))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }
}

extension BIChartCard where Header == EmptyView {
    init(model: BIWorkspaceModel, chart: BIChart, key: UUID, compact: Bool) {
        self.init(model: model, chart: chart, key: key, compact: compact) { EmptyView() }
    }
}

// MARK: - Properties

struct BIPropertiesPane: View {
    let model: BIWorkspaceModel
    let chart: BIChart

    private func bind<T>(_ path: WritableKeyPath<BIChart, T>) -> Binding<T> {
        Binding(get: { chart[keyPath: path] }, set: { value in model.updateChart(chart.id) { $0[keyPath: path] = value } })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                group("Chart Type") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                        ForEach(BIChartType.allCases, id: \.self) { type in
                            Button {
                                withAnimation(.smooth) { model.updateChart(chart.id) { $0.type = type } }
                            } label: {
                                Image(systemName: type.systemImage)
                                    .font(.system(size: 15))
                                    .frame(maxWidth: .infinity, minHeight: 34)
                                    .foregroundStyle(chart.type == type ? Color.white : Color.primary.opacity(0.75))
                                    .background(RoundedRectangle(cornerRadius: 6).fill(chart.type == type ? Color.accentColor : Color.primary.opacity(0.06)))
                            }
                            .buttonStyle(.plain)
                            .help(type.title)
                        }
                    }
                    Text(chart.type.title).font(.caption).foregroundStyle(.secondary)
                }
                group("Data") {
                    row("Name") { TextField("", text: bind(\.name)).textFieldStyle(.roundedBorder) }
                    row("Source") {
                        Picker("", selection: bind(\.sourceID)) {
                            Text("None").tag(UUID?.none)
                            ForEach(model.workspace.sources) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .labelsHidden()
                    }
                    row("Top N") {
                        TextField("All", value: bind(\.topN), format: .number).textFieldStyle(.roundedBorder)
                    }
                    row("Sort") {
                        Picker("", selection: bind(\.sort)) {
                            Text("Automatic").tag(BISort?.none)
                            Text("Axis ↑").tag(Optional(BISort(key: .dimension(0), ascending: true)))
                            Text("Axis ↓").tag(Optional(BISort(key: .dimension(0), ascending: false)))
                            Text("Value ↑").tag(Optional(BISort(key: .measure(0), ascending: true)))
                            Text("Value ↓").tag(Optional(BISort(key: .measure(0), ascending: false)))
                        }
                        .labelsHidden()
                    }
                }
                group("Appearance") {
                    row("Title") { TextField(chart.name, text: bind(\.title)).textFieldStyle(.roundedBorder) }
                    Toggle("Show Title", isOn: bind(\.showTitle))
                    Toggle("Show Legend", isOn: bind(\.showLegend))
                    Toggle("Show Values", isOn: bind(\.showValues))
                    row("Colors") {
                        Picker("", selection: bind(\.palette)) {
                            ForEach(BIPalette.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                    }
                    HStack(spacing: 3) {
                        ForEach(Array(chart.palette.colors.prefix(8).enumerated()), id: \.offset) { RoundedRectangle(cornerRadius: 2).fill($0.element).frame(height: 10) }
                    }
                }
                group("Axes") {
                    row("X Title") { TextField("Automatic", text: bind(\.xAxisTitle)).textFieldStyle(.roundedBorder) }
                    row("Y Title") { TextField("Automatic", text: bind(\.yAxisTitle)).textFieldStyle(.roundedBorder) }
                    row("Format") {
                        Picker("", selection: bind(\.numberFormat)) {
                            ForEach(BINumberFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                    }
                }
                if !model.workspace.dashboards.isEmpty {
                    group("Dashboard") {
                        Menu("Add to Dashboard") {
                            ForEach(model.workspace.dashboards) { board in Button(board.name) { model.place(chart.id, on: board.id) } }
                        }
                    }
                }
            }
            .padding(12)
            .controlSize(.small)
            .font(.system(size: 12))
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            content()
        }
    }
}

// MARK: - Data source detail

struct BISourceDetail: View {
    let model: BIWorkspaceModel
    let source: BIDataSource

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(source.name, systemImage: source.sql == nil ? "tablecells" : "doc.text.magnifyingglass").font(.title3.weight(.semibold))
                Spacer()
                Button("Reload Fields") { Task { await model.loadFields(source.id) } }
                Button("New Chart") { model.addChart(sourceID: source.id) }.buttonStyle(.borderedProminent)
            }
            Text(source.sql ?? "Table \(source.schema.map { "\($0)." } ?? "")\(source.table ?? "") on \(source.database)")
                .font(.system(size: 12, design: source.sql == nil ? .default : .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Table(source.fields) {
                TableColumn("Field") { Label($0.name, systemImage: $0.type.systemImage).foregroundStyle(.primary) }
                TableColumn("Type") { Text($0.type.rawValue.capitalized) }
                TableColumn("Role") { field in
                    Picker("", selection: Binding(get: { field.role }, set: { model.setRole($0, field: field.name, source: source.id) })) {
                        Text("Dimension").tag(BIFieldRole.dimension)
                        Text("Measure").tag(BIFieldRole.measure)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
            }
        }
        .padding(16)
        .task(id: source.id) { if source.fields.isEmpty { await model.loadFields(source.id) } }
    }
}

// MARK: - Export

enum BIExport {
    enum Format { case png, pdf }

    @MainActor
    static func write(model: BIWorkspaceModel, to url: URL) throws {
        let format: Format = url.pathExtension.lowercased() == "pdf" ? .pdf : .png
        let content: AnyView
        if let board = model.selectedDashboard {
            let size = BIDashboardLayout.contentSize(board, width: 1280)
            content = AnyView(BIDashboardCanvas(model: model, dashboard: board, width: 1280, interactive: false)
                .frame(width: 1280, height: size.height, alignment: .topLeading).padding(20))
        } else if let chart = model.selectedChart {
            content = AnyView(BIChartCard(model: model, chart: chart, key: chart.id, compact: false).frame(width: 960, height: 600).padding(20))
        } else {
            return
        }
        let renderer = ImageRenderer(content: content.background(Color(nsColor: .underPageBackgroundColor)).environment(\.colorScheme, .light))
        switch format {
        case .png:
            renderer.scale = 2
            guard let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: url, options: .atomic)
        case .pdf:
            var failed = false
            renderer.render { size, draw in
                var box = CGRect(origin: .zero, size: size)
                guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { failed = true; return }
                pdf.beginPDFPage(nil)
                draw(pdf)
                pdf.endPDFPage()
                pdf.closePDF()
            }
            if failed { throw CocoaError(.fileWriteUnknown) }
        }
    }
}
