import AppKit
import BunnyGridCore
import Observation
import SwiftUI

/// What the connection editor sheet is working on.
struct ConnectionDraft: Identifiable {
    var config: ConnectionConfig
    var password: String
    var isNew: Bool
    /// SSH password or private key passphrase (SSH tab), and the SSL client key passphrase. Keychain only.
    var sshSecret = ""
    var sslKeyPassphrase = ""

    var id: UUID { config.id }

    /// Everything the form holds that goes to the Keychain.
    var secrets: ConnectionSecrets {
        ConnectionSecrets(password: password, sshSecret: sshSecret, sslKeyPassphrase: sslKeyPassphrase)
    }
}

/// Top-level app state: saved connections, open sessions, the navigator selection and the tabs.
@MainActor
@Observable
final class AppModel {
    private(set) var connections: [ConnectionConfig] = []
    private(set) var sessions: [UUID: Session] = [:]
    var draft: ConnectionDraft?
    var showingConnectionPicker = false
    /// New Connection opens straight on "Create a Practice Database" (from the empty navigator).
    var connectionPickerStartsWithPractice = false
    /// The profile popover where the AI platform is chosen.
    var showingAccountMenu = false
    /// The first-launch welcome sheet (OnboardingView): Simple or Advanced, and the appearance.
    var showingOnboarding = false
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

    /// The right pane's tabs; which ones show depends on the open tab, as in Navicat.
    enum RightPane: String { case info, ddl, field, snippets, identifiers, ai }
    /// Navicat's Enter Focus Mode: navigator and right pane hidden until it is toggled off.
    private(set) var isFocusMode = false
    /// Items listed by the Index / Trigger buttons, for the status bar ("2 Indexes in main").
    var listedItemCount = 0
    /// Connection whose "New Database…" name prompt is showing.
    var creatingDatabaseFor: UUID?
    @ObservationIgnored private var panesBeforeFocus: (navigator: Bool, assistant: Bool)?
    var favoritesOnly = false
    /// Query tab waiting for a name in the Save Query sheet.
    var namingQuery: QueryTabModel?
    /// Table the Import Wizard sheet imports into.
    var importTarget: ImportTarget?
    /// Table the Data Generation sheet fills.
    var generationTarget: ImportTarget?
    /// Drop / empty / truncate / rename waiting for confirmation (ObjectActions.swift).
    var pendingObjectAction: PendingObjectAction?
    /// Export Wizard sheet target.
    var exportTarget: ExportTarget?
    /// Database the Execute SQL File sheet runs against.
    var sqlFileTarget: SQLFileTarget?
    /// Data Transfer / Data Synchronization / Structure Synchronization sheet.
    var syncWizard: SyncWizardRequest?
    /// Server whose User manager sheet is open.
    var usersSession: Session?
    /// Redis New Key sheet and key deletion waiting for confirmation (Redis/RedisNavigator.swift).
    var redisNewKey: RedisNewKeyTarget?
    var redisPendingDelete: RedisPendingDelete?

    // Navigator
    var navSelection: NavNode?
    var expanded: Set<NavNode> = [.myConnections]
    var navigatorFilter = ""

    // Workspace
    private(set) var tabs: [WorkspaceTab] = [] {
        didSet { updateSelectedTabKind() }
    }
    /// nil selects the fixed "Objects" tab.
    var selectedTabID: UUID? {
        didSet { updateSelectedTabKind() }
    }
    /// The kind of the selected tab, stored and only written when it changes: views that only care which kind of
    /// tab is open (the right pane's tabs, the status bar's layout) read this and skip switches between tabs of one kind.
    private(set) var selectedTabKind: WorkspaceTab.Kind?

    private func updateSelectedTabKind() {
        let kind = selectedTab?.kind
        if kind != selectedTabKind { selectedTabKind = kind }
    }
    /// Tab waiting for "discard unsaved changes?" confirmation.
    var tabPendingClose: WorkspaceTab?
    /// The app's model, for the app delegate (quitting with unsaved work asks first).
    @ObservationIgnored static weak var current: AppModel?

    /// Tabs whose work would be lost by quitting: pending grid edits, open transactions, modified queries,
    /// design changes, unsaved keys and documents.
    var tabsWithUnsavedChanges: [WorkspaceTab] { tabs.filter(\.hasUnsavedChanges) }
    var objectCategory: ObjectCategory = .tables
    private var queryCounter = 0

    // Panes (remembered between launches)
    var showNavigator = AppModel.savedPane("showNavigator") {
        didSet { AppModel.savePane(showNavigator, "showNavigator") }
    }
    var showAssistant = AppModel.savedPane("showAssistant") {
        didSet { AppModel.savePane(showAssistant, "showAssistant") }
    }

    /// Debug captures (`--window-size`) neither read nor write the remembered panes, so one capture can't hide
    /// the panes of the next, nor change what the user's own launches restore.
    private static var panesArePersisted: Bool {
        #if DEBUG
        !CommandLine.arguments.contains("--window-size")
        #else
        true
        #endif
    }

    private static func savedPane(_ key: String) -> Bool {
        panesArePersisted ? UserDefaults.standard.object(forKey: key) as? Bool ?? true : true
    }

    private static func savePane(_ value: Bool, _ key: String) {
        if panesArePersisted { UserDefaults.standard.set(value, forKey: key) }
    }

    let assistant: AssistantModel
    let profile = ProfileModel(directory: AppModel.dataDirectory)
    /// Batch jobs, schedules and backups (AutomationCenter.swift).
    let automation = AutomationCenter(dataDirectory: AppModel.dataDirectory)

    @ObservationIgnored private let store: ConnectionStore
    @ObservationIgnored private let historyStore: QueryHistoryStore
    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private let savedQueryStore = JSONListStore<SavedQuery>(fileURL: AppModel.dataDirectory.appending(path: "queries.json"))
    @ObservationIgnored private let favoriteStore = JSONListStore<FavoriteObject>(fileURL: AppModel.dataDirectory.appending(path: "favorites.json"))
    @ObservationIgnored private let profileStore = JSONListStore<TableProfile>(fileURL: AppModel.dataDirectory.appending(path: "table-profiles.json"))
    @ObservationIgnored private let snippetStore = JSONListStore<CodeSnippet>(fileURL: AppModel.dataDirectory.appending(path: "snippets.json"))
    /// The user's own code snippets (built-ins live in CodeSnippet.builtIns).
    private(set) var snippets: [CodeSnippet] = []

    init(
        store: ConnectionStore = ConnectionStore(fileURL: AppModel.dataDirectory.appending(path: "connections.json")),
        historyStore: QueryHistoryStore = QueryHistoryStore(fileURL: AppModel.dataDirectory.appending(path: "history.json")),
        keychain: KeychainStore = KeychainStore()
    ) {
        self.store = store
        self.historyStore = historyStore
        self.keychain = keychain
        self.assistant = AssistantModel(storeURL: AppModel.dataDirectory.appending(path: "ai-chats.json"))
        // An unreadable file is moved aside (not overwritten by the next save) and reported once.
        var problems: [String] = []
        func load<T>(_ url: URL, _ body: () throws -> [T]) -> [T] {
            let loaded = StoreQuarantine.load(url, body)
            if let problem = loaded.problem { problems.append(problem) }
            return loaded.elements
        }
        connections = load(store.fileURL) { try store.load() }
        history = load(historyStore.fileURL) { try historyStore.load() }
        savedQueries = load(savedQueryStore.fileURL) { try savedQueryStore.load() }
        favorites = load(favoriteStore.fileURL) { try favoriteStore.load() }
        tableProfiles = load(profileStore.fileURL) { try profileStore.load() }
        snippets = load(snippetStore.fileURL) { try snippetStore.load() }
        if !problems.isEmpty { alertMessage = problems.joined(separator: "\n") }
        AppModel.current = self
        for group in Set(connections.compactMap(\.group)) { expanded.insert(.group(group)) }
        assistant.app = self
        #if DEBUG || BUNNYGRID_BENCH
        Benchmarks.app = self
        #endif
        #if DEBUG
        UIHarness.shared.app = self
        #endif
        decideOnboarding()
        openLaunchArguments()
        runRedisLaunchFlags()
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

    /// First launch shows the welcome sheet; someone who used BunnyGrid before keeps Advanced without being asked.
    /// Launches that open a file or carry flags (captures, UI scenarios) are not covered by it, except with
    /// `--onboarding` (always shows it) or `--first-launch` (decides as a plain launch would).
    private func decideOnboarding() {
        let arguments = CommandLine.arguments.dropFirst()
        #if DEBUG
        let forced = arguments.contains("--onboarding")
        let asPlainLaunch = arguments.contains("--first-launch")
        #else
        let forced = false
        let asPlainLaunch = false
        #endif
        let opensSomething = arguments.contains { $0.hasPrefix("--") || (!$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0)) }
        let options = AppOptions.shared
        switch OnboardingDecision.resolve(completed: options.hasCompletedOnboarding, hasSavedConnections: !connections.isEmpty,
                                          hasSavedSettings: AppOptions.hasSavedPreferences, forced: forced,
                                          suppressed: opensSomething && !asPlainLaunch) {
        case .show: showingOnboarding = true
        case .skipExistingUser: options.completeOnboarding(mode: options.interfaceMode)
        case .skip: break
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

    /// CREATE DATABASE on a server connection, then refreshes its list.
    func createDatabase(_ name: String, on id: UUID) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let session = sessions[id] else { return }
        let sql = "CREATE DATABASE \(session.driver.dialect.quoteIdentifier(name))"
        Task {
            do {
                _ = try await session.driver.executeTimed(sql)
                await session.refreshDatabases()
            } catch {
                alertMessage = "Could not create database “\(name)”: \(error.localizedDescription)"
            }
        }
    }

    func saveSnippet(_ snippet: CodeSnippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) { snippets[index] = snippet } else { snippets.append(snippet) }
        try? snippetStore.save(snippets)
    }

    func deleteSnippet(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        try? snippetStore.save(snippets)
    }

    func toggleFocusMode() {
        if isFocusMode, let saved = panesBeforeFocus {
            showNavigator = saved.navigator
            showAssistant = saved.assistant
            panesBeforeFocus = nil
        } else {
            panesBeforeFocus = (showNavigator, showAssistant)
            showNavigator = false
            showAssistant = false
        }
        isFocusMode.toggle()
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
    /// The connection the toolbar acts on: the navigator's, else the open tab's.
    var currentSession: Session? {
        if let id = navSelection?.connectionID, let session = sessions[id] { return session }
        return currentContext?.session
    }

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
        let secrets = keychain.secrets(for: id)
        var draft = ConnectionDraft(config: config, password: secrets.password ?? "", isNew: false)
        draft.sshSecret = secrets.sshSecret ?? ""
        draft.sslKeyPassphrase = secrets.sslKeyPassphrase ?? ""
        self.draft = draft
    }

    func duplicate(_ id: UUID) {
        guard var copy = connection(id: id) else { return }
        let secrets = keychain.secrets(for: id)
        copy.id = UUID()
        copy.name = copy.displayName + " copy"
        save(copy, secrets: secrets)
    }

    /// Saves with a new database password, keeping the SSH and SSL secrets already in the Keychain.
    func save(_ config: ConnectionConfig, password: String?) {
        var secrets = keychain.secrets(for: config.id)
        secrets.password = password
        save(config, secrets: secrets)
    }

    func save(_ config: ConnectionConfig, secrets: ConnectionSecrets) {
        if let index = connections.firstIndex(where: { $0.id == config.id }) {
            connections[index] = config
        } else {
            connections.append(config)
        }
        keychain.setSecrets(config.kind.isFileBased ? ConnectionSecrets() : secrets, for: config.id)
        persist()
        if sessions[config.id] != nil { disconnect(config.id) }
        if let group = config.group { expanded.insert(.group(group)) }
        navSelection = .connection(config.id)
    }

    func delete(_ id: UUID) {
        disconnect(id)
        connections.removeAll { $0.id == id }
        keychain.setSecrets(ConnectionSecrets(), for: id)
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

    /// A driver for Test Connection: goes through the form's SSH tunnel and SSL settings like a real session.
    func makeDriver(for config: ConnectionConfig, secrets: ConnectionSecrets) -> any DatabaseDriver {
        DriverFactory.make(config: config, secrets: secrets)
    }

    // MARK: - Sessions

    @discardableResult
    func connect(_ id: UUID) -> Session? {
        guard let config = connection(id: id) else { return nil }
        if let existing = sessions[id], !existing.isFailed { return existing }
        // A failed session may still hold a connection or an SSH tunnel lease (e.g. Initial Queries failed).
        sessions[id]?.close()
        let session = Session(config: config, keychain: keychain)
        session.onQueryExecuted = { [weak self] entry in self?.record(entry) }
        sessions[id] = session
        expanded.insert(.connection(id))
        Task {
            await session.connect()
            if config.kind == .sqlite || !config.database.isEmpty {
                let db = config.kind == .sqlite ? "main" : config.database
                expanded.insert(.database(id, db))
                if let schema = config.kind.defaultSchema { expanded.insert(.schema(id, db, schema)) }
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
        case .database(let id, let db) where sessions[id]?.redis != nil:
            if let index = RedisBrowserModel.index(of: db) { sessions[id]?.redis?.open(index) }
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
        case .redisFolder, .redisKey, .redisMore:
            activateRedis(node)
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
        if context.kind.isDocumentStore { return openCollection(object, in: context) }
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
        if context.kind.isDocumentStore { return openMongoShell(text: text, in: context) }
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

    /// Model tab (Navicat Modeling) for a database or schema; reuses an open one.
    func openModel(in context: DatabaseContext, schema: String?) {
        guard Feature.model.isAvailable else { return }
        let schema = context.usesSchemas ? (schema ?? context.defaultSchema) : nil
        if let existing = tabs.first(where: {
            if case .model(let model) = $0 {
                model.connectionID == context.session?.id && model.databaseName == context.name && model.schema == schema
            } else {
                false
            }
        }) {
            selectedTabID = existing.id
            return
        }
        let tab = WorkspaceTab.model(ModelTabModel(context: context, schema: schema))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    /// Adds and selects a tab (for tab kinds opened from extensions, e.g. MongoDB's).
    func appendTab(_ tab: WorkspaceTab) {
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
        case .model(let model):
            model.savePositions()
        case .redis(let model):
            if case .key(let key) = model.content, key.hasUnsavedText { Task { await key.saveText() } }
        case .document(let tab):
            tab.save()
        case .automation, nil:
            break
        }
    }

    var canSaveCurrent: Bool {
        switch selectedTab {
        case .table(let model): model.hasChanges
        case .query(let model): !model.isEmpty
        case .design(let model): model.hasChanges
        case .model: false
        case .redis(let model): model.hasUnsavedChanges
        case .document(let tab): tab.canSave
        case .automation, nil: false
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

    /// Execute SQL File on the connection's first open database.
    func executeSQLFile(connectionID: UUID) {
        guard let context = sessions[connectionID]?.contexts.values.first else {
            alertMessage = "Open a database on this connection first."
            return
        }
        executeSQLFile(in: context)
    }

    // MARK: - Table profiles

    func profiles(for tab: TableTabModel) -> [TableProfile] {
        tableProfiles.filter {
            $0.connectionID == tab.connectionID && $0.database == tab.databaseName && $0.schema == tab.object.schema && $0.table == tab.object.name
        }
    }

    /// Saves a profile; one with the same name on the same table is replaced (keeping its default flag).
    func saveProfile(_ profile: TableProfile) {
        tableProfiles = tableProfiles.saving(profile)
        try? profileStore.save(tableProfiles)
    }

    /// The profile applied when the table opens ("Open with This Profile").
    func defaultProfile(for tab: TableTabModel) -> TableProfile? {
        profiles(for: tab).first(where: \.isDefault)
    }

    func toggleDefaultProfile(_ id: UUID) {
        tableProfiles = tableProfiles.togglingDefault(id)
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

    // MARK: - Practice databases

    /// Where practice databases are created (inside the app's data folder).
    static var practiceDirectory: URL { dataDirectory.appending(path: "Practice Databases", directoryHint: .isDirectory) }

    /// Creates a practice SQLite database from a template, saves it as a connection with the template's example
    /// queries in its Queries folder, connects and opens the first table. Returns false and sets `alertMessage` on failure.
    @discardableResult
    func createPracticeDatabase(_ template: PracticeTemplate, name: String) -> Bool {
        let url = PracticeDatabase.availableURL(named: name, in: Self.practiceDirectory)
        do {
            try PracticeDatabase.create(template, at: url)
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
        let displayName = url.deletingPathExtension().lastPathComponent
        var config = ConnectionConfig(name: displayName, kind: .sqlite, filePath: url.path)
        config.remarks = "Practice database (\(template.name) template). No user or password: it is a file on this Mac."
        save(config, password: nil)
        for example in template.examples {
            savedQueries.append(SavedQuery(connectionID: config.id, database: "main", name: example.name, sql: example.sql))
        }
        persistSavedQueries()
        connect(config.id)
        let id = config.id
        Task {
            for _ in 0..<200 where sessions[id]?.context("main")?.isOpen != true { try? await Task.sleep(for: .milliseconds(50)) }
            guard let context = sessions[id]?.context("main"), context.isOpen else { return }
            expanded.insert(.category(id, "main", nil, .tables))
            if template.examples.isEmpty == false { expanded.insert(.category(id, "main", nil, .queries)) }
            for _ in 0..<100 where context.objects(in: nil) == nil { try? await Task.sleep(for: .milliseconds(50)) }
            if let first = template.tables.first, let object = context.objects(in: nil)?.first(where: { $0.name == first }) {
                openTable(object, in: context)
            }
        }
        return true
    }

    // MARK: - Launch arguments

    /// Debug: `--attach FILE` once main is open; returns the database and table names for "alias.table".
    private func resolveAttachedTable(_ name: String?, connection id: UUID, database: String) async -> (database: String, table: String?) {
        guard let index = CommandLine.arguments.firstIndex(of: "--attach"), CommandLine.arguments.indices.contains(index + 1),
              let session = sessions[id] else { return (database, name) }
        let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        let alias = url.deletingPathExtension().lastPathComponent
        while session.context(database)?.isOpen != true { try? await Task.sleep(for: .milliseconds(50)) }
        if !session.databases.contains(alias) {
            do { try await session.attachSQLiteDatabase(path: url.path, alias: alias) } catch { alertMessage = error.localizedDescription }
        }
        expanded.insert(.database(id, alias))
        session.openDatabase(alias)
        guard let name, name.hasPrefix(alias + ".") else { return (database, name) }
        return (alias, String(name.dropFirst(alias.count + 1)))
    }

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
            // `--attach FILE` attaches another SQLite file (alias = file name); `--open-table alias.table` / `--design alias.table`.
            case "--attach" where !arguments.isEmpty: arguments.removeFirst()
            case "--query" where !arguments.isEmpty: query = arguments.removeFirst()
            // Their file arguments are not databases to open (handled after connecting / by the Import Wizard).
            case "--execute-sql" where !arguments.isEmpty, "--sync-target" where !arguments.isEmpty: arguments.removeFirst()
            case "--bi-export" where !arguments.isEmpty, "--bi-chart" where !arguments.isEmpty, "--bi-filter" where !arguments.isEmpty: arguments.removeFirst()
            // Benchmark options (Benchmarks.swift) take values that may be file paths.
            case "--bench", "--bench-script", "--bench-table", "--bench-rows", "--ui-script", "--ui-results", "--ui-shots":
                if !arguments.isEmpty { arguments.removeFirst() }
            case "--import-wizard":
                if let kind = arguments.first, ImportSourceKind(rawValue: kind) != nil {
                    arguments.removeFirst()
                    if let file = arguments.first, !file.hasPrefix("-") { arguments.removeFirst() }
                }
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
            let requested = args[flagIndex] == "--design" && args.indices.contains(flagIndex + 1) ? args[flagIndex + 1] : nil
            Task {
                let (database, tableName) = await resolveAttachedTable(requested, connection: id, database: database)
                while sessions[id]?.context(database)?.isOpen != true { try? await Task.sleep(for: .milliseconds(50)) }
                guard let context = sessions[id]?.context(database) else { return }
                let object = tableName.flatMap { name in context.objects(in: context.defaultSchema)?.first { $0.name == name } }
                openDesign(table: object, in: context)
                if case .design(let model) = selectedTab, tableName != nil {
                    try? await Task.sleep(for: .milliseconds(300))
                    model.addField()
                    model.columns[1].name = "full_name"
                    // `--save-design` saves it, to check ALTER paths end to end.
                    if CommandLine.arguments.contains("--save-design") {
                        if await model.save() == false { alertMessage = model.saveError ?? "Design not saved" }
                    }
                }
            }
        }
        #if DEBUG
        // Opens the first saved connection's editor; `-connectionTab ssl|ssh|advanced` picks the tab.
        if CommandLine.arguments.contains("--edit-connection"), let first = connections.first { edit(first.id) }
        if CommandLine.arguments.contains("--new-connection") { showingConnectionPicker = true }
        if CommandLine.arguments.contains("--account-menu") { showingAccountMenu = true }
        if CommandLine.arguments.contains("--ai-pane") { showAssistant = true; rightPane = .ai }
        if CommandLine.arguments.contains("--ai-wide") { assistant.isExpanded = true }
        if let index = CommandLine.arguments.firstIndex(of: "--right-pane"), CommandLine.arguments.indices.contains(index + 1),
           let pane = RightPane(rawValue: CommandLine.arguments[index + 1]) {
            showAssistant = true
            rightPane = pane
        }
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
        #if DEBUG
        runSyncDebugFlags(opened: opened)
        runBIDebugFlags(opened: opened, database: database)
        #endif
        if CommandLine.arguments.contains("--open-model"), let id = opened {
            Task {
                while sessions[id]?.context(database)?.isOpen != true { try? await Task.sleep(for: .milliseconds(50)) }
                if let context = sessions[id]?.context(database) { openModel(in: context, schema: context.defaultSchema) }
            }
        }
        if CommandLine.arguments.contains("--show-objects"), let id = opened {
            Task {
                while sessions[id]?.context(database)?.isOpen != true { try? await Task.sleep(for: .milliseconds(50)) }
                let schema = sessions[id]?.context(database)?.defaultSchema
                expanded.insert(.category(id, database, schema, .tables))
                select(.category(id, database, schema, .tables))
                if let index = CommandLine.arguments.firstIndex(of: "--category"), CommandLine.arguments.indices.contains(index + 1),
                   let category = ObjectCategory.allCases.first(where: { $0.rawValue.lowercased() == CommandLine.arguments[index + 1] }) {
                    showCategory(category)
                }
            }
        }
        #endif
        #if DEBUG
        if let id = opened, CommandLine.arguments.contains(where: { $0 == "--open-collection" || $0 == "--mongo-shell" }) {
            Task {
                while sessions[id]?.contexts.values.first(where: \.isOpen) == nil { try? await Task.sleep(for: .milliseconds(50)) }
                if let context = sessions[id]?.contexts.values.first(where: \.isOpen) { openMongoLaunchArguments(context: context) }
            }
        }
        #endif
        guard tableName != nil || query != nil, let id = opened else { return }
        Task {
            let (database, tableName) = await resolveAttachedTable(tableName, connection: id, database: database)
            while sessions[id]?.context(database)?.isOpen != true { try? await Task.sleep(for: .milliseconds(50)) }
            guard let context = sessions[id]?.context(database) else { return }
            if let query {
                openQuery(text: query, in: context)
                // `--explain` opens the query's plan instead of its result.
                if CommandLine.arguments.contains("--explain") { selectedQueryTab?.explain() } else { selectedQueryTab?.run() }
                #if DEBUG
                // `--demo-result-edits`: pending edits in the first result (Edit Result), for screenshots.
                if CommandLine.arguments.contains("--demo-result-edits"), let tab = selectedQueryTab {
                    try? await Task.sleep(for: .milliseconds(300))
                    while tab.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
                    if let result = tab.resultSets.first {
                        await tab.prepareEditor(for: result)
                        if let editor = tab.editor(for: result), editor.isEditable {
                            editor.setValue(.text("Edited in the result"), row: 1, column: 1)
                            editor.toggleDelete([3])
                            editor.addRow()
                        }
                    }
                }
                if CommandLine.arguments.contains("--query-builder") { selectedQueryTab?.showingQueryBuilder = true }
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
                // Transfer sheets for visual checks: --export-wizard, --import-wizard csv|json|sql [FILE], --execute-sql FILE.
                if CommandLine.arguments.contains("--export-wizard") { exportTarget = ExportTarget(context: context, objects: [object]) }
                if CommandLine.arguments.contains("--import-wizard") { importTarget = ImportTarget(context: context, object: object) }
                if let index = CommandLine.arguments.firstIndex(of: "--execute-sql"), CommandLine.arguments.indices.contains(index + 1) {
                    sqlFileTarget = SQLFileTarget(context: context, url: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                }
                #endif
                #if DEBUG
                if let tab = selectedTableTab, ["--demo-edits", "--focus-cell", "--begin-transaction", "--generate", "--profile",
                                                "--value-editor", "--cell-editor", "--demo-duplicate"].contains(where: CommandLine.arguments.contains) {
                    await tab.loadIfNeeded()
                    if CommandLine.arguments.contains("--demo-edits") {
                        tab.setValue(.text("Edited name"), row: 1, column: 1)
                        tab.toggleDelete([4, 5])
                        tab.addRow()
                        tab.setValue(.text("New customer"), row: tab.page?.rows.count ?? 0, column: 1)
                        tab.scroll(toRow: 0)
                        // `--apply-edits` applies them, to check UPDATE / DELETE / INSERT paths end to end.
                        if CommandLine.arguments.contains("--apply-edits") {
                            await tab.applyChanges()
                            if let error = tab.saveError { alertMessage = error }
                        }
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
                    tab.runCellEditingDebugFlags()
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
