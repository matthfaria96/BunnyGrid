import AppKit
import BunnyGridCore
import SwiftUI
import UniformTypeIdentifiers

/// The tab content for a document-store tab.
struct DocumentTabView: View {
    let tab: any DocumentTab

    var body: some View {
        if let viewer = tab as? CollectionTabModel {
            CollectionTabView(model: viewer)
        } else if let shell = tab as? MongoShellTabModel {
            MongoShellTabView(model: shell)
        } else if let bi = tab as? BIWorkspaceModel {
            BIWorkspaceView(model: bi)
        }
    }
}

// MARK: - Tree View

/// One line of Navicat's Tree View: key, value and type, with children for documents and arrays.
struct DocumentTreeNode: Identifiable {
    let id: String
    let key: String
    let value: String
    let type: String
    let children: [DocumentTreeNode]?

    static func nodes(_ documents: [BSONDocument]) -> [DocumentTreeNode] {
        documents.enumerated().map { index, document in
            let idText = document["_id"].map(BSONFormat.display) ?? ""
            return DocumentTreeNode(id: "\(index)", key: "(\(index + 1)) \(idText)", value: "{ \(document.count) fields }", type: "Document",
                                    children: children(.document(document), path: "\(index)"))
        }
    }

    static func children(_ value: BSON, path: String) -> [DocumentTreeNode]? {
        switch value {
        case .document(let document):
            return document.elements.map { node(key: $0.key, value: $0.value, path: "\(path).\($0.key)") }
        case .array(let array):
            return array.enumerated().map { node(key: "[\($0.offset)]", value: $0.element, path: "\(path).\($0.offset)") }
        default:
            return nil
        }
    }

    static func node(key: String, value: BSON, path: String) -> DocumentTreeNode {
        let text: String = switch value {
        case .document(let d): "{ \(d.count) fields }"
        case .array(let a): "[ \(a.count) elements ]"
        default: BSONFormat.display(value)
        }
        return DocumentTreeNode(id: path, key: key, value: text, type: value.typeName, children: children(value, path: path))
    }
}

struct DocumentTreeView: View {
    let documents: [BSONDocument]

    var body: some View {
        let nodes = DocumentTreeNode.nodes(documents)
        VStack(spacing: 0) {
            HStack {
                Text("Key").frame(maxWidth: .infinity, alignment: .leading)
                Text("Value").frame(maxWidth: .infinity, alignment: .leading)
                Text("Type").frame(width: 100, alignment: .leading)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            Divider()
            List {
                OutlineGroup(nodes, children: \.children) { node in
                    HStack {
                        Text(node.key).fontWeight(node.children != nil ? .medium : .regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(node.value).foregroundStyle(node.children != nil ? .secondary : .primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(node.type).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
                    }
                    .font(.system(size: 12, design: .monospaced))
                }
            }
            .listStyle(.inset)
        }
    }
}

/// JSON View: the documents in shell syntax, read-only and selectable.
struct DocumentJSONView: View {
    let documents: [BSONDocument]

    var body: some View {
        PlainTextEditor(text: .constant(documents.map { BSONFormat.shell($0) }.joined(separator: "\n\n")), isEditable: false)
    }
}

/// A MongoDB explain plan as an indented list of stages (COLLSCAN, IXSCAN, FETCH…).
struct DocumentPlanView: View {
    let nodes: [QueryPlanNode]

    var body: some View {
        let rows = nodes.flatMap { $0.flattened() }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: Self.symbol(row.node.title)).foregroundStyle(Color.accentColor).frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.node.title).font(.system(size: 12, weight: .semibold))
                            ForEach(Array(row.node.details.enumerated()), id: \.offset) { _, detail in
                                Text("\(detail.key): \(detail.value)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    .padding(.leading, 12 + CGFloat(row.depth) * 22)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03))
                }
            }
            .textSelection(.enabled)
        }
    }

    static func symbol(_ stage: String) -> String {
        switch stage.uppercased() {
        case "COLLSCAN": "tablecells"
        case "IXSCAN", "EXPRESS_IXSCAN", "IDHACK", "EXPRESS_CLUSTERED_IXSCAN": "magnifyingglass"
        case "FETCH": "arrow.down.doc"
        case "SORT", "SORT_KEY_GENERATOR": "arrow.up.arrow.down"
        case "LIMIT", "SKIP": "line.3.horizontal.decrease"
        case "PROJECTION_SIMPLE", "PROJECTION_DEFAULT", "PROJECTION_COVERED": "rectangle.split.3x1"
        case "SHARD_MERGE", "OR", "AND_HASH", "AND_SORTED": "arrow.triangle.merge"
        case "COUNT", "COUNT_SCAN", "GROUP": "sum"
        default: "smallcircle.filled.circle"
        }
    }
}

/// The three-way Grid / Tree / JSON switch of Navicat's MongoDB viewer.
struct ViewModePicker: View {
    @Binding var mode: CollectionTabModel.ViewMode

    var body: some View {
        Picker("", selection: $mode) {
            ForEach(CollectionTabModel.ViewMode.allCases) { mode in
                Image(systemName: mode.systemImage).help(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 110)
    }
}

// MARK: - Collection viewer

struct CollectionTabView: View {
    @Bindable var model: CollectionTabModel
    @State private var importMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) { toolbar }
            Divider()
            if model.showQueryBar {
                queryBar
                Divider()
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .task { await model.loadIfNeeded() }
        .sheet(item: $model.editor) { _ in DocumentEditorSheet(model: model) }
        .confirmationDialog("Delete \(model.selectedRows.count) document(s)?", isPresented: $model.confirmingDelete) {
            Button("Delete", role: .destructive) { Task { await model.deleteSelected() } }
        }
        .alert("Import", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK") { importMessage = nil }
        } message: { Text(importMessage ?? "") }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            toolButton("Add Document", "plus.rectangle.on.rectangle", disabled: model.isReadOnly) { model.addDocument() }
            toolButton("Edit Document", "pencil.and.list.clipboard", disabled: model.selectedRows.isEmpty || model.isReadOnly) { model.editSelected() }
            toolButton("Duplicate", "plus.square.on.square", disabled: model.selectedRows.isEmpty || model.isReadOnly) { model.duplicateSelected() }
            toolButton("Delete", "trash", disabled: model.selectedRows.isEmpty || model.isReadOnly) { model.confirmingDelete = true }
            Divider().frame(height: 22)
            toolButton("Filter", "line.3.horizontal.decrease.circle", disabled: false) { model.showQueryBar.toggle() }
            toolButton("Import", "square.and.arrow.down", disabled: model.isReadOnly) { importFile() }
            Menu {
                ForEach(DocumentTransferFormat.allCases) { format in
                    Button(format.rawValue) { export(format) }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            if model.isGridFS {
                toolButton("Save File", "arrow.down.doc", disabled: model.selectedRows.count != 1) { saveGridFSFile() }
            }
            Spacer()
            if let stats = model.stats {
                Text(statsSummary(stats)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func statsSummary(_ stats: BSONDocument) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(stats["size"]?.intValue ?? 0), countStyle: .file)
        let indexSize = ByteCountFormatter.string(fromByteCount: Int64(stats["totalIndexSize"]?.intValue ?? 0), countStyle: .file)
        return "\((stats["count"]?.intValue ?? 0).formatted()) documents · \(size) · \(stats["nindexes"]?.intValue ?? 0) indexes (\(indexSize))"
    }

    private func toolButton(_ title: String, _ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .disabled(disabled)
    }

    private var queryBar: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("Filter").foregroundStyle(.secondary)
                TextField("", text: $model.filterText, prompt: Text("{ field: \"value\" }"))
                    .onSubmit { model.applyFilter() }
                Button("Apply") { model.applyFilter() }.keyboardShortcut(.return, modifiers: .command)
            }
            GridRow {
                Text("Sort").foregroundStyle(.secondary)
                TextField("", text: $model.sortText, prompt: Text("{ field: -1 }")).onSubmit { model.applyFilter() }
                Button("Reset") { model.resetFilter() }
            }
            GridRow {
                Text("Projection").foregroundStyle(.secondary)
                TextField("", text: $model.projectionText, prompt: Text("{ field: 1, _id: 0 }")).onSubmit { model.applyFilter() }
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.error, model.documents.isEmpty {
            ContentUnavailableView("Couldn't load the documents", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if !model.hasLoaded {
            ProgressView()
        } else {
            switch model.viewMode {
            case .grid:
                ResultGridView(
                    columns: model.flattened.columns,
                    rows: model.displayRows,
                    columnTypes: model.flattened.columnTypes,
                    sort: model.gridSort,
                    onHeaderClick: { model.toggleSort($0) },
                    editing: model.isReadOnly ? nil : GridEditing(
                        revision: model.revision,
                        cellState: { model.cellState(row: $0, column: $1) },
                        onEdit: { model.setValue($2, row: $0, column: $1) },
                        onToggleDelete: { model.toggleDelete($0) }
                    ),
                    onSelectionChange: { model.selectedRows = $0 }
                )
            case .tree:
                DocumentTreeView(documents: model.documents)
            case .json:
                DocumentJSONView(documents: model.documents)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { model.addDocument() } label: { Image(systemName: "plus") }.disabled(model.isReadOnly).help("Add Document")
            Button { model.toggleDelete(model.selectedRows) } label: { Image(systemName: "minus") }
                .disabled(model.isReadOnly || model.selectedRows.isEmpty).help("Delete Document (pending)")
            Button { Task { await model.applyChanges() } } label: { Image(systemName: "checkmark") }.disabled(!model.hasChanges).help("Apply Changes")
            Button { model.discardChanges() } label: { Image(systemName: "xmark") }.disabled(!model.hasChanges).help("Discard Changes")
            Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
            if model.isLoading { ProgressView().controlSize(.small) }
            Spacer()
            Text(model.recordText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button { model.goToPage(0) } label: { Image(systemName: "backward.end") }.disabled(model.page == 0)
            Button { model.goToPage(model.page - 1) } label: { Image(systemName: "chevron.left") }.disabled(model.page == 0)
            Text("\(model.page + 1) / \(model.pageCount)").font(.system(size: 11)).monospacedDigit()
            Button { model.goToPage(model.page + 1) } label: { Image(systemName: "chevron.right") }.disabled(model.page + 1 >= model.pageCount)
            Button { model.goToPage(model.pageCount - 1) } label: { Image(systemName: "forward.end") }.disabled(model.page + 1 >= model.pageCount)
            ViewModePicker(mode: $model.viewMode)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .commaSeparatedText, .plainText, UTType(filenameExtension: "jsonl") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { importMessage = await model.importDocuments(from: url) }
    }

    private func export(_ format: DocumentTransferFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(model.collection).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let documents = try await model.allMatching()
                try DocumentTransfer.export(documents, as: format).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                model.error = error.localizedDescription
            }
        }
    }

    private func saveGridFSFile() {
        guard let row = model.selectedRows.first else { return }
        Task {
            do {
                let file = try await model.gridFSFileData(row: row)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = file.name
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try file.data.write(to: url)
            } catch {
                model.error = error.localizedDescription
            }
        }
    }
}

/// The JSON editor for one document, in shell syntax (`ObjectId("…")`, `ISODate("…")`), with Beautify and validation.
struct DocumentEditorSheet: View {
    @Bindable var model: CollectionTabModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var validation: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.editor?.originalID == nil ? "New Document" : "Edit Document").font(.headline)
            PlainTextEditor(text: $text)
                .frame(minWidth: 560, minHeight: 380)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            if let message = model.editor?.error ?? validation {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Beautify") {
                    if let document = try? MongoShellParser.parseDocument(text) { text = BSONFormat.shell(document) }
                }
                Button("Validate") { validate() }
                Spacer()
                Button("Cancel") { model.editor = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.editor?.text = text
                    saving = true
                    Task {
                        if await model.saveEditor() { dismiss() }
                        saving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving)
            }
        }
        .padding()
        .onAppear { text = model.editor?.text ?? "" }
    }

    private func validate() {
        do {
            _ = try MongoShellParser.parseDocument(text)
            validation = "Valid document."
        } catch {
            validation = error.localizedDescription
        }
    }
}

// MARK: - Shell

struct MongoShellTabView: View {
    @Bindable var model: MongoShellTabModel

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { model.run() } label: { Label("Run", systemImage: "play.fill") }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.isRunning)
                    Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .keyboardShortcut(".", modifiers: .command)
                        .disabled(!model.isRunning)
                    Button { model.explain() } label: { Label("Explain", systemImage: "list.bullet.indent") }
                        .disabled(model.isRunning)
                    if model.isRunning { ProgressView().controlSize(.small) }
                    Spacer()
                    Text("db: \(model.database)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
                SQLEditorView(text: $model.text, selectedText: $model.selectedText)
            }
            .frame(minHeight: 140)
            results.frame(minHeight: 160)
        }
    }

    @ViewBuilder
    private var results: some View {
        VStack(spacing: 0) {
            if model.outputs.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(model.outputs.enumerated()), id: \.element.id) { index, output in
                            Button("Result \(index + 1)") { model.selectedOutputID = output.id }
                                .buttonStyle(.bordered)
                                .tint(model.selectedOutput?.id == output.id ? .accentColor : .secondary)
                                .help(output.output.statement)
                        }
                    }
                    .padding(6)
                }
                Divider()
            }
            Group {
                if let error = model.error {
                    ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if let output = model.selectedOutput {
                    outputView(output)
                } else {
                    ContentUnavailableView("Run a command", systemImage: "terminal",
                                           description: Text("db.collection.find({ … }).sort({ … }).limit(10), aggregate([…]), insertOne({ … })…"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text(model.recordText).font(.system(size: 11)).foregroundStyle(.secondary)
                if let output = model.selectedOutput {
                    Text(String(format: "%.3fs", Double(output.output.duration.components.attoseconds) / 1e18 + Double(output.output.duration.components.seconds)))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                ViewModePicker(mode: $model.viewMode)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func outputView(_ output: MongoShellTabModel.Output) -> some View {
        if let plan = output.plan, model.viewMode != .json {
            DocumentPlanView(nodes: plan)
        } else if case .message(let text) = output.output.content {
            ContentUnavailableView(text, systemImage: "checkmark.circle")
        } else if case .value(let value) = output.output.content, value.documentValue == nil {
            PlainTextEditor(text: .constant(BSONFormat.shell(value)), isEditable: false)
        } else {
            switch model.viewMode {
            case .grid:
                let flat = DocumentFlattener.flatten(output.output.documents)
                ResultGridView(columns: flat.columns, rows: flat.rows, columnTypes: flat.columnTypes)
            case .tree: DocumentTreeView(documents: output.output.documents)
            case .json: DocumentJSONView(documents: output.output.documents)
            }
        }
    }
}

// MARK: - Connection form

/// MongoDB rows of the General tab: Connection Type (Standalone / Replica Set / SRV Record), Authentication Database
/// and Mechanism, as in Navicat for MongoDB.
struct MongoConnectionRows: View {
    @Binding var config: ConnectionConfig

    private var options: Binding<MongoOptions> {
        Binding(get: { config.mongo ?? MongoOptions() }, set: { config.mongo = $0 })
    }

    var body: some View {
        GridRow {
            Text("Connection Type").gridColumnAlignment(.trailing)
            Picker("", selection: Binding(get: { options.wrappedValue.srv }, set: { srv in
                options.wrappedValue.srv = srv
                if srv && config.tls == .prefer { config.tls = .verifyFull }
            })) {
                Text("Standalone / Replica Set").tag(false)
                Text("SRV Record (mongodb+srv)").tag(true)
            }
            .labelsHidden()
        }
        if !options.wrappedValue.srv {
            GridRow {
                Text("More Hosts").gridColumnAlignment(.trailing)
                TextField("", text: Binding(get: { options.wrappedValue.extraHosts.joined(separator: ", ") }, set: {
                    options.wrappedValue.extraHosts = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }), prompt: Text("host2:27017, host3:27017"))
            }
            GridRow {
                Text("Replica Set").gridColumnAlignment(.trailing)
                TextField("", text: options.replicaSet, prompt: Text("optional"))
            }
        }
        GridRow {
            Text("Auth Database").gridColumnAlignment(.trailing)
            TextField("", text: options.authSource, prompt: Text("admin"))
        }
        GridRow {
            Text("Auth Mechanism").gridColumnAlignment(.trailing)
            Picker("", selection: options.authMechanism) {
                Text("Default").tag("")
                Text("SCRAM-SHA-256").tag("SCRAM-SHA-256")
                Text("SCRAM-SHA-1").tag("SCRAM-SHA-1")
            }
            .labelsHidden()
        }
    }
}
