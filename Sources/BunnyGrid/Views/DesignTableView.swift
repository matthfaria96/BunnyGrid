import BunnyGridCore
import SwiftUI

/// Design Table / New Table tab: fields grid, indexes and the SQL that Save will run.
struct DesignTableView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: TableDesignModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            sectionBar
            Divider()
            Group {
                switch model.section {
                case .fields: fields
                case .indexes: indexes
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

    private var toolbar: some View {
        HStack(spacing: 12) {
            ToolbarChip(title: "Save", systemImage: "square.and.arrow.down.fill", tint: .blue,
                        isEnabled: model.hasChanges && model.planError == nil && !model.isSaving, help: "Save (⌘S)") {
                app.saveCurrent()
            }
            Divider().frame(height: 16)
            if model.section == .indexes {
                ToolbarChip(title: "Add Index", systemImage: "plus.rectangle", tint: .green) { model.addIndex() }
                ToolbarChip(title: "Delete Index", systemImage: "minus.rectangle", tint: .red,
                            isEnabled: model.indexSelection.flatMap { id in model.indexDesigns.first { $0.id == id } }.map { !model.isPrimaryIndex($0) } ?? false) {
                    model.deleteIndex()
                }
            } else {
                ToolbarChip(title: "Add Field", systemImage: "plus.rectangle", tint: .green) { model.addField() }
                ToolbarChip(title: "Insert Field", systemImage: "text.insert", tint: .green) { model.insertField() }
                ToolbarChip(title: "Delete Field", systemImage: "minus.rectangle", tint: .red, isEnabled: model.selection != nil) { model.deleteField() }
                ToolbarChip(title: "Primary Key", systemImage: "key.fill", tint: .yellow, isEnabled: model.selection != nil) { model.togglePrimaryKey() }
            }
            Spacer()
            HStack(spacing: 6) {
                Text("Table name").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
                TextField("new_table", text: $model.tableName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
            if model.isSaving || model.isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sectionBar: some View {
        HStack(spacing: 0) {
            ForEach(TableDesignModel.Section.allCases, id: \.self) { section in
                Button {
                    model.section = section
                } label: {
                    Text(section.rawValue)
                        .font(.system(size: 12))
                        .foregroundStyle(model.section == section ? .primary : .secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .overlay(alignment: .bottom) {
                            if model.section == section { Rectangle().fill(Color.accentColor).frame(height: 2) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .fixedSize(horizontal: false, vertical: true)
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
                Text(MarkdownText.highlightSQL(model.statements.map { $0 + ";" }.joined(separator: "\n\n")))
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }
}
