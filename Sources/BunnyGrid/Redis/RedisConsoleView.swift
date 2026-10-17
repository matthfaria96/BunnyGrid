import AppKit
import BunnyGridCore
import SwiftUI

/// redis-cli in a tab: prompt with the database, colored replies (errors red, integers blue, nil gray),
/// multi-line output, ↑/↓ history, "clear". Several lines pasted at once run in order.
struct RedisConsoleView: View {
    @Bindable var model: RedisConsoleModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        Text("Redis console. Commands run on this tab's own connection; SELECT switches its database. Type “clear” to clear.")
                            .foregroundStyle(.secondary)
                        ForEach(model.entries) { entry in
                            RedisConsoleEntryView(entry: entry, prompt: prompt(for: entry.database))
                                .id(entry.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.entries.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            HStack(spacing: 6) {
                Text(model.prompt).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.red)
                TextField("Command", text: $model.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit { Task { await model.run() } }
                    .onKeyPress(.upArrow) { model.step(-1); return .handled }
                    .onKeyPress(.downArrow) { model.step(1); return .handled }
                if model.isRunning { ProgressView().controlSize(.mini) }
                IconButton(systemImage: "play.fill", help: "Run (↩)", isEnabled: !model.isRunning) { Task { await model.run() } }
                IconButton(systemImage: "trash", help: "Clear the output") { model.clear() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .task {
            if !model.isConnected { await model.connect() }
            inputFocused = true
        }
    }

    private func prompt(for database: Int) -> String {
        let base = model.prompt
        guard let bracket = base.firstIndex(of: "[") ?? base.firstIndex(of: ">") else { return base }
        return String(base[..<bracket]) + (database == 0 ? "> " : "[\(database)]> ")
    }
}

private struct RedisConsoleEntryView: View {
    let entry: RedisConsoleModel.Entry
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !entry.command.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(prompt).foregroundStyle(.red.opacity(0.8))
                    Text(entry.command).fontWeight(.semibold)
                    Spacer(minLength: 8)
                    Text(String(format: "%.1f ms", Double(entry.duration.components.attoseconds) / 1e15 + Double(entry.duration.components.seconds) * 1000))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            if let error = entry.error {
                Text("(error) " + error).foregroundStyle(.red)
            } else if let reply = entry.reply {
                Text(RedisCommandLine.render(reply)).foregroundStyle(color(reply))
            }
        }
    }

    private func color(_ reply: RESPValue) -> Color {
        switch reply {
        case .error: .red
        case .integer, .double, .bigNumber, .boolean: .blue
        case .null: .secondary
        case .simpleString: .green
        default: .primary
        }
    }
}

/// Server Monitor: headline numbers, every INFO section, connected clients and the slow log.
struct RedisServerView: View {
    @Bindable var model: RedisServerModel
    @State private var pane: Pane = .info

    enum Pane: String, CaseIterable, Identifiable {
        case info = "Info", clients = "Clients", slowlog = "Slow Log"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $pane) {
                    ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Toggle("Auto Refresh (2 s)", isOn: $model.autoRefresh).toggleStyle(.checkbox)
                IconButton(systemImage: "arrow.clockwise", help: "Refresh") { Task { await model.refresh() } }
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .frame(height: 34)
            Divider()
            metrics
            Divider()
            switch pane {
            case .info: infoList
            case .clients: clientsTable
            case .slowlog: slowlogTable
            }
        }
        .task { if model.lastRefresh == nil { await model.refresh() } }
    }

    private var metrics: some View {
        let items: [(String, String, String)] = [
            ("Version", model.value("redis_version") ?? "–", "info.circle"),
            ("Uptime", model.value("uptime_in_seconds").flatMap(Int64.init).map(RedisTTLEditor.describe) ?? "–", "clock"),
            ("Clients", model.value("connected_clients") ?? "–", "person.2"),
            ("Memory", model.value("used_memory_human") ?? "–", "memorychip"),
            ("Ops/s", model.value("instantaneous_ops_per_sec") ?? "–", "speedometer"),
            ("Hit Rate", model.hitRate.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "–", "target"),
            ("Role", model.value("role") ?? "–", "point.3.connected.trianglepath.dotted"),
        ]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(items, id: \.0) { title, value, symbol in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(title, systemImage: symbol).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Text(value).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(minWidth: 110, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
                }
            }
            .padding(10)
        }
    }

    private var infoList: some View {
        List {
            if let error = model.error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            ForEach(model.sections) { section in
                Section(section.name) {
                    ForEach(section.entries) { entry in
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.key).foregroundStyle(.secondary).frame(width: 260, alignment: .leading)
                            Text(entry.value).textSelection(.enabled).lineLimit(2)
                        }
                        .font(.system(size: 12, design: .monospaced))
                    }
                }
            }
        }
    }

    private struct ClientRow: Identifiable {
        let id: String
        let fields: [String: String]
    }

    private var clientsTable: some View {
        let rows = model.clients.enumerated().map { ClientRow(id: $1["id"] ?? String($0), fields: $1) }
        return Table(rows) {
            TableColumn("ID") { Text($0.id) }.width(50)
            TableColumn("Address") { Text($0.fields["addr"] ?? "") }
            TableColumn("Name") { Text($0.fields["name"] ?? "") }
            TableColumn("DB") { Text($0.fields["db"] ?? "") }.width(40)
            TableColumn("User") { Text($0.fields["user"] ?? "") }
            TableColumn("Age (s)") { Text($0.fields["age"] ?? "") }.width(60)
            TableColumn("Idle (s)") { Text($0.fields["idle"] ?? "") }.width(60)
            TableColumn("Last Command") { Text($0.fields["cmd"] ?? "") }
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private var slowlogTable: some View {
        Table(model.slowlog) {
            TableColumn("ID") { Text(String($0.id)) }.width(50)
            TableColumn("Time") { Text($0.timestamp.formatted(date: .abbreviated, time: .standard)) }.width(170)
            TableColumn("Duration (µs)") { Text($0.durationMicroseconds.formatted()) }.width(100)
            TableColumn("Command") { Text($0.command).lineLimit(1).help($0.command) }
            TableColumn("Client") { Text($0.client) }.width(140)
        }
        .font(.system(size: 12, design: .monospaced))
        .overlay {
            if model.slowlog.isEmpty { Text("The slow log is empty.").foregroundStyle(.secondary) }
        }
    }
}
