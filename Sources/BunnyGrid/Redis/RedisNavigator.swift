import AppKit
import BunnyGridCore
import SwiftUI

/// Where the New Key sheet creates its key.
struct RedisNewKeyTarget: Identifiable {
    let id = UUID()
    let connectionID: UUID
    let database: Int
    /// Folder the key was created from ("user:"), pre-filled in the name.
    var prefix = ""
}

// MARK: - Navigator rows

extension NavigatorView {
    /// Under an expanded Redis database: the filter row, folders and keys built from the SCANned keys, and Load More.
    static func appendRedisKeys(app: AppModel, session: Session, database: String, depth: Int, filter: String, to rows: inout [NavRow]) {
        guard let browser = session.redis, let index = RedisBrowserModel.index(of: database) else { return }
        let id = session.id
        let db = browser.keys(index)
        let needle = filter.lowercased()

        func matches(_ node: RedisKeyTree.Node) -> Bool {
            switch node {
            case .key(_, let entry): entry.key.lowercased().contains(needle)
            case .folder(_, _, let children, _): children.contains(where: matches)
            }
        }

        func append(_ nodes: [RedisKeyTree.Node], depth: Int) {
            for node in nodes where needle.isEmpty || matches(node) {
                switch node {
                case .folder(let name, let path, let children, let count):
                    let navNode = NavNode.redisFolder(id, index, path)
                    let expanded = app.expanded.contains(navNode) || !needle.isEmpty
                    var row = NavRow(node: navNode, depth: depth, title: name.isEmpty ? "(empty)" : name, icon: "folder.fill",
                                     iconColor: .yellow, isExpandable: true, isExpanded: expanded)
                    row.subtitle = "(\(count))"
                    rows.append(row)
                    if expanded { append(children, depth: depth + 1) }
                case .key(let name, let entry):
                    var row = NavRow(node: .redisKey(id, index, entry.key), depth: depth, title: name.isEmpty ? "(empty)" : name,
                                     icon: entry.type?.systemImage ?? "key", iconColor: entry.type?.tint ?? .secondary)
                    row.subtitle = nil
                    rows.append(row)
                }
            }
        }

        append(db.tree, depth: depth)
        if db.isLoading && db.keys.isEmpty {
            var row = NavRow(node: .redisMore(id, index), depth: depth, title: "Scanning…", icon: "ellipsis", isDisabled: true)
            row.isLoading = true
            rows.append(row)
        } else if let error = db.error {
            var row = NavRow(node: .redisMore(id, index), depth: depth, title: "Could not scan keys", icon: "exclamationmark.triangle")
            row.warning = error
            rows.append(row)
        } else if !db.isComplete {
            var row = NavRow(node: .redisMore(id, index), depth: depth, title: "Load More Keys…", icon: "arrow.down.circle",
                             iconColor: .accentColor)
            row.subtitle = "\(db.keys.count.formatted()) loaded"
            row.isLoading = db.isLoading
            rows.append(row)
        } else if db.keys.isEmpty {
            rows.append(NavRow(node: .redisMore(id, index), depth: depth, title: "No keys", icon: "tray", isDisabled: true))
        }
    }
}

extension AppModel {
    var redisSelection: (session: Session, database: Int)? {
        guard let node = navSelection, let id = node.connectionID, let session = sessions[id], session.redis != nil else { return nil }
        switch node {
        case .database(_, let db): return RedisBrowserModel.index(of: db).map { (session, $0) }
        case .redisFolder(_, let db, _), .redisKey(_, let db, _), .redisMore(_, let db): return (session, db)
        default: return (session, (session.driver as? RedisDriver)?.defaultDatabase ?? 0)
        }
    }

    /// Double-click / Return on a Redis navigator row.
    func activateRedis(_ node: NavNode) {
        switch node {
        case .redisFolder:
            setExpanded(node, !expanded.contains(node))
        case .redisKey(let id, let db, let key):
            openRedisKey(key, database: db, connectionID: id)
        case .redisMore(let id, let db):
            if let browser = sessions[id]?.redis {
                if browser.keys(db).error != nil { browser.reload(db) } else { Task { await browser.loadMore(db) } }
            }
        default:
            break
        }
    }

    func openRedisKey(_ key: String, database: Int, connectionID: UUID) {
        guard let session = sessions[connectionID], let browser = session.redis else { return }
        if let existing = tabs.first(where: {
            if case .redis(let model) = $0, case .key(let keyModel) = model.content {
                model.connectionID == connectionID && keyModel.database == database && keyModel.key == key
            } else {
                false
            }
        }) {
            selectedTabID = existing.id
            return
        }
        let model = RedisKeyModel(database: database, key: key, driver: browser.driver, browser: browser)
        openTab(.redis(RedisTabModel(content: .key(model), session: session)))
    }

    /// Console tab with its own connection, starting on `database`.
    func openRedisConsole(connectionID: UUID, database: Int? = nil) {
        guard let session = sessions[connectionID], let driver = session.makeDedicatedDriver(database: "") as? RedisDriver else { return }
        let start = database ?? redisSelection?.database ?? driver.defaultDatabase
        let model = RedisConsoleModel(driver: driver, database: start)
        openTab(.redis(RedisTabModel(content: .console(model), session: session)))
    }

    func openRedisServerMonitor(connectionID: UUID) {
        guard let session = sessions[connectionID], let browser = session.redis else { return }
        if let existing = tabs.first(where: {
            if case .redis(let model) = $0, case .server = model.content { model.connectionID == connectionID } else { false }
        }) {
            selectedTabID = existing.id
            return
        }
        openTab(.redis(RedisTabModel(content: .server(RedisServerModel(driver: browser.driver)), session: session)))
    }

    func deleteRedisKeys(_ keys: [String], database: Int, connectionID: UUID) {
        guard let browser = sessions[connectionID]?.redis, !keys.isEmpty else { return }
        Task {
            do {
                try await browser.driver.delete(database: database, keys: keys)
                browser.didDelete(keys, in: database)
                for tab in tabs {
                    if case .redis(let model) = tab, case .key(let keyModel) = model.content, model.connectionID == connectionID,
                       keyModel.database == database, keys.contains(keyModel.key) {
                        closeTab(tab.id)
                    }
                }
            } catch {
                alertMessage = "Could not delete: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Context menus

struct RedisNavContextMenu: View {
    @Environment(AppModel.self) private var app
    let node: NavNode

    var body: some View {
        switch node {
        case .database(let id, let name):
            if let browser = app.sessions[id]?.redis, let index = RedisBrowserModel.index(of: name) {
                let readOnly = browser.driver.config.readOnly
                Button("New Key…") { app.redisNewKey = RedisNewKeyTarget(connectionID: id, database: index) }.disabled(readOnly)
                Button("Console") { app.openRedisConsole(connectionID: id, database: index) }
                Divider()
                Menu("Key Separator") {
                    ForEach([":", ".", "/", "_", "-", "|"], id: \.self) { separator in
                        Button(separator) { browser.separator = separator }
                    }
                    Button("None (flat list)") { browser.separator = "" }
                }
                Divider()
                Button("Refresh") { browser.reload(index) }
            }
        case .redisFolder(let id, let db, let prefix):
            if let browser = app.sessions[id]?.redis {
                Button("New Key…") { app.redisNewKey = RedisNewKeyTarget(connectionID: id, database: db, prefix: prefix) }
                    .disabled(browser.driver.config.readOnly)
                Button("Copy Prefix") { copy(prefix) }
                Divider()
                Button("Delete Loaded Keys in Folder…", role: .destructive) {
                    app.redisPendingDelete = RedisPendingDelete(connectionID: id, database: db, keys: browser.keys(under: prefix, in: db), label: prefix + "*")
                }
                .disabled(browser.driver.config.readOnly)
                Divider()
                Button("Refresh") { browser.reload(db) }
            }
        case .redisKey(let id, let db, let key):
            Button("Open Key") { app.openRedisKey(key, database: db, connectionID: id) }
            Button("Copy Key Name") { copy(key) }
            Divider()
            Button("Delete Key…", role: .destructive) {
                app.redisPendingDelete = RedisPendingDelete(connectionID: id, database: db, keys: [key], label: key)
            }
            .disabled(app.sessions[id]?.redis?.driver.config.readOnly ?? true)
        case .redisMore(let id, let db):
            Button("Load More Keys") { app.activateRedis(node) }
            Button("Refresh") { app.sessions[id]?.redis?.reload(db) }
        default:
            EmptyView()
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Connection menu items for Redis (in place of New Database / Execute SQL File).
struct RedisConnectionMenuItems: View {
    @Environment(AppModel.self) private var app
    let id: UUID

    var body: some View {
        let isOpen = app.sessions[id]?.isConnected == true
        Button("New Key…") {
            let db = (app.sessions[id]?.driver as? RedisDriver)?.defaultDatabase ?? 0
            app.redisNewKey = RedisNewKeyTarget(connectionID: id, database: db)
        }
        .disabled(!isOpen || app.connection(id: id)?.readOnly == true)
        Button("Console") { app.openRedisConsole(connectionID: id) }.disabled(!isOpen)
        Button("Server Monitor") { app.openRedisServerMonitor(connectionID: id) }.disabled(!isOpen)
    }
}

struct RedisPendingDelete: Identifiable {
    let id = UUID()
    let connectionID: UUID
    let database: Int
    let keys: [String]
    let label: String
}

/// The key filter (SCAN MATCH pattern and TYPE) shown above the tree while a Redis connection is selected.
struct RedisFilterBar: View {
    @Bindable var browser: RedisBrowserModel
    @State private var pattern = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "key.viewfinder").foregroundStyle(.secondary).font(.system(size: 12))
            TextField("SCAN pattern, e.g. user:*", text: $pattern)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit { browser.pattern = pattern }
            Menu {
                Button("All Types") { browser.typeFilter = nil }
                Divider()
                ForEach(RedisKeyType.allCases) { type in
                    Button { browser.typeFilter = type } label: {
                        Label(type.displayName, systemImage: browser.typeFilter == type ? "checkmark" : type.systemImage)
                    }
                }
            } label: {
                Text(browser.typeFilter?.displayName ?? "All Types").font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .glassBackground(in: Capsule())
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .onAppear { pattern = browser.pattern }
    }
}

// MARK: - New Key

struct RedisNewKeySheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: RedisNewKeyTarget

    @State private var key = ""
    @State private var type: RedisKeyType = .string
    @State private var field = ""
    @State private var value = ""
    @State private var score = "0"
    @State private var expires = false
    @State private var ttl = 3600
    @State private var error: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Key in db\(target.database)").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    Text("Key:").gridColumnAlignment(.trailing)
                    TextField("", text: $key, prompt: Text("user:1001"))
                }
                GridRow {
                    Text("Type:")
                    Picker("", selection: $type) {
                        ForEach(RedisKeyType.allCases) { Label($0.displayName, systemImage: $0.systemImage).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                if type == .hash || type == .stream {
                    GridRow { Text("Field:"); TextField("", text: $field) }
                }
                if type == .zset {
                    GridRow { Text("Score:"); TextField("", text: $score).frame(width: 120) }
                }
                GridRow(alignment: .top) {
                    Text(type == .set || type == .zset ? "Member:" : type == .json ? "JSON:" : "Value:")
                    PlainTextEditor(text: $value)
                        .frame(height: 110)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
                }
                GridRow {
                    Text("TTL:")
                    HStack {
                        Toggle("Expire after", isOn: $expires)
                        TextField("", value: $ttl, format: .number.grouping(.never)).frame(width: 90).disabled(!expires)
                        Text("seconds").foregroundStyle(.secondary)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || isSaving)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear { key = target.prefix }
    }

    private var isValid: Bool {
        guard !key.isEmpty else { return false }
        switch type {
        case .hash, .stream: return !field.isEmpty
        case .zset: return Double(score) != nil
        case .json: return JSONFormatter.validate(value.isEmpty ? "{}" : value) == nil
        default: return true
        }
    }

    private func create() async {
        guard let browser = app.sessions[target.connectionID]?.redis else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await browser.driver.createKey(database: target.database, key: key, type: type, field: Data(field.utf8), value: Data(value.utf8),
                                               score: Double(score) ?? 0, ttl: expires ? Int64(ttl) : nil)
            browser.didCreate(key, type: type, in: target.database)
            dismiss()
            app.openRedisKey(key, database: target.database, connectionID: target.connectionID)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
