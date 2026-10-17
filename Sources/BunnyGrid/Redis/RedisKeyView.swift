import AppKit
import BunnyGridCore
import SwiftUI

/// Navicat for Redis' key viewer: the key bar (name, type, TTL, rename, delete), the value editor for the
/// key's type, and a footer with sizes and Load More.
struct RedisKeyView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: RedisKeyModel
    let tabID: UUID

    @State private var renaming = false
    @State private var newName = ""
    @State private var editingTTL = false
    @State private var confirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let value = model.value {
                    RedisValueEditor(model: model, value: value)
                } else if model.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("No Value", systemImage: "key", description: Text(model.error ?? ""))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Sizes and memory are in the window's status bar; the footer only appears for an error or Load More.
            if model.error != nil || model.isTruncated {
                Divider()
                footer
            }
        }
        .task { if model.value == nil { await model.load() } }
        .alert("Rename Key", isPresented: $renaming) {
            TextField("New name", text: $newName)
            Button("Rename") { Task { await model.rename(to: newName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("RENAMENX: fails when a key with the new name exists.")
        }
        .confirmationDialog("Delete “\(model.key)”?", isPresented: $confirmingDelete) {
            Button("Delete Key", role: .destructive) {
                Task { if await model.deleteKey() { app.closeTab(tabID) } }
            }
        } message: {
            Text("The key and its value are removed from db\(model.database).")
        }
        .popover(isPresented: $editingTTL, arrowEdge: .bottom) {
            RedisTTLEditor(ttl: model.info?.ttl ?? -1) { seconds in
                editingTTL = false
                Task { await model.setTTL(seconds) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill").foregroundStyle(.red)
            Text(model.key).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            if let info = model.info {
                RedisTypeBadge(type: info.type)
            }
            Spacer(minLength: 8)
            Button {
                editingTTL = true
            } label: {
                Label(ttlText, systemImage: "timer")
            }
            .help("Set or remove the key's expiry (EXPIRE / PERSIST)")
            .disabled(model.isReadOnly || model.info == nil)
            Button {
                newName = model.key
                renaming = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .disabled(model.isReadOnly)
            IconButton(systemImage: "arrow.clockwise", help: "Reload the value") { Task { await model.load() } }
            IconButton(systemImage: "trash", help: "Delete the key", tint: .red, isEnabled: !model.isReadOnly) { confirmingDelete = true }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    private var ttlText: String {
        guard let ttl = model.info?.ttl else { return "TTL" }
        return ttl >= 0 ? "TTL \(RedisTTLEditor.describe(ttl))" : "No Expiry"
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(1).help(error)
            }
            Spacer()
            if model.isLoading { ProgressView().controlSize(.mini) }
            if model.isTruncated {
                Button("Load More") { Task { await model.loadMore() } }
            }
        }
        .font(.system(size: 11))
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 26)
    }
}

struct RedisTypeBadge: View {
    let type: RedisKeyType

    var body: some View {
        Text(type.displayName.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(type.tint))
    }
}

extension RedisKeyType {
    var tint: Color {
        switch self {
        case .string: .blue
        case .hash: .orange
        case .list: .green
        case .set: .purple
        case .zset: .pink
        case .stream: .teal
        case .json: .indigo
        case .other: .gray
        }
    }

    var systemImage: String {
        switch self {
        case .string: "textformat"
        case .hash: "number.square"
        case .list: "list.number"
        case .set: "circle.grid.2x2"
        case .zset: "chart.bar.doc.horizontal"
        case .stream: "water.waves"
        case .json: "curlybraces"
        case .other: "questionmark.square"
        }
    }
}

/// Expiry in seconds, or none (PERSIST).
struct RedisTTLEditor: View {
    let ttl: Int64
    let apply: (Int64?) -> Void
    @State private var expires = false
    @State private var seconds = 3600

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Expire after", isOn: $expires)
            HStack {
                TextField("", value: $seconds, format: .number.grouping(.never)).frame(width: 100)
                Text("seconds")
                Text(RedisTTLEditor.describe(Int64(seconds))).foregroundStyle(.secondary)
            }
            .disabled(!expires)
            HStack {
                ForEach([(60, "1 min"), (3600, "1 h"), (86_400, "1 day"), (604_800, "1 week")], id: \.0) { value, label in
                    Button(label) { expires = true; seconds = value }
                }
            }
            .controlSize(.small)
            HStack {
                Spacer()
                Button("Apply") { apply(expires && seconds > 0 ? Int64(seconds) : nil) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(14)
        .frame(width: 300)
        .onAppear {
            expires = ttl >= 0
            if ttl > 0 { seconds = Int(ttl) }
        }
    }

    static func describe(_ seconds: Int64) -> String {
        guard seconds >= 60 else { return "\(seconds) s" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) s"
    }
}

// MARK: - Value editors

/// One row of the collection editors.
struct RedisRow: Identifiable, Hashable {
    let id: Int
    /// Hash field, list index, set / zset member or stream id.
    var first: Data
    /// Hash value, list value, zset score or stream fields; empty for sets.
    var second: String
    var score: Double = 0
    var fields: [RedisPair] = []
}

private struct RedisValueEditor: View {
    @Bindable var model: RedisKeyModel
    let value: RedisValue

    var body: some View {
        switch value {
        case .string(let data): RedisStringEditor(model: model, data: data, isJSONKey: false)
        case .json: RedisStringEditor(model: model, data: Data(model.draftText.utf8), isJSONKey: true)
        case .hash, .list, .set, .zset, .stream: RedisCollectionEditor(model: model, value: value)
        case .unsupported(let name):
            ContentUnavailableView("\(name) keys can't be shown", systemImage: "questionmark.square.dashed",
                                   description: Text("Use the Console to read this module type."))
        }
    }
}

/// String values as text, JSON or a hex dump (parts of the cell editor: `PlainTextEditor`, `JSONFormatter`, `HexFormatter`).
private struct RedisStringEditor: View {
    enum Mode: String, CaseIterable, Identifiable {
        case text = "Text", json = "JSON", hex = "Hex"
        var id: String { rawValue }
    }

    @Bindable var model: RedisKeyModel
    let data: Data
    let isJSONKey: Bool
    @State private var mode: Mode = .text
    @State private var jsonError: String?

    private var isBinary: Bool { String(data: data, encoding: .utf8) == nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if !isJSONKey {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if mode == .json || isJSONKey {
                    Button("Beautify") { reformat { try JSONFormatter.pretty($0) } }
                    Button("Minify") { reformat { try JSONFormatter.minify($0) } }
                    if let jsonError {
                        Label(jsonError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(1).help(jsonError)
                    } else if !model.draftText.isEmpty {
                        Label("Valid JSON", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                Spacer()
                if isBinary && mode != .hex {
                    Text("Binary value: edits replace it with UTF-8 text").foregroundStyle(.secondary)
                }
                Button("Load File…") { loadFile() }.disabled(model.isReadOnly || isJSONKey)
                Button("Save File…") { saveFile() }
                Button("Save") { Task { await model.saveText() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.hasUnsavedText || model.isReadOnly || mode == .hex || (isJSONKey && jsonError != nil))
            }
            .font(.system(size: 11))
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            Divider()
            if mode == .hex && !isJSONKey {
                PlainTextEditor(text: .constant(HexFormatter.dump(data)), isEditable: false, wrapsLines: false)
            } else {
                PlainTextEditor(text: $model.draftText, isEditable: !model.isReadOnly)
            }
        }
        .onChange(of: model.revision, initial: true) { _, _ in
            if !isJSONKey {
                let trimmed = model.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
                mode = isBinary ? .hex : ((trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) && JSONFormatter.validate(trimmed) == nil ? .json : .text)
            }
        }
        .onChange(of: model.draftText, initial: true) { _, text in
            jsonError = (mode == .json || isJSONKey) && !text.isEmpty ? JSONFormatter.validate(text) : nil
        }
        .onChange(of: mode) { _, _ in
            jsonError = mode == .json && !model.draftText.isEmpty ? JSONFormatter.validate(model.draftText) : nil
        }
    }

    private func reformat(_ transform: (String) throws -> String) {
        do { model.draftText = try transform(model.draftText) } catch { jsonError = error.localizedDescription }
    }

    private func loadFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let bytes = try? Data(contentsOf: url) else { return }
        Task { await model.saveBytes(bytes) }
    }

    private func saveFile() {
        let panel = NSSavePanel()
        let kind = BlobKind.detect(data)
        panel.nameFieldStringValue = (model.key.split(separator: ":").last.map(String.init) ?? "value") + "." + (isJSONKey ? "json" : kind.fileExtension)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try (isJSONKey ? Data(model.draftText.utf8) : data).write(to: url, options: .atomic) } catch { model.error = error.localizedDescription }
    }
}

/// Hash, list, set, sorted set and stream values as an editable table.
private struct RedisCollectionEditor: View {
    @Bindable var model: RedisKeyModel
    let value: RedisValue
    @State private var selection = Set<RedisRow.ID>()
    @State private var editing: RedisMemberDraft?
    @State private var filter = ""

    private var rows: [RedisRow] {
        let all: [RedisRow] = switch value {
        case .hash(let pairs): pairs.enumerated().map { RedisRow(id: $0, first: $1.field, second: text($1.value)) }
        case .list(let items): items.enumerated().map { RedisRow(id: $0, first: Data(String($0).utf8), second: text($1)) }
        case .set(let items): items.enumerated().map { RedisRow(id: $0, first: $1, second: "") }
        case .zset(let items): items.enumerated().map { RedisRow(id: $0, first: $1.member, second: RESPValueFormat.score($1.score), score: $1.score) }
        case .stream(let entries): entries.enumerated().map {
            RedisRow(id: $0, first: Data($1.id.utf8), second: $1.fields.map { "\(text($0.field))=\(text($0.value))" }.joined(separator: "  "), fields: $1.fields)
        }
        default: []
        }
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return all }
        return all.filter { text($0.first).localizedCaseInsensitiveContains(needle) || $0.second.localizedCaseInsensitiveContains(needle) }
    }

    private var columns: (String, String?) {
        switch value {
        case .hash: ("Field", "Value")
        case .list: ("Index", "Value")
        case .set: ("Member", nil)
        case .zset: ("Member", "Score")
        case .stream: ("ID", "Fields")
        default: ("", nil)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                IconButton(systemImage: "plus", help: "Add", isEnabled: !model.isReadOnly) { editing = RedisMemberDraft(value: value, row: nil) }
                IconButton(systemImage: "minus", help: "Remove the selected items", isEnabled: !model.isReadOnly && !selection.isEmpty) { removeSelected() }
                IconButton(systemImage: "pencil", help: "Edit the selected item", isEnabled: !model.isReadOnly && selection.count == 1 && !isStream) {
                    if let row = rows.first(where: { selection.contains($0.id) }) { editing = RedisMemberDraft(value: value, row: row) }
                }
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter loaded items", text: $filter).textFieldStyle(.plain)
                }
                .frame(width: 200)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            Divider()
            Table(rows, selection: $selection) {
                TableColumn(columns.0) { row in
                    Text(text(row.first)).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                }
                .width(min: 80, ideal: 220)
                TableColumn(columns.1 ?? "") { row in
                    Text(row.second).font(.system(size: 12, design: .monospaced)).lineLimit(1).help(row.second)
                }
            }
            .contextMenu(forSelectionType: RedisRow.ID.self) { ids in
                Button("Edit…") {
                    if let id = ids.first, let row = rows.first(where: { $0.id == id }) { editing = RedisMemberDraft(value: value, row: row) }
                }
                .disabled(ids.count != 1 || model.isReadOnly || isStream)
                Button("Copy") {
                    let lines = rows.filter { ids.contains($0.id) }.map { [text($0.first), $0.second].filter { !$0.isEmpty }.joined(separator: "\t") }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
                Divider()
                Button("Remove", role: .destructive) { selection = ids; removeSelected() }.disabled(model.isReadOnly)
            } primaryAction: { ids in
                guard !model.isReadOnly, !isStream, let id = ids.first, let row = rows.first(where: { $0.id == id }) else { return }
                editing = RedisMemberDraft(value: value, row: row)
            }
        }
        .sheet(item: $editing) { draft in
            RedisMemberSheet(draft: draft) { result in
                editing = nil
                guard let result else { return }
                Task { await save(result) }
            }
        }
        .onChange(of: model.revision) { _, _ in selection = [] }
    }

    private var isStream: Bool { if case .stream = value { true } else { false } }

    private func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? RedisCommandLine.quote(data)
    }

    private func save(_ draft: RedisMemberDraft) async {
        let key = model.key, db = model.database
        let field = Data(draft.first.utf8), second = Data(draft.second.utf8)
        let original = draft.row?.first
        switch value {
        case .hash:
            await model.perform { try await $0.hashSet(database: db, key: key, field: field, value: second, replacing: original) }
        case .list:
            if let row = draft.row {
                await model.perform { try await $0.listSet(database: db, key: key, index: row.id, value: second) }
            } else {
                let head = draft.atHead
                await model.perform { try await $0.listPush(database: db, key: key, values: [second], atHead: head) }
            }
        case .set:
            await model.perform { try await $0.setAdd(database: db, key: key, members: [field], replacing: original) }
        case .zset:
            let score = Double(draft.second) ?? 0
            await model.perform { try await $0.zsetAdd(database: db, key: key, member: field, score: score, replacing: original) }
        case .stream:
            let pairs = RedisMemberDraft.streamFields(draft.second)
            let id = draft.first
            await model.perform { _ = try await $0.streamAdd(database: db, key: key, id: id, fields: pairs) }
        default:
            break
        }
    }

    private func removeSelected() {
        let chosen = rows.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let key = model.key, db = model.database
        Task {
            switch value {
            case .hash: await model.perform { try await $0.hashDelete(database: db, key: key, fields: chosen.map(\.first)) }
            case .set: await model.perform { try await $0.setRemove(database: db, key: key, members: chosen.map(\.first)) }
            case .zset: await model.perform { try await $0.zsetRemove(database: db, key: key, members: chosen.map(\.first)) }
            case .stream:
                let ids = chosen.map { String(decoding: $0.first, as: UTF8.self) }
                await model.perform { try await $0.streamDelete(database: db, key: key, ids: ids) }
            case .list:
                // Highest index first, so earlier removals don't shift the later ones.
                let indexes = chosen.map(\.id).sorted(by: >)
                await model.perform { driver in
                    for index in indexes { try await driver.listRemove(database: db, key: key, index: index) }
                }
            default: break
            }
            selection = []
        }
    }
}

enum RESPValueFormat {
    static func score(_ value: Double) -> String {
        if value.isInfinite { return value > 0 ? "+inf" : "-inf" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }
}

/// What the add / edit sheet works on.
struct RedisMemberDraft: Identifiable {
    enum Kind { case hash, list, set, zset, stream }

    let id = UUID()
    let kind: Kind
    let row: RedisRow?
    var first: String
    var second: String
    var atHead = false

    init(value: RedisValue, row: RedisRow?) {
        self.row = row
        let kind: Kind = switch value {
        case .hash: .hash
        case .list: .list
        case .set: .set
        case .zset: .zset
        default: .stream
        }
        self.kind = kind
        first = row.map { String(decoding: $0.first, as: UTF8.self) } ?? (kind == .stream ? "*" : "")
        if kind == .stream {
            second = row.map { $0.fields.map { "\(String(decoding: $0.field, as: UTF8.self)) \(String(decoding: $0.value, as: UTF8.self))" }.joined(separator: "\n") } ?? "field value"
        } else {
            second = row.map { kind == .zset ? RESPValueFormat.score($0.score) : $0.second } ?? (kind == .zset ? "0" : "")
        }
    }

    /// "field value" per line; the value may hold spaces.
    static func streamFields(_ text: String) -> [RedisPair] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
            return RedisPair(parts[0], parts.count > 1 ? parts[1] : "")
        }
    }

    var title: String {
        let verb = row == nil ? "Add" : "Edit"
        return switch kind {
        case .hash: "\(verb) Field"
        case .list: "\(verb) Element"
        case .set, .zset: "\(verb) Member"
        case .stream: "Add Entry"
        }
    }
}

private struct RedisMemberSheet: View {
    @State var draft: RedisMemberDraft
    let done: (RedisMemberDraft?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.title).font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
                switch draft.kind {
                case .hash:
                    GridRow { Text("Field:"); TextField("", text: $draft.first) }
                    GridRow(alignment: .top) { Text("Value:"); editor($draft.second) }
                case .list:
                    if draft.row == nil {
                        GridRow {
                            Text("Insert:")
                            Picker("", selection: $draft.atHead) {
                                Text("At the end (RPUSH)").tag(false)
                                Text("At the start (LPUSH)").tag(true)
                            }
                            .labelsHidden().fixedSize()
                        }
                    } else {
                        GridRow { Text("Index:"); Text(draft.first).foregroundStyle(.secondary) }
                    }
                    GridRow(alignment: .top) { Text("Value:"); editor($draft.second) }
                case .set:
                    GridRow(alignment: .top) { Text("Member:"); editor($draft.first) }
                case .zset:
                    GridRow(alignment: .top) { Text("Member:"); editor($draft.first) }
                    GridRow { Text("Score:"); TextField("", text: $draft.second).frame(width: 140) }
                case .stream:
                    GridRow { Text("ID:"); TextField("", text: $draft.first, prompt: Text("* (generated)")).frame(width: 220) }
                    GridRow(alignment: .top) {
                        Text("Fields:")
                        VStack(alignment: .leading, spacing: 4) {
                            editor($draft.second)
                            Text("One “field value” pair per line.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                if draft.kind == .zset, Double(draft.second) == nil {
                    Label("The score must be a number.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                }
                Spacer()
                Button("Cancel", role: .cancel) { done(nil) }.keyboardShortcut(.cancelAction)
                Button(draft.row == nil ? "Add" : "Save") { done(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(18)
        .frame(width: 480)
    }

    private var isValid: Bool {
        switch draft.kind {
        case .hash: !draft.first.isEmpty
        case .zset: !draft.first.isEmpty && Double(draft.second) != nil
        case .stream: !RedisMemberDraft.streamFields(draft.second).isEmpty
        case .list, .set: true
        }
    }

    private func editor(_ text: Binding<String>) -> some View {
        PlainTextEditor(text: text)
            .frame(minHeight: 90, maxHeight: 220)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
    }
}
