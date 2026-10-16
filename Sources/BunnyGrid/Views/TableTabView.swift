import BunnyGridCore
import SwiftUI

struct TableTabView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: TableTabModel
    @State private var showingColumns = false
    @State private var showingSQLPreview = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.showFilterBar {
                FilterSortBar(model: model)
                Divider()
            }
            if model.mode == .structure {
                StructureView(columns: model.columns, indexes: model.indexes)
            } else {
                HSplitView {
                    VSplitView {
                        dataArea
                            .frame(minHeight: 120)
                        if model.showHistory {
                            HistoryPanel(model: model)
                                .frame(minHeight: 80, idealHeight: 140, maxHeight: 400)
                        }
                    }
                    .frame(minWidth: 300)
                    if model.showCellEditor {
                        CellEditorPanel(model: model)
                            .frame(minWidth: 220, idealWidth: 280, maxWidth: 520)
                    }
                }
                Divider()
                GridFooter(model: model, showingSQLPreview: $showingSQLPreview)
            }
        }
        .task { await model.loadIfNeeded() }
        .alert("Changes Not Saved", isPresented: Binding(
            get: { model.saveError != nil },
            set: { if !$0 { model.saveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.saveError ?? "")
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(alignment: .top, spacing: 8) {
            FlowLayout(spacing: 12, lineSpacing: 4) {
                ToolbarChip(title: "Table Profile", systemImage: "tablecells.badge.ellipsis", tint: .blue, isEnabled: false, showsMenuIndicator: true) {}
                if model.isInTransaction {
                    ToolbarChip(title: "Commit", systemImage: "checkmark.seal.fill", tint: .green, help: "Apply pending edits and commit the transaction") {
                        Task { await model.commitTransaction() }
                    }
                    ToolbarChip(title: "Rollback", systemImage: "arrow.uturn.backward.circle.fill", tint: .red, help: "Undo everything since Begin Transaction") {
                        Task { await model.rollbackTransaction() }
                    }
                } else {
                    ToolbarChip(title: "Begin Transaction", systemImage: "arrow.triangle.branch", tint: .orange, isEnabled: model.canBeginTransaction,
                                help: model.canBeginTransaction ? "Edit inside a transaction on this tab's own connection; commit or roll back later" : "Begin Transaction needs an editable table") {
                        Task { await model.beginTransaction(session: model.connectionID.flatMap { app.sessions[$0] }) }
                    }
                }
                ToolbarChip(title: "Cell Editor", systemImage: "square.and.pencil", tint: .orange, isOn: model.showCellEditor) {
                    model.showCellEditor.toggle()
                }
                ToolbarChip(title: "Filter & Sort", systemImage: "line.3.horizontal.decrease.circle", tint: .orange, isOn: model.showFilterBar) {
                    model.showFilterBar.toggle()
                }
                ToolbarChip(title: "Columns", systemImage: "rectangle.split.3x1", tint: .blue, isOn: !model.hiddenColumns.isEmpty) {
                    showingColumns = true
                }
                .popover(isPresented: $showingColumns, arrowEdge: .bottom) { ColumnsPopover(model: model) }
                ToolbarChip(title: "History", systemImage: "clock.arrow.circlepath", tint: .orange, isOn: model.showHistory) {
                    model.showHistory.toggle()
                }
                ToolbarChip(title: "Fill with AI", systemImage: "sparkles", tint: .blue, isEnabled: model.object.kind == .table) {
                    app.assistant.ask(
                        "Write an INSERT statement with 10 rows of realistic sample data for the table \(model.object.qualifiedName). Respect the column types, primary key and NOT NULL constraints.",
                        includeTable: true
                    )
                }
                ToolbarChip(title: "Data Profiling", systemImage: "chart.bar.doc.horizontal", tint: .green, isEnabled: false) {}
                ToolbarChip(title: "Import", systemImage: "square.and.arrow.down", tint: .teal,
                            isEnabled: model.object.kind == .table && model.readOnlyReason == nil) {
                    if let context = app.currentContextFor(model) {
                        app.importTarget = ImportTarget(context: context, object: model.object)
                    }
                }
                ExportChip(columns: model.page?.columns ?? [], rows: model.page?.rows ?? [], suggestedName: model.object.name)
                    .disabled(model.page == nil)
                ToolbarChip(title: "Data Generation", systemImage: "wand.and.stars", tint: .purple,
                            isEnabled: model.object.kind == .table && model.readOnlyReason == nil && !model.isInTransaction) {
                    if let context = app.currentContextFor(model) {
                        app.generationTarget = ImportTarget(context: context, object: model.object)
                    }
                }
                ToolbarChip(title: "Data Masking", systemImage: "theatermasks", tint: .indigo, isEnabled: false) {}
                ToolbarChip(title: "Create BI Workspace", systemImage: "chart.pie", tint: .pink, isEnabled: false) {}
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                Menu {
                    Button("Refresh") { model.requestReload() }.disabled(model.hasChanges)
                    Button(model.mode == .data ? "Show Structure" : "Show Data") {
                        model.mode = model.mode == .data ? .structure : .data
                    }
                    Divider()
                    Button("Copy SELECT Statement") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.lastSQL, forType: .string)
                    }
                    Button("Open SELECT in New Query") {
                        if let context = app.currentContextFor(model) { app.openQuery(text: model.lastSQL + ";", in: context) }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                IconButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "Focus on this tab (hide side panes)",
                           isOn: !app.showNavigator && !app.showAssistant) {
                    let focused = !app.showNavigator && !app.showAssistant
                    app.showNavigator = focused
                    app.showAssistant = focused
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: Data

    @ViewBuilder
    private var dataArea: some View {
        ZStack {
            if let error = model.error {
                ErrorBanner(message: error)
            } else if let page = model.page {
                if model.viewMode == .form {
                    FormRecordView(model: model)
                } else {
                    ResultGridView(
                        columns: page.columns,
                        rows: model.displayRows,
                        columnTypes: model.columnTypes,
                        hiddenColumns: model.hiddenColumns,
                        sort: model.orderBy,
                        onHeaderClick: { column in Task { await model.toggleSort(column) } },
                        editing: model.isEditable ? GridEditing(
                            revision: model.revision,
                            cellState: { model.cellState(row: $0, column: $1) },
                            onEdit: { model.setValue($2, row: $0, column: $1) },
                            onToggleDelete: { model.toggleDelete($0) }
                        ) : nil,
                        focusedCell: model.focusedCell,
                        onFocusChange: { model.focusedCell = $0 },
                        onSelectionChange: { model.selectedRows = $0 },
                        scrollRequest: model.scrollRequest
                    )
                }
            }
            if model.isLoading || model.isSaving {
                ProgressView().controlSize(.small)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension AppModel {
    func currentContextFor(_ model: TableTabModel) -> DatabaseContext? {
        guard let id = model.connectionID else { return nil }
        return sessions[id]?.context(model.databaseName)
    }
}

// MARK: - Footer

/// + − ✓ ✗ ↻ ■ on the left; pagination, page settings, find and Grid/Form view on the right.
private struct GridFooter: View {
    @Bindable var model: TableTabModel
    @Binding var showingSQLPreview: Bool
    @State private var pageText = "1"
    @State private var showingPageSize = false
    @State private var showingFind = false

    var body: some View {
        HStack(spacing: 2) {
            IconButton(systemImage: "plus", help: "Add Record", isEnabled: model.isEditable) { model.addRow() }
            IconButton(systemImage: "minus", help: "Delete Selected Records (⌫)", isEnabled: model.isEditable && !model.selectedRows.isEmpty) {
                model.toggleDelete(model.selectedRows)
            }
            IconButton(systemImage: "checkmark", help: "Apply Changes (⌘S)", tint: .green, isEnabled: model.hasChanges && !model.isSaving) {
                Task { await model.applyChanges() }
            }
            IconButton(systemImage: "xmark", help: "Discard Changes", tint: .red, isEnabled: model.hasChanges) { model.discardChanges() }
            IconButton(systemImage: "arrow.clockwise", help: "Refresh (⌘R)", isEnabled: !model.hasChanges) { model.requestReload() }
            IconButton(systemImage: "stop.fill", help: "Stop", isEnabled: model.isLoading) { model.stopLoading() }

            if model.isInTransaction {
                Divider().frame(height: 14).padding(.horizontal, 4)
                Label("In transaction", systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .help("Applied edits are not visible to other connections until you Commit")
            }
            if model.hasChanges {
                Divider().frame(height: 14).padding(.horizontal, 4)
                Button("\(model.changeCount) pending change\(model.changeCount == 1 ? "" : "s")") { showingSQLPreview = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .help("Preview the SQL that Apply will run")
                    .popover(isPresented: $showingSQLPreview, arrowEdge: .top) { SQLPreview(sql: model.pendingSQL) }
            } else if let reason = model.readOnlyReason {
                Divider().frame(height: 14).padding(.horizontal, 4)
                Label(reason, systemImage: "lock.fill").font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Spacer()

            IconButton(systemImage: "backward.end.fill", help: "First Page", isEnabled: model.canGoBack) { Task { await model.goToPage(1) } }
            IconButton(systemImage: "arrowtriangle.left.fill", help: "Previous Page", isEnabled: model.canGoBack) { Task { await model.previousPage() } }
            TextField("", text: $pageText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .frame(width: 38)
                .onSubmit { Task { await model.goToPage(Int(pageText) ?? 1) } }
                .disabled(model.hasChanges)
                .help("Page")
            IconButton(systemImage: "arrowtriangle.right.fill", help: "Next Page", isEnabled: model.canGoForward) { Task { await model.nextPage() } }
            IconButton(systemImage: "forward.end.fill", help: "Last Page", isEnabled: model.canGoForward && model.totalRows != nil) {
                if let total = model.totalRows { Task { await model.goToPage((total + model.pageSize - 1) / model.pageSize) } }
            }
            IconButton(systemImage: "gearshape", help: "Records per page") { showingPageSize = true }
                .popover(isPresented: $showingPageSize, arrowEdge: .top) { PageSizePopover(model: model) }
            Divider().frame(height: 14).padding(.horizontal, 4)
            IconButton(systemImage: "plus.magnifyingglass", help: "Find in Grid") { showingFind = true }
                .popover(isPresented: $showingFind, arrowEdge: .top) { FindPopover(model: model) }
            IconButton(systemImage: "tablecells", help: "Grid View", isOn: model.viewMode == .grid) { model.viewMode = .grid }
            IconButton(systemImage: "list.bullet.rectangle", help: "Form View", isOn: model.viewMode == .form) { model.viewMode = .form }
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .onChange(of: model.pageNumber, initial: true) { _, page in pageText = String(page) }
    }
}

private struct PageSizePopover: View {
    @Bindable var model: TableTabModel
    @State private var custom = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Records per page").font(.headline)
            ForEach([100, 500, 1000, 5000], id: \.self) { size in
                Button {
                    Task { await model.setPageSize(size) }
                } label: {
                    HStack {
                        Text(size.formatted())
                        Spacer()
                        if model.pageSize == size { Image(systemName: "checkmark") }
                    }
                }
                .buttonStyle(.plain)
            }
            HStack {
                TextField("Custom", text: $custom).frame(width: 80)
                Button("Set") { if let size = Int(custom) { Task { await model.setPageSize(size) } } }
            }
            if model.hasChanges {
                Text("Apply or discard changes first.").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding()
        .frame(width: 200)
    }
}

private struct FindPopover: View {
    @Bindable var model: TableTabModel
    @State private var text = ""
    @State private var notFound = false

    var body: some View {
        HStack {
            TextField("Find in this page", text: $text)
                .frame(width: 200)
                .onSubmit(findNext)
            Button("Find Next", action: findNext)
        }
        .padding()
        .overlay(alignment: .bottomLeading) {
            if notFound { Text("No match").font(.caption).foregroundStyle(.secondary).padding(.leading, 16).padding(.bottom, 2) }
        }
    }

    private func findNext() {
        notFound = !model.findNext(text)
    }
}

// MARK: - Panels

/// Filter & Sort bar: a WHERE clause and the current sort.
private struct FilterSortBar: View {
    @Bindable var model: TableTabModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(.orange)
            Text("WHERE").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
            TextField("e.g. amount > 5 AND customer_id = 1", text: $model.filterText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { Task { await model.applyFilter() } }
                .disabled(model.hasChanges)
            Button("Apply") { Task { await model.applyFilter() } }
                .disabled(model.hasChanges)
            if !model.appliedFilter.isEmpty {
                Button("Clear") {
                    model.filterText = ""
                    Task { await model.applyFilter() }
                }
            }
            Divider().frame(height: 16)
            Text("ORDER BY").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
            if let sort = model.orderBy {
                Text("\(sort.column) \(sort.direction.rawValue)").font(.system(size: 12, design: .monospaced))
                Button {
                    Task { await model.toggleSort(sort.column) }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("Change direction")
            } else {
                Text("click a column header").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

/// Checkbox list to show or hide grid columns.
private struct ColumnsPopover: View {
    @Bindable var model: TableTabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Columns").font(.headline)
                Spacer()
                Button("Show All") { model.hiddenColumns = [] }.disabled(model.hiddenColumns.isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.page?.columns ?? [], id: \.self) { column in
                        Toggle(isOn: Binding(
                            get: { !model.hiddenColumns.contains(column) },
                            set: { visible in
                                if visible { model.hiddenColumns.remove(column) } else { model.hiddenColumns.insert(column) }
                            }
                        )) {
                            HStack {
                                Text(column)
                                Spacer()
                                Text(model.columnTypes[column] ?? "").foregroundStyle(.secondary).font(.caption)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding()
        .frame(width: 260)
    }
}

/// Shows the focused cell's full value; long text and JSON can be edited here.
private struct CellEditorPanel: View {
    @Bindable var model: TableTabModel
    @State private var text = ""
    @State private var loadedCell: GridCell?

    private var columnName: String? {
        guard let cell = model.focusedCell, let columns = model.page?.columns, columns.indices.contains(cell.column) else { return nil }
        return columns[cell.column]
    }

    private var canEdit: Bool {
        guard model.isEditable, let cell = model.focusedCell else { return false }
        if case .blob = model.focusedValue { return false }
        return model.cellState(row: cell.row, column: cell.column) != .deleted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "square.and.pencil").foregroundStyle(.orange)
                Text(columnName ?? "Cell Editor").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if let name = columnName, let type = model.columnTypes[name] {
                    Text(type).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                IconButton(systemImage: "xmark", help: "Close Cell Editor") { model.showCellEditor = false }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            Divider()
            if model.focusedCell == nil {
                Text("Click a cell to see its value.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .disabled(!canEdit)
                Divider()
                HStack {
                    if model.focusedValue?.isNull == true { Text("NULL").foregroundStyle(.secondary).font(.caption) }
                    Spacer()
                    Button("Set NULL") {
                        if let cell = model.focusedCell { model.setValue(.null, row: cell.row, column: cell.column) }
                    }
                    .disabled(!canEdit)
                    Button("Apply to Cell") {
                        if let cell = model.focusedCell { model.setValue(.text(text), row: cell.row, column: cell.column) }
                    }
                    .disabled(!canEdit)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .controlSize(.small)
                .padding(8)
            }
        }
        .onChange(of: model.focusedCell, initial: true) { _, _ in load() }
        .onChange(of: model.revision) { _, _ in load() }
    }

    private func load() {
        loadedCell = model.focusedCell
        guard let value = model.focusedValue else {
            text = ""
            return
        }
        text = value.isNull ? "" : value.displayString
    }
}

/// SQL this tab ran (SELECTs and applied changes), newest first.
private struct HistoryPanel: View {
    @Bindable var model: TableTabModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.orange)
                Text("History").font(.system(size: 12, weight: .semibold))
                Spacer()
                IconButton(systemImage: "xmark", help: "Close History") { model.showHistory = false }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            Divider()
            List(model.log) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.date, format: .dateTime.hour().minute().second())
                        .foregroundStyle(.secondary)
                    Image(systemName: entry.error == nil ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(entry.error == nil ? .green : .red)
                    Text(entry.sql).textSelection(.enabled).lineLimit(3)
                    if let error = entry.error { Text(error).foregroundStyle(.red).lineLimit(2) }
                }
                .font(.system(size: 11.5, design: .monospaced))
            }
            .listStyle(.plain)
        }
    }
}

/// One record at a time, field by field (Navicat's Form View).
private struct FormRecordView: View {
    @Bindable var model: TableTabModel

    private var row: Int { model.focusedCell?.row ?? model.selectedRows.first ?? 0 }

    var body: some View {
        let rows = model.displayRows
        let columns = model.page?.columns ?? []
        VStack(spacing: 0) {
            if rows.indices.contains(row) {
                ScrollView {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                            if !model.hiddenColumns.contains(column) {
                                GridRow {
                                    VStack(alignment: .trailing, spacing: 1) {
                                        Text(column).font(.system(size: 12, weight: .semibold))
                                        Text(model.columnTypes[column] ?? "").font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    .gridColumnAlignment(.trailing)
                                    FormField(model: model, row: row, column: index, value: rows[row][index])
                                }
                            }
                        }
                    }
                    .padding()
                }
            } else {
                Text("No record").foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Button { move(-1) } label: { Image(systemName: "chevron.up") }.disabled(row <= 0)
                Button { move(1) } label: { Image(systemName: "chevron.down") }.disabled(row >= rows.count - 1)
                Text("Record \(min(row + 1, rows.count)) of \(rows.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .frame(height: 24)
        }
    }

    private func move(_ delta: Int) {
        let target = max(0, min(model.displayRows.count - 1, row + delta))
        model.focusedCell = GridCell(row: target, column: model.focusedCell?.column ?? 0)
        model.selectedRows = [target]
    }
}

private struct FormField: View {
    @Bindable var model: TableTabModel
    let row: Int
    let column: Int
    let value: CellValue
    @State private var text = ""

    var body: some View {
        let editable = model.isEditable && model.cellState(row: row, column: column) != .deleted
        TextField(value.isNull ? "(Null)" : "", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: value.isNumeric ? .monospaced : .default))
            .disabled(!editable)
            .onSubmit {
                if text != (value.isNull ? "" : value.displayString) { model.setValue(.text(text), row: row, column: column) }
            }
            .onChange(of: value, initial: true) { _, newValue in text = newValue.isNull ? "" : newValue.displayString }
    }
}

struct SQLPreview: View {
    let sql: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("These statements run in one transaction:")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(sql)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sql, forType: .string)
                }
            }
        }
        .padding()
        .frame(width: 520, height: 260)
    }
}

private struct StructureView: View {
    let columns: [BunnyGridCore.TableColumn]
    let indexes: [TableIndex]

    var body: some View {
        VSplitView {
            Table(columns) {
                SwiftUI.TableColumn("") { column in
                    if column.isPrimaryKey {
                        Image(systemName: "key.fill").foregroundStyle(.yellow).help("Primary key")
                    }
                }
                .width(24)
                SwiftUI.TableColumn("Name", value: \.name)
                SwiftUI.TableColumn("Type") { Text($0.dataType).font(.body.monospaced()) }
                SwiftUI.TableColumn("Not Null") { Text($0.nullable ? "" : "✓") }.width(70)
                SwiftUI.TableColumn("Default") { Text($0.defaultValue ?? "").font(.body.monospaced()) }
            }
            .frame(minHeight: 120)

            Table(indexes) {
                SwiftUI.TableColumn("Index", value: \.name)
                SwiftUI.TableColumn("Fields") { Text($0.columns.joined(separator: ", ")) }
                SwiftUI.TableColumn("Unique") { Text($0.unique ? "✓" : "") }.width(60)
                SwiftUI.TableColumn("Primary") { Text($0.primary ? "✓" : "") }.width(60)
            }
            .frame(minHeight: 80)
        }
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        ScrollView {
            Label {
                Text(message).textSelection(.enabled).font(.body.monospaced())
            } icon: {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}
