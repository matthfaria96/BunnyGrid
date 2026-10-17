import AppKit
import BunnyGridCore
import SwiftUI

/// Navicat's Query Builder: the database's tables on the left, a diagram of the tables in the query,
/// and below it the SELECT as grammar-style clauses you click to fill in, with the SQL it writes.
/// OK puts the SQL into the editor over the selection or the statement it was opened on.
struct QueryBuilderSheet: View {
    let query: QueryTabModel
    @State private var model: QueryBuilderModel
    @Environment(\.dismiss) private var dismiss

    init(query: QueryTabModel) {
        self.query = query
        _model = State(initialValue: QueryBuilderModel(query: query))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.parseError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.callout).lineLimit(2)
                    Spacer()
                    Text("OK inserts a new query at the cursor.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
                Divider()
            }
            HSplitView {
                objectList.frame(minWidth: 170, idealWidth: 200, maxWidth: 320)
                VSplitView {
                    QueryBuilderCanvas(model: model).frame(minHeight: 180, idealHeight: 300)
                    HSplitView {
                        // Vertical only: the clause chips wrap to the pane's width, as in Navicat's grammar editor.
                        ScrollView(.vertical) {
                            QueryBuilderClauses(model: model)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .defaultScrollAnchor(.topLeading)
                        .frame(minWidth: 320)
                        preview.frame(minWidth: 220, idealWidth: 320)
                    }
                    .frame(minHeight: 220, idealHeight: 340)
                }
            }
            Divider()
            HStack {
                Text("\(Self.count(model.query.tables.count, "table")), \(Self.count(model.query.joins.count, "join"))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    query.applyQueryBuilder(model.sql, range: model.target)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.query.tables.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 620, idealHeight: 760)
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    private var objectList: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $model.objectFilter)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List(model.filteredObjects, id: \.self) { object in
                Label(object.name, systemImage: object.kind == .view ? "eye" : "tablecells")
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.add(object) }
                    .onDrag { NSItemProvider(object: (QueryBuilderCanvasView.tableDragPrefix + object.name) as NSString) }
                    .help("Drag onto the diagram or double-click to add")
            }
            .listStyle(.sidebar)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SQL Preview").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.sql, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy SQL")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            // Long lines wrap instead of being clipped.
            ScrollView(.vertical) {
                Text(model.sql)
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// The SELECT … LIMIT clauses, each a keyword followed by clickable pieces, like Navicat's builder.
struct QueryBuilderClauses: View {
    @Bindable var model: QueryBuilderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            clause("SELECT") {
                Toggle("DISTINCT", isOn: $model.query.distinct).toggleStyle(.checkbox).font(.callout)
                ForEach(Array(model.query.columns.enumerated()), id: \.offset) { index, column in
                    columnChip(index, column)
                }
                addMenu("<Click here to add fields>") { table, column in
                    model.query.columns.append(BuilderColumn(tableID: table, column: column))
                    model.query.columns.removeAll { $0.tableID == table && $0.column == "*" && column != "*" && $0.aggregate == nil }
                } extra: {
                    Button("COUNT(*)") { model.query.columns.append(BuilderColumn(tableID: nil, column: "*", aggregate: .count)) }
                }
            }
            clause("FROM") {
                if model.query.tables.isEmpty { placeholder("<Drag tables onto the diagram>") }
                ForEach(model.query.tables) { table in
                    tableChip(table)
                }
                ForEach(model.query.joins) { join in
                    joinChip(join)
                }
            }
            clause("WHERE", flow: false) {
                ConditionGroupEditor(model: model, having: false, path: [])
            }
            clause("GROUP BY") {
                ForEach(Array(model.query.groupBy.enumerated()), id: \.offset) { index, operand in
                    chip(model.label(operand)) {
                        Button("Remove") { model.query.groupBy.remove(at: index) }
                    }
                }
                addMenu("<Click here to add fields>", includeStar: false) { table, column in
                    model.query.groupBy.append(.column(tableID: table, name: column))
                }
            }
            clause("HAVING", flow: false) {
                ConditionGroupEditor(model: model, having: true, path: [])
            }
            clause("ORDER BY") {
                ForEach(Array(model.query.orderBy.enumerated()), id: \.offset) { index, order in
                    chip(model.label(order.operand) + (order.descending ? " DESC" : " ASC")) {
                        Button("Ascending") { model.query.orderBy[index].descending = false }
                        Button("Descending") { model.query.orderBy[index].descending = true }
                        Divider()
                        Button("Remove") { model.query.orderBy.remove(at: index) }
                    }
                }
                addMenu("<Click here to add fields>", includeStar: false) { table, column in
                    model.query.orderBy.append(BuilderOrder(.column(tableID: table, name: column)))
                }
            }
            clause("LIMIT") {
                numberField("<Click here to set limit>", value: $model.query.limit)
                Text("OFFSET").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(.blue)
                numberField("<0>", value: $model.query.offset)
            }
        }
    }

    // MARK: Pieces

    private func clause<Content: View>(_ keyword: String, flow: Bool = true, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(keyword)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.blue)
                .frame(width: 76, height: 22, alignment: .leading)
                .fixedSize()
            Group {
                if flow {
                    QueryBuilderFlow(spacing: 6) { content() }
                } else {
                    content()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.tertiary)
    }

    private func chip<Items: View>(_ title: String, @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            Text(title).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help(title)
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.12)))
    }

    private func addMenu<Extra: View>(_ title: String, includeStar: Bool = true, add: @escaping (Int?, String) -> Void, @ViewBuilder extra: () -> Extra = { EmptyView() }) -> some View {
        Menu {
            ForEach(model.query.tables) { table in
                Menu(table.reference) {
                    if includeStar { Button("*") { add(table.id, "*") } }
                    ForEach(model.columnNames(table.id), id: \.self) { column in
                        Button(column) { add(table.id, column) }
                    }
                }
            }
            extra()
        } label: {
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.query.tables.isEmpty)
    }

    private func columnChip(_ index: Int, _ column: BuilderColumn) -> some View {
        let alias = column.alias.map { " AS \($0)" } ?? ""
        return chip(model.label(column.operand) + alias) {
            Menu("Function") {
                Button("None") { model.query.columns[index].aggregate = nil }
                ForEach(BuilderAggregate.allCases, id: \.self) { function in
                    Button(function.rawValue) { model.query.columns[index].aggregate = function }
                }
            }
            Button("Set Alias…") { promptAlias(for: index) }
            Divider()
            Button("Remove") { model.query.columns.remove(at: index) }
        }
    }

    private func tableChip(_ table: BuilderTable) -> some View {
        chip(table.alias.map { "\(table.name) AS \($0)" } ?? table.name) {
            Button("Set Alias…") {
                if let alias = QueryBuilderPrompt.ask("Alias for \(table.name)", value: table.alias ?? ""),
                   let index = model.query.tables.firstIndex(where: { $0.id == table.id }) {
                    model.query.tables[index].alias = alias.isEmpty ? nil : alias
                }
            }
            Button("Remove") { model.remove(table.id) }
        }
    }

    private func joinChip(_ join: BuilderJoin) -> some View {
        let left = model.query.table(join.leftTable)?.reference ?? "?", right = model.query.table(join.rightTable)?.reference ?? "?"
        let source = model.query.table(join.rightTable).map { t in t.alias.map { "\(t.name) AS \($0)" } ?? t.name } ?? right
        return chip("\(join.kind.rawValue) \(source) ON \(left).\(join.leftColumn) = \(right).\(join.rightColumn)") {
            ForEach(BuilderJoinKind.allCases, id: \.self) { kind in
                Button(kind.title) {
                    if let index = model.query.joins.firstIndex(of: join) { model.query.joins[index].kind = kind }
                }
                .disabled(kind == .full && (model.kind == .mysql || model.kind == .mariadb))
            }
            Divider()
            Button("Delete Join") { model.query.joins.removeAll { $0 == join } }
        }
    }

    private func promptAlias(for index: Int) {
        guard model.query.columns.indices.contains(index),
              let alias = QueryBuilderPrompt.ask("Alias for \(model.label(model.query.columns[index].operand))", value: model.query.columns[index].alias ?? "")
        else { return }
        model.query.columns[index].alias = alias.isEmpty ? nil : alias
    }

    private func numberField(_ prompt: String, value: Binding<Int?>) -> some View {
        TextField(prompt, text: Binding(
            get: { value.wrappedValue.map(String.init) ?? "" },
            set: { value.wrappedValue = Int($0.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 0 ? $0 : nil } }))
            .textFieldStyle(.roundedBorder)
            .frame(width: 110)
    }
}

/// One AND/OR group of WHERE or HAVING, with its conditions and nested groups.
struct ConditionGroupEditor: View {
    @Bindable var model: QueryBuilderModel
    let having: Bool
    let path: [Int]

    private var group: BuilderGroup {
        get { having ? model.query.having[group: path] : model.query.whereClause[group: path] }
    }

    private func update(_ change: (inout BuilderGroup) -> Void) {
        if having { change(&model.query.having[group: path]) } else { change(&model.query.whereClause[group: path]) }
    }

    var body: some View {
        let group = group
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(group.items.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 6) {
                    if index > 0 {
                        Menu(group.conjunction.rawValue) {
                            Button("AND") { update { $0.conjunction = .and } }
                            Button("OR") { update { $0.conjunction = .or } }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                    }
                    switch item {
                    case .predicate(let predicate):
                        PredicateEditor(model: model, having: having, predicate: predicate) { change in
                            update { g in
                                if case .predicate(var p) = g.items[index] { change(&p); g.items[index] = .predicate(p) }
                            }
                        } remove: {
                            update { $0.items.remove(at: index) }
                        }
                    case .group(let child):
                        HStack(alignment: .top, spacing: 4) {
                            Text(child.negated ? "NOT (" : "(").font(.system(size: 12, weight: .bold, design: .monospaced))
                            ConditionGroupEditor(model: model, having: having, path: path + [index])
                            Text(")").font(.system(size: 12, weight: .bold, design: .monospaced))
                            Menu {
                                Button(child.negated ? "Remove NOT" : "Negate (NOT)") {
                                    update { g in if case .group(var c) = g.items[index] { c.negated.toggle(); g.items[index] = .group(c) } }
                                }
                                Button("Remove Group") { update { $0.items.remove(at: index) } }
                            } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                        }
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.3)))
                    }
                }
            }
            HStack(spacing: 10) {
                Button(group.isEmpty && path.isEmpty ? "<Click here to add conditions>" : "+ Condition") {
                    update { $0.items.append(.predicate(newPredicate)) }
                }
                if !group.isEmpty {
                    Button("+ Group") {
                        update { $0.items.append(.group(BuilderGroup(conjunction: .or, items: [.predicate(newPredicate)]))) }
                    }
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize()
            .disabled(model.query.tables.isEmpty)
        }
    }

    private var newPredicate: BuilderPredicate {
        let first = model.allColumns.first
        let left: BuilderOperand = having
            ? .aggregate(.count, tableID: nil, column: "*")
            : .column(tableID: first?.table.id, name: first?.column ?? "")
        return BuilderPredicate(left: left, op: .equal, values: [.text("")])
    }
}

/// `<field> <operator> <value>` with menus for the field and operator and text fields for the values.
struct PredicateEditor: View {
    let model: QueryBuilderModel
    let having: Bool
    let predicate: BuilderPredicate
    let change: ((inout BuilderPredicate) -> Void) -> Void
    let remove: () -> Void

    var body: some View {
        // Wraps (field / operator / values / buttons) when the clause pane is narrow, like Navicat's grammar editor.
        QueryBuilderFlow(spacing: 6) {
            Menu(model.label(predicate.left)) {
                if having {
                    Button("COUNT(*)") { change { $0.left = .aggregate(.count, tableID: nil, column: "*") } }
                }
                ForEach(model.query.tables) { table in
                    Menu(table.reference) {
                        ForEach(model.columnNames(table.id), id: \.self) { column in
                            if having {
                                Menu(column) {
                                    ForEach(BuilderAggregate.allCases, id: \.self) { function in
                                        Button(function.rawValue) { change { $0.left = .aggregate(function, tableID: table.id, column: column) } }
                                    }
                                    Button("(no function)") { change { $0.left = .column(tableID: table.id, name: column) } }
                                }
                            } else {
                                Button(column) { change { $0.left = .column(tableID: table.id, name: column) } }
                            }
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.system(size: 12, design: .monospaced))

            Menu(predicate.op.rawValue) {
                ForEach(BuilderOperator.allCases, id: \.self) { op in
                    Button(op.rawValue) {
                        change { p in
                            p.op = op
                            let count = op.valueCount ?? max(1, p.values.count)
                            while p.values.count < count { p.values.append(.text("")) }
                            if p.values.count > count { p.values = Array(p.values.prefix(count)) }
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.system(size: 12, weight: .semibold, design: .monospaced))

            ForEach(Array(predicate.values.enumerated()), id: \.offset) { index, value in
                if index > 0 {
                    Text(predicate.op.valueCount == 2 ? "AND" : ",").font(.system(size: 12, weight: .bold, design: .monospaced))
                }
                TextField("<value>", text: Binding(
                    get: { Self.display(value) },
                    set: { text in change { $0.values[index] = BuilderOperand.value(text) } }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 120)
                    .help("Text, a number, NULL, or a parameter such as :name or ?")
            }
            if predicate.op.valueCount == nil {
                Button { change { $0.values.append(.text("")) } } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(.borderless)
                    .help("Add a value to the list")
            }
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove condition")
        }
    }

    static func display(_ operand: BuilderOperand) -> String {
        switch operand {
        case .text(let text): text
        case .number(let text), .parameter(let text): text
        case .null: "NULL"
        case .column(_, let name): name
        case .aggregate(let f, _, let c): "\(f.rawValue)(\(c))"
        }
    }
}

/// Lays pieces out left to right, wrapping to new lines.
struct QueryBuilderFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(bounds.width, subviews)
        for (subview, point) in zip(subviews, layout.points) {
            // A piece wider than the row (a long JOIN chip) is capped to it instead of running past the edge.
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                          proposal: ProposedViewSize(width: min(subview.sizeThatFits(.unspecified).width, bounds.width), height: nil))
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if width.isFinite, size.width > width { size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0, x + size.width > width {
                x = 0
                y += line + spacing
                line = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return (CGSize(width: min(widest, width.isFinite ? width : widest), height: y + line), points)
    }
}

/// A one-field text prompt (aliases).
@MainActor
enum QueryBuilderPrompt {
    static func ask(_ title: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespaces)
    }
}
