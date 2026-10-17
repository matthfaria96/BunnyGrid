import AppKit
import BunnyGridCore
import SwiftUI

/// DDL tab: the object's CREATE statement, highlighted, with Copy.
struct DDLPane: View {
    let context: DatabaseContext?
    let object: DatabaseObject?
    @State private var ddl = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).padding().frame(maxHeight: .infinity, alignment: .top)
            } else if ddl.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(SQLSyntax.highlight(ddl))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ddl, forType: .string)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5))
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
            }
        }
        .task(id: object?.id) { await load() }
    }

    private func load() async {
        ddl = ""
        error = nil
        guard let context, let object else { error = "Select a table or view."; return }
        do {
            ddl = try await context.driver.objectDDL(name: object.name, kind: object.kind, schema: context.driverSchema(object.schema))
            if ddl.isEmpty { error = "No DDL available." }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Field tab: the column under the grid's focus — name, Type, Not Null, Default Value.
struct FieldPane: View {
    let table: TableTabModel

    private var column: BunnyGridCore.TableColumn? {
        guard let cell = table.focusedCell, let page = table.page, cell.column < page.columns.count else { return table.columns.first }
        let name = page.columns[cell.column]
        return table.columns.first { $0.name == name }
    }

    var body: some View {
        ScrollView {
            if let column {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 8) {
                        AppIcon(name: "table", size: 18)
                        if column.isPrimaryKey {
                            Image(systemName: "key.fill").foregroundStyle(.yellow).font(.system(size: 13))
                        }
                        Text(column.name).font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.bottom, 6)
                    field("Type", column.dataType)
                    field("Not Null", column.nullable ? "No" : "Yes")
                    field("Default Value", column.defaultValue ?? "")
                    field("Primary Key", column.isPrimaryKey ? "Yes" : "No")
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Select a cell to see its field.").font(.system(size: 12)).foregroundStyle(.secondary).padding()
            }
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Text(value.isEmpty ? "--" : value).font(.system(size: 12)).textSelection(.enabled)
        }
    }
}

/// Code Snippet tab: label filter, snippets (built-in and yours), search; double-click inserts at the cursor.
struct SnippetsPane: View {
    @Environment(AppModel.self) private var app
    let query: QueryTabModel?
    @AppStorage("snippetLabel") private var label = "All Labels"
    @State private var search = ""
    @State private var editing: CodeSnippet?

    private var all: [CodeSnippet] { CodeSnippet.builtIns + app.snippets }
    private var labels: [String] { ["All Labels"] + Array(Set(all.map(\.label))).sorted() }
    private var shown: [CodeSnippet] {
        all.filter { snippet in
            (label == "All Labels" || snippet.label == label)
                && (search.isEmpty || snippet.name.localizedCaseInsensitiveContains(search) || snippet.detail.localizedCaseInsensitiveContains(search))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Picker("", selection: $label) {
                    ForEach(labels, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                IconButton(systemImage: "plus.circle", help: "New Snippet", tint: .green) {
                    editing = CodeSnippet(name: "", label: "My Snippets", detail: "", code: query?.selectedText ?? "")
                }
            }
            .padding(10)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(shown) { snippet in
                        SnippetRow(snippet: snippet) { insert(snippet) }
                            .contextMenu {
                                Button("Insert") { insert(snippet) }
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(snippet.code, forType: .string)
                                }
                                if !snippet.isBuiltIn {
                                    Divider()
                                    Button("Edit…") { editing = snippet }
                                    Button("Delete", role: .destructive) { app.deleteSnippet(snippet.id) }
                                }
                            }
                    }
                }
                .padding(.horizontal, 8)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassBackground(in: Capsule())
            .padding(8)
        }
        .sheet(item: $editing) { snippet in
            SnippetEditor(snippet: snippet)
        }
    }

    private func insert(_ snippet: CodeSnippet) {
        guard let query else { return }
        query.insert(snippet.code, mode: query.hasSelection ? .replaceSelection : .atCursor)
    }
}

private struct SnippetRow: View {
    let snippet: CodeSnippet
    let insert: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "curlybraces.square")
                .font(.system(size: 22))
                .foregroundStyle(snippet.isBuiltIn ? Color.teal : Color.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                (Text(snippet.name).font(.system(size: 12.5, weight: .semibold)) + Text("  " + snippet.label).font(.system(size: 11)).foregroundColor(.secondary))
                    .lineLimit(2)
                Text(snippet.detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(isHovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: insert)
        .help(snippet.code)
    }
}

private struct SnippetEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var snippet: CodeSnippet

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(snippet.name.isEmpty ? "New Snippet" : "Edit Snippet").font(.headline)
            Form {
                TextField("Name", text: $snippet.name)
                TextField("Label", text: $snippet.label)
                TextField("Description", text: $snippet.detail)
            }
            Text("Code").font(.system(size: 12))
            TextEditor(text: $snippet.code)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 160)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    app.saveSnippet(snippet)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(snippet.name.trimmingCharacters(in: .whitespaces).isEmpty || snippet.code.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Identifiers tab: tables and views of the editor's database, expandable to columns; double-click inserts the name.
struct IdentifiersPane: View {
    let query: QueryTabModel?
    @State private var search = ""
    @State private var expanded: Set<String> = []
    @State private var columns: [String: [BunnyGridCore.TableColumn]] = [:]

    private var objects: [DatabaseObject] {
        guard let context = query?.context else { return [] }
        let all = (context.objects(in: context.defaultSchema) ?? []).filter { $0.kind != .routine }
        return search.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach([DatabaseObjectKind.table, .view, .materializedView], id: \.self) { kind in
                    let group = objects.filter { $0.kind == kind }
                    if !group.isEmpty {
                        Section(kind == .table ? "Table" : kind == .view ? "View" : "Materialized View") {
                            ForEach(group) { object in
                                DisclosureGroup(isExpanded: Binding(
                                    get: { expanded.contains(object.id) },
                                    set: { open in
                                        if open { expanded.insert(object.id); Task { await loadColumns(object) } } else { expanded.remove(object.id) }
                                    }
                                )) {
                                    ForEach(columns[object.id] ?? []) { column in
                                        HStack(spacing: 6) {
                                            Image(systemName: column.isPrimaryKey ? "key.fill" : GridHeaderCell.symbolName(for: column.dataType))
                                                .font(.system(size: 10)).foregroundStyle(column.isPrimaryKey ? .yellow : .secondary).frame(width: 14)
                                            Text(column.name)
                                            Spacer()
                                            Text(column.dataType).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                                        }
                                        .contentShape(Rectangle())
                                        .onTapGesture(count: 2) { insert(column.name) }
                                    }
                                } label: {
                                    Label {
                                        Text(object.name)
                                    } icon: {
                                        AppIcon(name: object.kind.iconName, size: 15)
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { insert(object.name) }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .font(.system(size: 12.5))
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassBackground(in: Capsule())
            .padding(8)
        }
    }

    private func loadColumns(_ object: DatabaseObject) async {
        guard columns[object.id] == nil, let context = query?.context else { return }
        columns[object.id] = (try? await context.driver.listColumns(table: object.name, schema: context.driverSchema(object.schema))) ?? []
    }

    private func insert(_ identifier: String) {
        query?.insert(identifier, mode: .atCursor)
    }
}
