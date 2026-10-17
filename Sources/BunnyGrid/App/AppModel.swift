import AppKit
import BunnyGridCore
import Observation
import SwiftUI

/// What the connection editor sheet is working on.
struct ConnectionDraft: Identifiable {
    var config: ConnectionConfig
    var password: String
    var isNew: Bool

    var id: UUID { config.id }
}

/// Top-level app state: saved connections, open sessions, the navigator selection and the tabs.
@MainActor
@Observable
final class AppModel {
    private(set) var connections: [ConnectionConfig] = []
    private(set) var sessions: [UUID: Session] = [:]
    var draft: ConnectionDraft?
    var showingConnectionPicker = false
    /// The profile popover where the AI platform is chosen.
    var showingAccountMenu = false
    var alertMessage: String?
    private(set) var history: [QueryHistoryEntry] = []
    private(set) var savedQueries: [SavedQuery] = []
    private(set) var favorites: [FavoriteObject] = []
    private(set) var tableProfiles: [TableProfile] = []
    /// Connections starred from the navigator ("Add Star").
    private(set) var starredConnections: Set<UUID> = Set((UserDefaults.standard.stringArray(forKey: "starredConnections") ?? []).compactMap(UUID.init))
    /// Connection waiting for a group name ("Manage Group → New Group…").
    var groupingConnection: UUID?
    /// Which tab the right pane shows.
    var rightPane: RightPane = .info

    enum RightPane: String { case info, ai }
    var favoritesOnly = false
    /// Query tab waiting for a name in the Save Query sheet.
    var namingQuery: QueryTabModel?
    /// Table the Import Wizard sheet imports into.
    var importTarget: ImportTarget?
    /// Table the Data Generation sheet fills.
    var generationTarget: ImportTarget?

    // Navigator
    var navSelection: NavNode?
    var expanded: Set<NavNode> = [.myConnections]
    var navigatorFilter = ""

    // Workspace
    private(set) var tabs: [WorkspaceTab] = []
    /// nil selects the fixed "Objects" tab.
    var selectedTabID: UUID?
    /// Tab waiting for "discard unsaved changes?" confirmation.
    var tabPendingClose: WorkspaceTab?
    var objectCategory: ObjectCategory = .tables
    private var queryCounter = 0

    // Panes (remembered between launches)
    var showNavigator = UserDefaults.standard.object(forKey: "showNavigator") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showNavigator, forKey: "showNavigator") }
    }
    var showAssistant = UserDefaults.standard.object(forKey: "showAssistant") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showAssistant, forKey: "showAssistant") }
    }

    let assistant: AssistantModel
    let profile = ProfileModel(directory: AppModel.dataDirectory)

    @ObservationIgnored private let store: ConnectionStore
    @ObservationIgnored private let historyStore: QueryHistoryStore
    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private let savedQueryStore = JSONListStore<SavedQuery>(fileURL: AppModel.dataDirectory.appending(path: "queries.json"))
    @ObservationIgnored private let favoriteStore = JSONListStore<FavoriteObject>(fileURL: AppModel.dataDirectory.appending(path: "favorites.json"))
    @ObservationIgnored private let profileStore = JSONListStore<TableProfile>(fileURL: AppModel.dataDirectory.appending(path: "table-profiles.json"))

    init(
        store: ConnectionStore = ConnectionStore(fileURL: AppModel.dataDirectory.appending(path: "connections.json")),
        historyStore: QueryHistoryStore = QueryHistoryStore(fileURL: AppModel.dataDirectory.appending(path: "history.json")),
        keychain: KeychainStore = KeychainStore()
    ) {
        self.store = store
        self.historyStore = historyStore
        self.keychain = keychain
        self.assistant = AssistantModel(storeURL: AppModel.dataDirectory.appending(path: "ai-chats.json"))
        do {
            connections = try store.load()
        } catch {
            alertMessage = "Could not read saved connections: \(error.localizedDescription)"
        }
        history = (try? historyStore.load()) ?? []
        savedQueries = (try? savedQueryStore.load()) ?? []
        favorites = (try? favoriteStore.load()) ?? []
        tableProfiles = (try? profileStore.load()) ?? []
        for group in Set(connections.compactMap(\.group)) { expanded.insert(.group(group)) }
        assistant.app = self
        openLaunchArguments()
        // Plain launches restore the last session (Options › Tabs / Auto Recovery); launches with files or flags don't.
        if CommandLine.arguments.dropFirst().allSatisfy({ $0.hasPrefix("-NS") || $0.hasPrefix("-Apple") }) {
            restoreWorkspaceIfNeeded()
        }
        markWorkspaceRunning()
        startAutosave()
        // Connections marked "Auto connect" (Advanced tab) open at launch.
        for config in connections where config.autoConnect == true && sessions[config.id] == nil {
            connect(config.id)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveWorkspace(cleanExit: true) }
        }
    }

    /// Application Support/BunnyGrid, or `BUNNYGRID_DATA_DIR` for development and tests.
    static var dataDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["BUNNYGRID_DATA_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return ConnectionStore.defaultFileURL.deletingLastPathComponent()
    }

    func connection(id: UUID) -> ConnectionConfig? {
        connections.first { $0.id == id }
    }

    var groups: [String] {
        Array(Set(connections.compactMap(\.group))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Selection-derived state

    var selectedTab: WorkspaceTab? {
        tabs.first { $0.id == selectedTabID }
    }

    var selectedTableTab: TableTabModel? {
        if case .table(let model) = selectedTab { model } else { nil }
    }

    var selectedQueryTab: QueryTabModel? {
        if case .query(let model) = selectedTab { model } else { nil }
    }

    func select(_ query: QueryTabModel) {
        selectedTabID = query.id
    }

    /// The editor that chat code goes into: the selected query tab, else the most recent one.
    var activeQueryTab: QueryTabModel? {
        if let selectedQueryTab { return selectedQueryTab }
        for tab in tabs.reversed() { if case .query(let model) = tab { return model } }
        return nil
    }

    /// The database the navigator points at, falling back to the open tab's database.
    var currentContext: DatabaseContext? {
        if let node = navSelection, let id = node.connectionID, let session = sessions[id] {
            if let db = node.databaseName { return session.context(db) }
            return session.contexts.values.first
        }
        if let tab = selectedTableTab, let id = tab.connectionID {
            return sessions[id]?.context(tab.databaseName)
        }
        return nil
    }

    var currentSchema: String? {
        navSelection?.schemaName ?? currentContext?.defaultSchema
    }

    /// "payment @dvdrental.public (PostgreSQL) - Table - BunnyGrid".
    var windowTitle: String {
        guard let tab = selectedTab else { return "BunnyGrid" }
        return "\(tab.title) - \(tab.kindName) - BunnyGrid"
    }

    // MARK: - Editing connections

    /// Shows the New Connection picker; with a kind, goes straight to that kind's form.
    func newConnection(kind: DatabaseKind? = nil) {
        guard let kind else {
            showingConnectionPicker = true
            return
        }
        var config = ConnectionConfig(kind: kind)
        if case .group(let group) = navSelection { config.group = group }
        draft = ConnectionDraft(config: config, password: "", isNew: true)
    }

    func edit(_ id: UUID) {
        guard let config = connection(id: id) else { return }
        draft = ConnectionDraft(config: config, password: keychain.password(for: id) ?? "", isNew: false)
    }

    func duplicate(_ id: UUID) {
        guard var copy = connection(id: id) else { return }
        let password = keychain.password(for: id)
        copy.id = UUID()
        copy.name = copy.displayName + " copy"
        save(copy, password: password)
    }

    func save(_ config: ConnectionConfig, password: String?) {
        if let index = connections.firstIndex(where: { $0.id == config.id }) {
            connections[index] = config
        } else {
            connections.append(config)
        }
        keychain.setPassword(config.kind.isFileBased ? nil : password, for: config.id)
        persist()
        if sessions[config.id] != nil { disconnect(config.id) }
        if let group = config.group { expanded.insert(.group(group)) }
        navSelection = .connection(config.id)
    }

    func delete(_ id: UUID) {
        disconnect(id)
        connections.removeAll { $0.id == id }
        keychain.setPassword(nil, for: id)
        if navSelection?.connectionID == id { navSelection = nil }
        persist()
        clearHistory(for: id)
    }

    private func persist() {
        do {
            try store.save(connections)
        } catch {
            alertMessage = "Could not save connections: \(error.localizedDescription)"
        }
    }

    func makeDriver(for config: ConnectionConfig, password: String?) -> any DatabaseDriver {
        DriverFactory.make(config: config, password: password)
    }

    // MARK: - Sessions

    @discardableResult
    func connect(_ id: UUID) -> Session? {
        guard let config = connection(id: id) else { return nil }
        if let existing = sessions[id], !existing.isFailed { return existing }
        let session = Session(config: config, keychain: keychain)
        session.onQueryExecuted = { [weak self] entry in self?.record(entry) }
        sessions[id] = session
        expanded.insert(.connection(id))
        Task {
            await session.connect()
            if config.kind == .sqlite || !config.database.isEmpty {
                let db = config.kind == .sqlite ? "main" : config.database
                expanded.insert(.database(id, db))
                if config.kind == .postgresql { expanded.insert(.schema(id, db, "public")) }
            }
        }
        return session
    }

    func disconnect(_ id: UUID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        for tab in tabs where tab.connectionID == id { closeTab(tab.id) }
        session.close()
        expanded = expanded.filter { $0.connectionID != id }
    }

    /// Expanding a node in the navigator opens what it represents.
    func setExpanded(_ node: NavNode, _ isExpanded: Bool) {
        if isExpanded { expanded.insert(node) } else { expanded.remove(node) }
        guard isExpanded else { return }
        switch node {
        case .connection(let id):
            connect(id)
        case .database(let id, let db):
            sessions[id]?.openDatabase(db)
        case .schema(let id, let db, let schema):
            if let context = sessions[id]?.context(db) {
                Task { await context.loadObjects(schema: schema) }
            }
        default:
            break
        }
    }

    /// Double-click on a navigator node.
    func activate(_ node: NavNode) {
        switch node {
        case .connection, .database, .schema:
            setExpanded(node, !expanded.contains(node))
        case .category(_, _, _, let category):
            objectCategory = category
            selectedTabID = nil
        case .object(let id, let db, let object):
            guard object.kind != .routine, let context = sessions[id]?.context(db) else { return }
            openTable(object, in: context)
        case .savedQuery(let id, let db, let queryID):
            guard let context = sessions[id]?.context(db), let saved = savedQueries.first(where: { $0.id == queryID }) else { return }
            openSavedQuery(saved, in: context)
        default:
            break
        }
    }

    /// Single click: selecting a folder shows its objects in the Objects tab, as in Navicat.
    func select(_ node: NavNode?) {
        navSelection = node
        if case .category(_, _, _, let category) = node {
            objectCategory = category
            selectedTabID = nil
        }
    }

    /// The main toolbar's object-type buttons show that kind of object for the current schema.
    func showCategory(_ category: ObjectCategory) {
        objectCategory = category
        selectedTabID = nil
        if let context = currentContext, let id = context.session?.id {
            let schema = context.usesSchemas ? currentSchema : nil
            navSelection = .category(id, context.name, schema, category)
            expanded.insert(.database(id, context.name))
            if let schema { expanded.insert(.schema(id, context.name, schema)) }
        }
    }

    /// Selects and reveals the open tab's object in the navigator.
    func revealSelectedTab() {
        guard let tab = selectedTableTab, let id = tab.connectionID else { return }
        expanded.insert(.myConnections)
        if let group = connection(id: id)?.group { expanded.insert(.group(group)) }
        expanded.insert(.connection(id))
        expanded.insert(.database(id, tab.databaseName))
        let usesSchemas = sessions[id]?.context(tab.databaseName)?.usesSchemas == true
        let schema = usesSchemas ? tab.object.schema : nil
        if let schema { expanded.insert(.schema(id, tab.databaseName, schema)) }
        let category: ObjectCategory = switch tab.object.kind {
        case .table: .tables
        case .view: .views
        case .materializedView: .materializedViews
        case .routine: .functions
        }
        expanded.insert(.category(id, tab.databaseName, schema, category))
        navSelection = .object(id, tab.databaseName, tab.object)
    }

    func collapseNavigator() {
        expanded = [.myConnections]
    }

    // MARK: - Tabs

    func openTable(_ object: DatabaseObject, in context: DatabaseContext) {
        // Options › Tabs › "Allow opening multiple forms for same object".
        if !AppOptions.shared.values.allowMultipleForms, let existing = tabs.first(where: {
            if case .table(let model) = $0 {
                model.object == object && model.databaseName == context.name && model.connectionID == context.session?.id
            } else {
                false
            }
        }) {
            selectedTabID = existing.id
            return
        }
        let tab = WorkspaceTab.table(TableTabModel(object: object, context: context))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func openQuery(text: String = "", in context: DatabaseContext? = nil) {
        guard let context = context ?? currentContext ?? sessions.values.lazy.compactMap({ $0.contexts.values.first }).first else {
            alertMessage = "Open a connection and a database first."
            return
        }
        queryCounter += 1
        let tab = WorkspaceTab.query(QueryTabModel(title: "Query \(queryCounter)", text: text, context: context))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func openSavedQuery(_ saved: SavedQuery, in context: DatabaseContext) {
        if let existing = tabs.first(where: {
            if case .query(let model) = $0 { model.savedQueryID == saved.id } else { false }
        }) {
            selectedTabID = existing.id
            return
        }
        let tab = WorkspaceTab.query(QueryTabModel(saved: saved, context: context))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    /// Design Table for an existing table, or New Table when `table` is nil.
    func openDesign(table: DatabaseObject?, in context: DatabaseContext) {
        if let table, let existing = tabs.first(where: {
            if case .design(let model) = $0 {
                !model.isNew && model.tableName == table.name && model.databaseName == context.name && model.connectionID == context.session?.id
            } else {
                false
            }
        }) {
            selectedTabID = existing.id
            return
        }
        let schema = context.usesSchemas ? (table?.schema ?? currentSchema ?? context.defaultSchema) : nil
        let tab = WorkspaceTab.design(TableDesignModel(context: context, schema: schema, table: table?.name))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    // MARK: - Save (⌘S)

    /// Saves whatever the selected tab holds: grid edits, the query, or the table design.
    func saveCurrent() {
        switch selectedTab {
        case .table(let model):
            Task { await model.applyChanges() }
        case .query(let model):
            saveQuery(model)
        case .design(let model):
            Task {
                if await model.save() == false, let error = model.saveError {
                    alertMessage = error
                    model.saveError = nil
                }
            }
        case nil:
            break
        }
    }

    var canSaveCurrent: Bool {
        switch selectedTab {
        case .table(let model): model.hasChanges
        case .query(let model): !model.text.isEmpty
        case .design(let model): model.hasChanges
        case nil: false
        }
    }

    // MARK: - Saved queries

    func savedQueries(connectionID: UUID, database: String) -> [SavedQuery] {
        savedQueries.filter { $0.connectionID == connectionID && $0.database == database }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Updates a saved query in place, or asks for a name the first time.
    func saveQuery(_ tab: QueryTabModel, name: String? = nil) {
        guard let connectionID = tab.connectionID else { return }
        if let id = tab.savedQueryID, let index = savedQueries.firstIndex(where: { $0.id == id }) {
            savedQueries[index].sql = tab.text
            savedQueries[index].updatedAt = Date()
            tab.markSaved(id: id, name: savedQueries[index].name)
        } else if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            let saved = SavedQuery(connectionID: connectionID, database: tab.databaseName, name: name, sql: tab.text)
            savedQueries.append(saved)
            tab.markSaved(id: saved.id, name: name)
        } else {
            namingQuery = tab
            return
        }
        persistSavedQueries()
    }

    func deleteSavedQuery(_ id: UUID) {
        savedQueries.removeAll { $0.id == id }
        persistSavedQueries()
    }

    private func persistSavedQueries() {
        do { try savedQueryStore.save(savedQueries) } catch { alertMessage = "Could not save queries: \(error.localizedDescription)" }
    }

    // MARK: - Connection organization

    func toggleStar(_ id: UUID) {
        if starredConnections.contains(id) { starredConnections.remove(id) } else { starredConnections.insert(id) }
        UserDefaults.standard.set(starredConnections.map(\.uuidString), forKey: "starredConnections")
    }

    func setColor(_ color: ConnectionColor, for id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].color = color
        persist()
    }

    func move(_ id: UUID, toGroup group: String?) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        let name = group?.trimmingCharacters(in: .whitespaces)
        connections[index].group = (name?.isEmpty ?? true) ? nil : name
        if let name = connections[index].group { expanded.insert(.group(name)) }
        persist()
    }

    /// Opens a .sql file in a new query tab on the connection's first open database and runs it.
    func executeSQLFile(connectionID: UUID) {
        guard let context = sessions[connectionID]?.contexts.values.first else {
            alertMessage = "Open a database on this connection first."
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "sql") ?? .plainText, .plainText]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        openQuery(text: text, in: context)
        selectedQueryTab?.title = url.deletingPathExtension().lastPathComponent
        selectedQueryTab?.run()
    }

    // MARK: - Table profiles

    func profiles(for tab: TableTabModel) -> [TableProfile] {
        tableProfiles.filter {
            $0.connectionID == tab.connectionID && $0.database == tab.databaseName && $0.schema == tab.object.schema && $0.table == tab.object.name
        }
    }

    func saveProfile(_ profile: TableProfile) {
        tableProfiles.removeAll { $0.connectionID == profile.connectionID && $0.database == profile.database
            && $0.schema == profile.schema && $0.table == profile.table && $0.name == profile.name }
        tableProfiles.append(profile)
        try? profileStore.save(tableProfiles)
    }

    func deleteProfile(_ id: UUID) {
        tableProfiles.removeAll { $0.id == id }
        try? profileStore.save(tableProfiles)
    }

    // MARK: - Favorites

    func isFavorite(_ object: DatabaseObject, connectionID: UUID, database: String) -> Bool {
        favorites.contains { $0.connectionID == connectionID && $0.database == database && $0.schema == object.schema && $0.name == object.name }
    }

    func toggleFavorite(_ object: DatabaseObject, connectionID: UUID, database: String) {
        if isFavorite(object, connectionID: connectionID, database: database) {
            favorites.removeAll { $0.connectionID == connectionID && $0.database == database && $0.schema == object.schema && $0.name == object.name }
        } else {
            favorites.append(FavoriteObject(connectionID: connectionID, database: database, schema: object.schema, name: object.name, kind: object.kind))
        }
        try? favoriteStore.save(favorites)
    }

    /// Opens a favorite, connecting and opening its database first if needed.
    func openFavorite(_ favorite: FavoriteObject) {
        guard let session = connect(favorite.connectionID) else { return }
        Task {
            var attempts = 0
            while !session.isConnected && !session.isFailed && attempts < 200 {
                attempts += 1
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard session.isConnected else { return }
            let context = session.openDatabase(favorite.database)
            attempts = 0
            while !context.isOpen && !context.isFailed && attempts < 200 {
                attempts += 1
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard context.isOpen else { return }
            openTable(favorite.object, in: context)
        }
    }

    /// Closes a tab, asking first when it holds unsaved work.
    func requestClose(_ tab: WorkspaceTab) {
        if tab.hasUnsavedChanges { tabPendingClose = tab } else { closeTab(tab.id) }
    }

    /// ⌘W: close the selected tab; with only the Objects tab showing, close the window.
    func closeSelectedTabOrWindow() {
        if let tab = selectedTab {
            requestClose(tab)
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    func selectAdjacentTab(_ offset: Int) {
        // Objects (nil) is position 0, followed by the open tabs.
        let order: [UUID?] = [nil] + tabs.map { Optional($0.id) }
        guard let current = order.firstIndex(of: selectedTabID) else { return }
        selectedTabID = order[(current + offset + order.count) % order.count]
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].cancel()
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    // MARK: - History

    func history(for connectionID: UUID) -> [QueryHistoryEntry] {
        history.filter { $0.connectionID == connectionID }
    }

    private func record(_ entry: QueryHistoryEntry) {
        DiagnosticLog.write("[query] \(String(format: "%.1f", entry.durationMilliseconds)) ms\(entry.rowCount.map { ", \($0) rows" } ?? "")\(entry.error.map { ", error: \($0)" } ?? ""): \(entry.sql.replacingOccurrences(of: "\n", with: " "))")
        history = historyStore.adding(entry, to: history)
        let snapshot = history
        let store = historyStore
        Task.detached(priority: .utility) { try? store.save(snapshot) }
    }

    func clearHistory(for connectionID: UUID) {
        history.removeAll { $0.connectionID == connectionID }
        try? historyStore.save(history)
    }

    // MARK: - SQLite files

    func presentOpenSQLitePanel() {
        let panel = NSOpenPanel()
        panel.title = "Open SQLite Database"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openSQLiteFile(url)
    }

    func openSQLiteFile(_ url: URL) {
        let path = url.path
        if let existing = connections.first(where: { $0.kind == .sqlite && $0.filePath == path }) {
            connect(existing.id)
            navSelection = .connection(existing.id)
            return
        }
        let config = ConnectionConfig(name: url.lastPathComponent, kind: .sqlite, filePath: path)
        save(config, password: nil)
        connect(config.id)
    }

    // MARK: - Launch arguments

    /// Opens SQLite files passed on the command line (`BunnyGrid path/to/db.sqlite`).
    /// For development and screenshots, `--open-table NAME` and `--query SQL` open tabs once connected.
    private func openLaunchArguments() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var tableName: String?
        var query: String?
        var opened: UUID?
        var database = "main"
        while let flag = arguments.first {
            arguments.removeFirst()
            switch flag {
            case "--open-table" where !arguments.isEmpty: tableName = arguments.removeFirst()
            case "--query" where !arguments.isEmpty: query = arguments.removeFirst()
            case "--connect-first":
                guard let first = connections.first else { continue }
                connect(first.id)
                navSelection = .connection(first.id)
                opened = first.id
                database = first.kind == .sqlite ? "main" : first.database
                if let group = first.group { expanded.insert(.group(group)) }
            default:
                guard !flag.hasPrefix("-"), FileManager.default.fileExists(atPath: flag) else { continue }
                openSQLiteFile(URL(fileURLWithPath: flag).standardizedFileURL)
                opened = navSelection?.connectionID
            }
        }
        #if DEBUG
        if let flagIndex = CommandLine.arguments.firstIndex(where: { $0 == "--design" || $0 == "--new-table" }), let id = opened {
            let args = CommandLine.arguments
            let tableName = args[flagIndex] == "--design" && args.indices.contains(flagIndex + 1) ? args[flagIndex + 1] : nil
            Task {
                while sessions[id]?.context(database)?.isOpen != true { try? await Task.sleep(for: .milliseconds(50)) }
                guard let context = sessions[id]?.context(database) else { return }
                let object = tableName.flatMap { name in context.objects(in: context.defaultSchema)?.first { $0.name == name } }
                openDesign(table: object, in: context)
                if case .design(let model) = selectedTab, tableName != nil {
                    try? await Task.sleep(for: .milliseconds(300))
                    model.addField()
                    model.columns[1].name = "full_name"
                }
            }
        }
        #if DEBUG
        if CommandLine.arguments.contains("--new-connection") { showingConnectionPicker = true }
        if CommandLine.arguments.contains("--account-menu") { showingAccountMenu = true }
        if CommandLine.arguments.contains("--ai-pane") { showAssistant = true; rightPane = .ai }
        if CommandLine.arguments.contains("--ai-wide") { assistant.isExpanded = true }
        if let index = CommandLine.arguments.firstIndex(of: "--ai-ask"), CommandLine.arguments.indices.contains(index + 1) {
            let prompt = CommandLine.arguments[index + 1]
            Task {
                try? await Task.sleep(for: .seconds(1))
                assistant.draft = prompt
                assistant.send()
                guard CommandLine.arguments.contains("--ai-compare") else { return }
                while assistant.isStreaming { try? await Task.sleep(for: .milliseconds(100)) }
                if let last = assistant.currentChat?.messages.last, let other = assistant.compareAssistants.first {
                    assistant.compare(last.id, with: other)
                }
            }
        }
        #endif
        if CommandLine.arguments.contains("--show-objects"), let id = opened {
            Task {
                while sessions[id]?.context(database)?.isOpen != true { try? await Task.sleep(for: .milliseconds(50)) }
                let schema = sessions[id]?.context(database)?.defaultSchema
                expanded.insert(.category(id, database, schema, .tables))
                select(.category(id, database, schema, .tables))
            }
        }
        #endif
        guard tableName != nil || query != nil, let id = opened else { return }
        Task {
            while sessions[id]?.context(database)?.isOpen != true { try? await Task.sleep(for: .milliseconds(50)) }
            guard let context = sessions[id]?.context(database) else { return }
            if let query {
                openQuery(text: query, in: context)
                selectedQueryTab?.run()
                #if DEBUG
                if let index = CommandLine.arguments.firstIndex(of: "--ask-ai"), CommandLine.arguments.indices.contains(index + 1),
                   let tab = selectedQueryTab {
                    try? await Task.sleep(for: .milliseconds(800))
                    while tab.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
                    let name = CommandLine.arguments[index + 1]
                    if name == "custom" {
                        tab.showingAskAICustom = true
                    } else if let action = AIBuiltinAction(rawValue: name) {
                        AskAI.run(action, on: tab, app: self)
                    }
                }
                #endif
            }
            if let tableName, let object = context.objects(in: context.defaultSchema)?.first(where: { $0.name == tableName }) {
                expanded.insert(.category(id, database, context.defaultSchema, .tables))
                navSelection = .object(id, database, object)
                openTable(object, in: context)
                #if DEBUG
                if let tab = selectedTableTab, ["--demo-edits", "--focus-cell", "--begin-transaction", "--generate", "--profile"].contains(where: CommandLine.arguments.contains) {
                    await tab.loadIfNeeded()
                    if CommandLine.arguments.contains("--demo-edits") {
                        tab.setValue(.text("Edited name"), row: 1, column: 1)
                        tab.toggleDelete([4, 5])
                        tab.addRow()
                        tab.setValue(.text("New customer"), row: tab.page?.rows.count ?? 0, column: 1)
                        tab.scroll(toRow: 0)
                    }
                    if CommandLine.arguments.contains("--begin-transaction") {
                        await tab.beginTransaction(session: sessions[id])
                        tab.setValue(.text("9.99"), row: 0, column: 4)
                    }
                    if CommandLine.arguments.contains("--profile") {
                        tab.showProfiling = true
                    }
                    if CommandLine.arguments.contains("--generate") {
                        generationTarget = ImportTarget(context: context, object: object)
                    }
                    if CommandLine.arguments.contains("--focus-cell") {
                        tab.focusedCell = GridCell(row: 4, column: 2)
                        tab.selectedRows = [4]
                    }
                }
                #endif
            }
        }
    }
}

/// What the Import Wizard imports into.
struct ImportTarget: Identifiable {
    let id = UUID()
    let context: DatabaseContext
    let object: DatabaseObject
}
