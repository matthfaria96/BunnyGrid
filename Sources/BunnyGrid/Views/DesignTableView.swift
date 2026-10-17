import BunnyGridCore
import SwiftUI

/// Design Table / New Table tab: fields grid, indexes and the SQL that Save will run.
struct DesignTableView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: TableDesignModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            sectionBar
            Divider()
            Group {
                switch model.section {
                case .fields:
                    VSplitView {
                        fields.frame(minHeight: 160)
                        FieldProperties(model: model).frame(minHeight: 110, idealHeight: 150)
                    }
                case .indexes: indexes
                case .foreignKeys: foreignKeysView
                case .uniques: uniquesView
                case .triggers: triggersView
                case .options: optionsView
                case .sqlPreview: sqlPreview
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = model.planError, model.section != .sqlPreview {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .task { await model.load() }
        .alert("Table Not Saved", isPresented: Binding(
            get: { model.saveError != nil },
            set: { if !$0 { model.saveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.saveError ?? "")
        }
    }

    /// Icon toolbar whose buttons follow the tab, as in Navicat (Add Field / Add Index / Add Foreign Key…).
    private var toolbar: some View {
        HStack(spacing: 2) {
            ToolIconButton(systemImage: "square.and.arrow.down", help: "Save (⌘S)") { app.saveCurrent() }
                .disabled(!(model.hasChanges && model.planError == nil && !model.isSaving))
            Divider().frame(height: 16).padding(.horizontal, 6)
            switch model.section {
            case .fields:
                ToolIconButton(systemImage: "plus.circle", help: "Add Field", tint: .green) { model.addField() }
                ToolIconButton(systemImage: "arrow.left.circle", help: "Insert Field") { model.insertField() }
                ToolIconButton(systemImage: "minus.circle", help: "Delete Field", tint: .red) { model.deleteField() }
                    .disabled(model.selection == nil)
                ToolIconButton(systemImage: "key", help: "Primary Key", tint: .yellow) { model.togglePrimaryKey() }
                    .disabled(model.selection == nil)
            case .indexes, .uniques:
                ToolIconButton(systemImage: "plus.circle", help: model.section == .uniques ? "Add Unique" : "Add Index", tint: .green) {
                    model.addIndex()
                    if model.section == .uniques, let id = model.indexSelection, let index = model.indexDesigns.firstIndex(where: { $0.id == id }) {
                        model.indexDesigns[index].unique = true
                    }
                }
                ToolIconButton(systemImage: "minus.circle", help: model.section == .uniques ? "Delete Unique" : "Delete Index", tint: .red) { model.deleteIndex() }
                    .disabled(model.indexSelection.flatMap { id in model.indexDesigns.first { $0.id == id } }.map { model.isPrimaryIndex($0) } ?? true)
            case .foreignKeys:
                ToolIconButton(systemImage: "plus.circle", help: "Add Foreign Key", tint: .green) { model.addForeignKey() }
                ToolIconButton(systemImage: "minus.circle", help: "Delete Foreign Key", tint: .red) { model.deleteForeignKey() }
                    .disabled(model.foreignKeySelection == nil)
            case .triggers:
                ToolIconButton(systemImage: "plus.circle", help: "Add Trigger", tint: .green) { model.addTrigger() }
                ToolIconButton(systemImage: "minus.circle", help: "Delete Trigger", tint: .red) {
                    if let name = model.triggerSelection { model.droppedTriggers.insert(name) }
                }
                .disabled(model.triggerSelection == nil)
            case .options, .sqlPreview:
                EmptyView()
            }
            Spacer()
            HStack(spacing: 6) {
                Text("Table name").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
                TextField("new_table", text: $model.tableName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            if model.isSaving || model.isLoading { ProgressView().controlSize(.small) }
            Divider().frame(height: 16).padding(.horizontal, 6)
            ToolIconButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "Enter Focus Mode", isOn: app.isFocusMode) { app.toggleFocusMode() }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    private var sectionBar: some View {
        HStack(spacing: 4) {
            ForEach(TableDesignModel.Section.allCases, id: \.self) { section in
                Button {
                    model.section = section
                } label: {
                    Text(section.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(model.section == section ? Color.white : Color.primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(model.section == section ? Color.accentColor.opacity(0.85) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    // MARK: Foreign Keys

    private func keyBinding<Value>(_ id: ForeignKeyDesign.ID, _ keyPath: WritableKeyPath<TableForeignKey, Value>, fallback: Value) -> Binding<Value> {
        Binding(
            get: { model.foreignKeyDesigns.first { $0.id == id }?.key[keyPath: keyPath] ?? fallback },
            set: { value in
                if let index = model.foreignKeyDesigns.firstIndex(where: { $0.id == id }) { model.foreignKeyDesigns[index].key[keyPath: keyPath] = value }
            }
        )
    }

    /// A list of field names picked from a menu (checkmarks), as in the Indexes tab.
    private func fieldsMenu(_ selected: [String], choices: [String], placeholder: String, set: @escaping ([String]) -> Void) -> some View {
        Menu {
            ForEach(choices, id: \.self) { column in
                Button {
                    var columns = selected
                    if let position = columns.firstIndex(of: column) { columns.remove(at: position) } else { columns.append(column) }
                    set(columns)
                } label: {
                    if selected.contains(column) { Label(column, systemImage: "checkmark") } else { Text(column) }
                }
            }
            if choices.isEmpty { Text("No fields") }
        } label: {
            Text(selected.isEmpty ? placeholder : selected.joined(separator: ", "))
                .foregroundStyle(selected.isEmpty ? .secondary : .primary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var foreignKeysView: some View {
        Table(model.foreignKeyDesigns, selection: $model.foreignKeySelection) {
            TableColumn("Name") { row in
                if model.foreignKeysHaveNames {
                    TextField("", text: keyBinding(row.id, \.name, fallback: "")).textFieldStyle(.plain)
                } else {
                    Text("(unnamed)").foregroundStyle(.tertiary).help("SQLite doesn't keep foreign key names.")
                }
            }
            .width(min: 80, ideal: 130)
            TableColumn("Fields") { row in
                fieldsMenu(row.key.columns, choices: model.columns.map(\.name), placeholder: "Choose fields") {
                    keyBinding(row.id, \.columns, fallback: []).wrappedValue = $0
                }
            }
            .width(min: 80, ideal: 110)
            // SQLite keys can only point inside the same database file.
            TableColumn(model.kind == .postgresql ? "Referenced Schema" : "Referenced Database") { row in
                if model.kind == .sqlite {
                    Text("main").foregroundStyle(.secondary)
                } else {
                    Menu {
                        ForEach(model.referenceSchemas, id: \.self) { schema in
                            Button(schema) {
                                guard schema != row.key.referencedSchema else { return }
                                keyBinding(row.id, \.referencedSchema, fallback: nil).wrappedValue = schema
                                keyBinding(row.id, \.referencedTable, fallback: "").wrappedValue = ""
                                keyBinding(row.id, \.referencedColumns, fallback: []).wrappedValue = []
                                Task { await model.loadReferenceTables(schema: schema) }
                            }
                        }
                    } label: {
                        Text(row.key.referencedSchema ?? model.defaultReferenceSchema ?? "")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                }
            }
            .width(min: 60, ideal: 90)
            TableColumn("Referenced Table") { row in
                let schema = row.key.referencedSchema ?? model.defaultReferenceSchema
                Menu {
                    ForEach(model.tables(in: schema), id: \.self) { table in
                        Button(table) {
                            guard table != row.key.referencedTable else { return }
                            keyBinding(row.id, \.referencedTable, fallback: "").wrappedValue = table
                            // Point at the parent's primary key when it has a single-field one, as Navicat does.
                            Task {
                                await model.loadReferenceColumns(table: table, schema: schema)
                                let fields = model.columns(of: table, in: schema)
                                let guess = fields.contains("id") ? ["id"] : Array(fields.prefix(1))
                                keyBinding(row.id, \.referencedColumns, fallback: []).wrappedValue = Array(guess.prefix(max(row.key.columns.count, 1)))
                            }
                        }
                    }
                } label: {
                    Text(row.key.referencedTable.isEmpty ? "Choose table" : row.key.referencedTable)
                        .foregroundStyle(row.key.referencedTable.isEmpty ? .secondary : .primary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .task(id: schema ?? "") { await model.loadReferenceTables(schema: schema) }
            }
            .width(min: 80, ideal: 120)
            TableColumn("Referenced Fields") { row in
                let schema = row.key.referencedSchema ?? model.defaultReferenceSchema
                fieldsMenu(row.key.referencedColumns, choices: model.columns(of: row.key.referencedTable, in: schema),
                           placeholder: model.kind == .sqlite ? "Primary key" : "Choose fields") {
                    keyBinding(row.id, \.referencedColumns, fallback: []).wrappedValue = $0
                }
                .disabled(row.key.referencedTable.isEmpty)
                .task(id: (schema ?? "") + "." + row.key.referencedTable) {
                    await model.loadReferenceColumns(table: row.key.referencedTable, schema: schema)
                }
            }
            .width(min: 80, ideal: 110)
            TableColumn("On Delete") { row in
                Picker("", selection: keyBinding(row.id, \.onDelete, fallback: "NO ACTION")) {
                    ForEach(TableForeignKey.actions, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
            .width(min: 90, ideal: 105)
            TableColumn("On Update") { row in
                Picker("", selection: keyBinding(row.id, \.onUpdate, fallback: "NO ACTION")) {
                    ForEach(TableForeignKey.actions, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
            .width(min: 90, ideal: 105)
            TableColumn("") { row in
                if row.isNew {
                    Text("new").font(.system(size: 10)).foregroundStyle(.green)
                } else if row.isChanged {
                    Text("changed").font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            .width(50)
        }
        .overlay {
            if model.foreignKeyDesigns.isEmpty {
                Text("No foreign keys. Use Add Foreign Key to create one.").foregroundStyle(.tertiary)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.kind == .sqlite, !model.isNew, model.foreignKeysChanged {
                Label("SQLite can't alter foreign keys in place: saving rebuilds the table (new table, copy rows, drop, rename) and recreates its indexes and triggers. See SQL Preview.",
                      systemImage: "info.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
    }

    // MARK: Uniques

    private var uniquesView: some View {
        Table(model.indexDesigns.filter { $0.unique && !model.isPrimaryIndex($0) }, selection: $model.indexSelection) {
            TableColumn("Name") { index in
                TextField("", text: indexBinding(index.id, \.name)).textFieldStyle(.plain)
            }
            .width(min: 140, ideal: 200)
            TableColumn("Fields") { index in
                Menu {
                    ForEach(model.columns.map(\.name), id: \.self) { column in
                        Button {
                            var columns = indexBinding(index.id, \.columns).wrappedValue
                            if let position = columns.firstIndex(of: column) { columns.remove(at: position) } else { columns.append(column) }
                            indexBinding(index.id, \.columns).wrappedValue = columns
                        } label: {
                            if index.columns.contains(column) { Label(column, systemImage: "checkmark") } else { Text(column) }
                        }
                    }
                } label: {
                    Text(index.columns.isEmpty ? "Choose fields" : index.columns.joined(separator: ", "))
                        .foregroundStyle(index.columns.isEmpty ? .secondary : .primary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
            }
        }
        .overlay {
            if !model.indexDesigns.contains(where: { $0.unique && !model.isPrimaryIndex($0) }) {
                Text("No unique constraints. Use Add Unique to create one.").foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Triggers

    private var triggersView: some View {
        VSplitView {
            Table(model.triggers.filter { !model.droppedTriggers.contains($0.name) }, selection: $model.triggerSelection) {
                TableColumn("Name") { trigger in Text(trigger.name) }
                    .width(min: 140, ideal: 200)
                TableColumn("Fires") { trigger in Text(trigger.timing) }
                    .width(90)
                TableColumn("Insert") { trigger in Image(systemName: trigger.events.contains("INSERT") ? "checkmark" : "").foregroundStyle(.secondary) }
                    .width(60)
                TableColumn("Update") { trigger in Image(systemName: trigger.events.contains("UPDATE") ? "checkmark" : "").foregroundStyle(.secondary) }
                    .width(60)
                TableColumn("Delete") { trigger in Image(systemName: trigger.events.contains("DELETE") ? "checkmark" : "").foregroundStyle(.secondary) }
                    .width(60)
            }
            .frame(minHeight: 120)
            VStack(alignment: .leading, spacing: 6) {
                Text("Definition").font(.system(size: 12, weight: .semibold))
                if let name = model.triggerSelection, let trigger = model.triggers.first(where: { $0.name == name }) {
                    ScrollView {
                        Text(SQLSyntax.highlight(trigger.definition))
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                ForEach(model.newTriggers.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("New trigger").font(.system(size: 11)).foregroundStyle(.green)
                            Spacer()
                            Button("Remove") { model.newTriggers.remove(at: index) }.buttonStyle(.borderless).font(.system(size: 11))
                        }
                        TextEditor(text: $model.newTriggers[index])
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 80)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
                    }
                }
                if !model.droppedTriggers.isEmpty {
                    Text("Will drop: " + model.droppedTriggers.sorted().joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(.red)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(minHeight: 120)
        }
    }

    // MARK: Options

    private var optionsView: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 12) {
            switch model.kind {
            case .mysql, .mariadb:
                GridRow {
                    Text("Engine:").gridColumnAlignment(.trailing)
                    Picker("", selection: $model.engine) {
                        ForEach(["InnoDB", "MyISAM", "MEMORY", "ARCHIVE", "CSV"] + (model.originalEngine.isEmpty || ["InnoDB", "MyISAM", "MEMORY", "ARCHIVE", "CSV"].contains(model.originalEngine) ? [] : [model.originalEngine]), id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                GridRow {
                    Text("Comment:")
                    TextField("", text: $model.comment).frame(width: 360)
                }
            case .postgresql:
                GridRow {
                    Text("Comment:").gridColumnAlignment(.trailing)
                    TextField("", text: $model.comment).frame(width: 360)
                }
            case .sqlite:
                GridRow {
                    Text("Table Options:").gridColumnAlignment(.trailing)
                    Text("SQLite tables have no comment or engine. WITHOUT ROWID and STRICT are set in CREATE TABLE (see the DDL pane).")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 360, alignment: .leading)
                }
            case .mongodb:
                EmptyView()
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Fields

    private func binding<Value>(_ id: ColumnDesign.ID, _ keyPath: WritableKeyPath<ColumnDesign, Value>) -> Binding<Value> {
        Binding(
            get: { model.columns.first { $0.id == id }?[keyPath: keyPath] ?? ColumnDesign(name: "", type: "")[keyPath: keyPath] },
            set: { value in
                if let index = model.columns.firstIndex(where: { $0.id == id }) { model.columns[index][keyPath: keyPath] = value }
            }
        )
    }

    private var fields: some View {
        Table(model.columns, selection: $model.selection) {
            TableColumn("Name") { column in
                TextField("", text: binding(column.id, \.name)).textFieldStyle(.plain)
            }
            .width(min: 120, ideal: 180)
            TableColumn("Type") { column in
                HStack(spacing: 2) {
                    TextField("", text: binding(column.id, \.type))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                    Menu {
                        ForEach(model.dialect.suggestedTypes, id: \.self) { type in
                            Button(type) { binding(column.id, \.type).wrappedValue = type }
                        }
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .width(min: 120, ideal: 170)
            TableColumn("Not Null") { column in
                Toggle("", isOn: Binding(
                    get: { !binding(column.id, \.nullable).wrappedValue },
                    set: { binding(column.id, \.nullable).wrappedValue = !$0 }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
            }
            .width(64)
            TableColumn("Key") { column in
                Button {
                    model.selection = column.id
                    model.togglePrimaryKey()
                } label: {
                    Image(systemName: column.isPrimaryKey ? "key.fill" : "key")
                        .foregroundStyle(column.isPrimaryKey ? .yellow : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help(column.isPrimaryKey ? "Primary key" : "Make primary key")
            }
            .width(40)
            TableColumn("Default") { column in
                TextField("", text: binding(column.id, \.defaultValue))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
            }
            .width(min: 100, ideal: 160)
            TableColumn("") { column in
                if column.originalName == nil {
                    Text("new").font(.system(size: 10)).foregroundStyle(.green)
                } else if column.originalName != column.name {
                    Text("renamed").font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            .width(60)
        }
    }

    // MARK: Indexes

    private func indexBinding<Value>(_ id: IndexDesign.ID, _ keyPath: WritableKeyPath<IndexDesign, Value>) -> Binding<Value> {
        Binding(
            get: { model.indexDesigns.first { $0.id == id }?[keyPath: keyPath] ?? IndexDesign(name: "", columns: [])[keyPath: keyPath] },
            set: { value in
                if let index = model.indexDesigns.firstIndex(where: { $0.id == id }) { model.indexDesigns[index][keyPath: keyPath] = value }
            }
        )
    }

    private var indexes: some View {
        Table(model.indexDesigns, selection: $model.indexSelection) {
            TableColumn("Name") { index in
                if model.isPrimaryIndex(index) {
                    Label(index.name, systemImage: "key.fill").foregroundStyle(.secondary)
                } else {
                    TextField("", text: indexBinding(index.id, \.name)).textFieldStyle(.plain)
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn("Fields") { index in
                Menu {
                    ForEach(model.columns.map(\.name), id: \.self) { column in
                        Button {
                            var columns = indexBinding(index.id, \.columns).wrappedValue
                            if let position = columns.firstIndex(of: column) { columns.remove(at: position) } else { columns.append(column) }
                            indexBinding(index.id, \.columns).wrappedValue = columns
                        } label: {
                            if index.columns.contains(column) { Label(column, systemImage: "checkmark") } else { Text(column) }
                        }
                    }
                } label: {
                    Text(index.columns.isEmpty ? "Choose fields" : index.columns.joined(separator: ", "))
                        .foregroundStyle(index.columns.isEmpty ? .secondary : .primary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .disabled(model.isPrimaryIndex(index))
            }
            TableColumn("Unique") { index in
                Toggle("", isOn: indexBinding(index.id, \.unique))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(model.isPrimaryIndex(index))
            }
            .width(60)
            TableColumn("") { index in
                if index.originalName == nil {
                    Text("new").font(.system(size: 10)).foregroundStyle(.green)
                } else if model.isPrimaryIndex(index) {
                    Text("primary key").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .width(80)
        }
        .overlay {
            if model.indexDesigns.isEmpty {
                Text("No indexes. Use Add Index to create one.").foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: SQL Preview

    @ViewBuilder
    private var sqlPreview: some View {
        if let error = model.planError {
            ContentUnavailableView("Can't Save Yet", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if model.statements.isEmpty {
            ContentUnavailableView("No Changes", systemImage: "checkmark.circle", description: Text("The design matches the table in the database."))
        } else {
            ScrollView {
                Text(SQLSyntax.highlight(model.statements.map { $0 + ";" }.joined(separator: "\n\n")))
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }
}

/// Properties of the selected field, under the Fields grid (Navicat's bottom panel).
private struct FieldProperties: View {
    @Bindable var model: TableDesignModel

    private var index: Int? { model.selection.flatMap { id in model.columns.firstIndex { $0.id == id } } }

    var body: some View {
        Group {
            if let index {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
                    GridRow {
                        Text("Default Value:").gridColumnAlignment(.trailing)
                        TextField("", text: $model.columns[index].defaultValue, prompt: Text("None"))
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 280)
                    }
                    GridRow {
                        Text("Not Null:")
                        Toggle("", isOn: Binding(get: { !model.columns[index].nullable }, set: { model.columns[index].nullable = !$0 }))
                            .toggleStyle(.checkbox).labelsHidden()
                    }
                    GridRow {
                        Text("Primary Key:")
                        Toggle("", isOn: Binding(get: { model.columns[index].isPrimaryKey }, set: { value in
                            model.columns[index].isPrimaryKey = value
                            if value { model.columns[index].nullable = false }
                        }))
                        .toggleStyle(.checkbox).labelsHidden()
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
            } else {
                Text("Select a field to edit its properties.").foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .font(.system(size: 12))
    }
}
