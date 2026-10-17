import BunnyGridCore
import Foundation
import Observation

/// Object folders shown under a schema (or database) in the navigator, and the
/// object-type buttons in the main toolbar.
enum ObjectCategory: String, CaseIterable, Hashable {
    case tables = "Tables"
    case views = "Views"
    case materializedViews = "Materialized Views"
    case functions = "Functions"
    case queries = "Queries"
    case backups = "Backups"
    /// SQLite's Index and Trigger toolbar buttons (listed in Objects, not as navigator folders).
    case indexes = "Indexes"
    case triggers = "Triggers"
    /// MongoDB GridFS buckets.
    case gridFS = "GridFS"

    var objectKind: DatabaseObjectKind? {
        switch self {
        case .tables: .table
        case .views: .view
        case .materializedViews: .materializedView
        case .functions: .routine
        case .gridFS: .table
        case .queries, .backups, .indexes, .triggers: nil
        }
    }

    /// Singular noun for buttons such as "Open Table".
    var noun: String {
        switch self {
        case .tables: "Table"
        case .views: "View"
        case .materializedViews: "Materialized View"
        case .functions: "Function"
        case .queries: "Query"
        case .backups: "Backup"
        case .indexes: "Index"
        case .triggers: "Trigger"
        case .gridFS: "Bucket"
        }
    }

    static func categories(for kind: DatabaseKind) -> [ObjectCategory] {
        switch kind {
        case .postgresql: allCases
        case .mysql, .mariadb, .sqlserver: [.tables, .views, .functions, .queries, .backups]
        case .sqlite: [.tables, .views, .queries, .backups]
        case .redis: []
        case .mongodb: [.tables, .views, .gridFS, .indexes, .queries]
        }
    }

    /// The object buttons of the main toolbar, which differ per engine as in Navicat.
    static func toolbarCategories(for kind: DatabaseKind?) -> [ObjectCategory] {
        switch kind {
        case .sqlite: [.tables, .views, .indexes, .triggers]
        case .redis: []
        case .mongodb: [.tables, .views, .gridFS, .indexes]
        case .postgresql: [.tables, .views, .materializedViews, .functions]
        default: [.tables, .views, .functions]
        }
    }
}

/// A node in the navigator tree.
enum NavNode: Hashable {
    case cloud
    case cloudInfo
    case myConnections
    case group(String)
    case connection(UUID)
    case database(UUID, String)
    case schema(UUID, String, String)
    case category(UUID, String, String?, ObjectCategory)
    case object(UUID, String, DatabaseObject)
    case savedQuery(UUID, String, UUID)
    /// Redis key folder (database index, prefix with the trailing separator), key, and the Load More row.
    case redisFolder(UUID, Int, String)
    case redisKey(UUID, Int, String)
    case redisMore(UUID, Int)

    var connectionID: UUID? {
        switch self {
        case .redisFolder(let id, _, _), .redisKey(let id, _, _), .redisMore(let id, _): id
        case .connection(let id), .database(let id, _), .schema(let id, _, _),
             .category(let id, _, _, _), .object(let id, _, _), .savedQuery(let id, _, _): id
        default: nil
        }
    }

    var databaseName: String? {
        switch self {
        case .database(_, let db), .schema(_, let db, _), .category(_, let db, _, _), .object(_, let db, _), .savedQuery(_, let db, _): db
        case .redisFolder(_, let db, _), .redisKey(_, let db, _), .redisMore(_, let db): "db\(db)"
        default: nil
        }
    }

    var schemaName: String? {
        switch self {
        case .schema(_, _, let schema): schema
        case .category(_, _, let schema, _): schema
        case .object(_, _, let object): object.schema
        default: nil
        }
    }
}

/// One open connection to a server (or SQLite file) and the databases opened on it.
@MainActor
@Observable
final class Session: Identifiable {
    enum State: Equatable {
        case connecting
        case connected
        case failed(String)
    }

    let config: ConnectionConfig
    /// Server-level driver: lists databases, and serves every database on MySQL/SQLite.
    /// Rebuilt in `connect()` once the secrets have been read from the Keychain.
    private(set) var driver: any DatabaseDriver
    /// Database password, SSH password or key passphrase, SSL key passphrase.
    @ObservationIgnored private var secrets = ConnectionSecrets()
    @ObservationIgnored private let keychain: KeychainStore
    private(set) var state: State = .connecting
    private(set) var serverVersion = ""
    private(set) var databases: [String] = []
    private(set) var contexts: [String: DatabaseContext] = [:]
    /// Key browser of a Redis connection (nil for SQL engines).
    private(set) var redis: RedisBrowserModel?
    @ObservationIgnored var onQueryExecuted: ((QueryHistoryEntry) -> Void)?

    init(config: ConnectionConfig, keychain: KeychainStore) {
        self.config = config
        self.keychain = keychain
        self.driver = DriverFactory.make(config: Self.serverConfig(config), password: nil)
    }

    private static func serverConfig(_ config: ConnectionConfig) -> ConnectionConfig {
        var serverConfig = config
        if serverConfig.database.isEmpty, let database = config.kind.serverDatabase {
            serverConfig.database = database
        }
        return serverConfig
    }

    nonisolated var id: UUID { config.id }
    var isConnected: Bool { state == .connected }
    var isFailed: Bool { if case .failed = state { true } else { false } }

    /// The database the server-level driver is attached to (PostgreSQL connects to one database).
    private var serverDatabase: String {
        config.database.isEmpty ? (config.kind.serverDatabase ?? "") : config.database
    }

    func connect() async {
        state = .connecting
        if !config.kind.isFileBased {
            // Keychain reads can block on an access prompt; keep them off the main thread.
            let keychain = keychain, id = config.id
            secrets = await Task.detached { keychain.secrets(for: id) }.value
            driver = DriverFactory.make(config: Self.serverConfig(config), secrets: secrets)
        }
        do {
            try await driver.connect()
            try await Self.runInitialQueries(config, on: driver)
            serverVersion = (try? await driver.serverVersion()) ?? ""
            databases = config.kind == .sqlite ? ["main"] : try await driver.listDatabases()
            if let kv = driver as? RedisDriver { redis = RedisBrowserModel(driver: kv, session: self); await redis?.refreshKeyspace() }
            state = .connected
            if config.kind.isKeyValue {
                // Redis databases are opened by the key browser, not as SQL contexts.
            } else if config.kind == .sqlite {
                openDatabase("main")
            } else if !config.database.isEmpty, databases.contains(config.database) {
                openDatabase(config.database)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// The connection's Initial Queries (Advanced tab), run on every new driver connection.
    static func runInitialQueries(_ config: ConnectionConfig, on driver: any DatabaseDriver) async throws {
        guard let script = config.initialQueries, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        for statement in SQLSplitter.split(script) {
            do {
                _ = try await driver.executeTimed(statement)
            } catch {
                throw InitialQueryError(statement: statement, message: error.localizedDescription)
            }
        }
    }

    func close() {
        for context in contexts.values { context.close() }
        contexts = [:]
        let driver = driver
        Task { await driver.disconnect() }
    }

    func refreshDatabases() async {
        guard config.kind != .sqlite else { return }
        databases = (try? await driver.listDatabases()) ?? databases
    }

    func context(_ name: String) -> DatabaseContext? { contexts[name] }

    /// SQLite's "Attach Database…": ATTACH the file under `alias` and list it beside main.
    func attachSQLiteDatabase(path: String, alias: String) async throws {
        guard let sqlite = driver as? SQLiteDriver else { return }
        try await sqlite.attach(path: path, as: alias)
        databases = try await driver.listDatabases().filter { $0 != "temp" }
    }

    /// A new, unconnected driver for `database`, for work that needs its own connection
    /// (a table tab's manual transaction, a query editor). On MySQL it connects with `database` as the
    /// default database, so unqualified names in the editor resolve there.
    func makeDedicatedDriver(database: String) -> any DatabaseDriver {
        var databaseConfig = config
        switch config.kind {
        case .postgresql, .mysql, .mariadb, .sqlserver, .mongodb: databaseConfig.database = database
        case .sqlite: break
        case .redis: break
        }
        return DriverFactory.make(config: databaseConfig, secrets: secrets)
    }

    /// Opens a database (idempotent). PostgreSQL needs a connection per database;
    /// other engines reuse the server connection.
    @discardableResult
    func openDatabase(_ name: String) -> DatabaseContext {
        if let existing = contexts[name], !existing.isFailed { return existing }
        let context: DatabaseContext
        if config.kind.connectsPerDatabase && name != serverDatabase {
            var databaseConfig = config
            databaseConfig.database = name
            context = DatabaseContext(name: name, session: self, driver: DriverFactory.make(config: databaseConfig, secrets: secrets), ownsDriver: true)
        } else {
            context = DatabaseContext(name: name, session: self, driver: driver, ownsDriver: false)
        }
        contexts[name] = context
        Task { await context.open() }
        return context
    }

    func closeDatabase(_ name: String) {
        contexts.removeValue(forKey: name)?.close()
    }
}

/// An opened database: its schemas, objects and the driver bound to it.
@MainActor
@Observable
final class DatabaseContext: Identifiable {
    enum State: Equatable {
        case opening
        case open
        case failed(String)
    }

    nonisolated let name: String
    let driver: any DatabaseDriver
    @ObservationIgnored private let ownsDriver: Bool
    @ObservationIgnored weak var session: Session?
    private(set) var state: State = .opening
    private(set) var schemas: [String] = []
    /// Objects keyed by schema; engines without schemas use the empty key.
    private(set) var objectsBySchema: [String: [DatabaseObject]] = [:]
    private(set) var loadingSchemas: Set<String> = []
    private var columnCache: [String: [String]] = [:]
    @ObservationIgnored private var columnLoads: Set<String> = []

    init(name: String, session: Session, driver: any DatabaseDriver, ownsDriver: Bool) {
        self.name = name
        self.session = session
        self.driver = driver
        self.ownsDriver = ownsDriver
    }

    nonisolated var id: String { name }
    var kind: DatabaseKind { driver.config.kind }
    var isOpen: Bool { state == .open }
    var isFailed: Bool { if case .failed = state { true } else { false } }
    var usesSchemas: Bool { kind.hasSchemas }
    var defaultSchema: String? { kind.defaultSchema }

    func open() async {
        state = .opening
        do {
            if ownsDriver {
                try await driver.connect()
                if let config = session?.config { try await Session.runInitialQueries(config, on: driver) }
            }
            if usesSchemas {
                schemas = try await driver.listSchemas()
                if let schema = defaultSchema, schemas.contains(schema) {
                    await loadObjects(schema: schema)
                }
            } else {
                await loadObjects(schema: nil)
            }
            state = .open
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func close() {
        guard ownsDriver else { return }
        let driver = driver
        Task { await driver.disconnect() }
    }

    /// The schema argument the driver expects: the database name on MySQL, nothing on SQLite.
    func driverSchema(_ schema: String?) -> String? {
        switch kind {
        case .postgresql, .sqlserver: schema
        case .mysql, .mariadb, .mongodb: name
        // Attached SQLite databases are addressed as `alias.table`; main stays unqualified.
        case .sqlite: name == "main" ? nil : name
        case .redis: nil
        }
    }

    func objects(in schema: String?) -> [DatabaseObject]? {
        if kind.isDocumentStore { return objectsBySchema[""]?.filter(DocumentCatalog.isBrowsable) }
        return objectsBySchema[usesSchemas ? (schema ?? "") : ""]
    }

    func objects(in schema: String?, category: ObjectCategory) -> [DatabaseObject]? {
        if kind.isDocumentStore { return documentObjects(objectsBySchema[""], category: category) }
        guard let kind = category.objectKind else { return [] }
        return objects(in: schema)?.filter { $0.kind == kind }
    }

    func loadObjects(schema: String?, force: Bool = false) async {
        let key = usesSchemas ? (schema ?? "") : ""
        guard force || objectsBySchema[key] == nil, !loadingSchemas.contains(key) else { return }
        loadingSchemas.insert(key)
        defer { loadingSchemas.remove(key) }
        objectsBySchema[key] = (try? await driver.listObjects(schema: driverSchema(schema))) ?? []
        if force { columnCache = [:] }
    }

    func refresh() async {
        if usesSchemas {
            schemas = (try? await driver.listSchemas()) ?? schemas
            for key in objectsBySchema.keys { await loadObjects(schema: key, force: true) }
        } else {
            await loadObjects(schema: nil, force: true)
        }
    }

    /// "@dvdrental.public (My Server)", as in Navicat's tab titles: the place, then the connection name.
    func location(schema: String?) -> String {
        let place = usesSchemas && schema != nil ? "\(name).\(schema!)" : name
        return "@\(place) (\(session?.config.displayName ?? kind.displayName))"
    }

    // MARK: - Autocomplete

    var completionCatalog: CompletionCatalog {
        let catalog = CompletionCatalog(schemas: schemas, tables: objectsBySchema.values.flatMap { $0 }, columns: columnCache)
        return AppOptions.shared.values.includeSystemObjectsInCompletion ? catalog : catalog.withoutSystemObjects()
    }

    /// Options › Code Completion › Clear Code Completion Info: forget cached columns (they load again on use).
    func clearCompletionInfo() {
        columnCache = [:]
    }

    func cachedColumns(for table: String) -> [String]? {
        columnCache[table.lowercased()]
    }

    /// Loads, in the background, the columns of tables referenced in `sql`.
    func prefetchColumns(for sql: String) {
        guard AppOptions.shared.values.autoUpdateCompletionInfo else { return }
        for reference in SQLCompletion.tableReferences(in: sql) {
            let key = reference.table.lowercased()
            guard columnCache[key] == nil, !columnLoads.contains(key) else { continue }
            let schema = reference.schema
                ?? objectsBySchema.values.joined().first { $0.name.lowercased() == key }?.schema
                ?? driverSchema(defaultSchema)
            columnLoads.insert(key)
            Task {
                defer { columnLoads.remove(key) }
                if let columns = try? await driver.listColumns(table: reference.table, schema: schema), !columns.isEmpty {
                    columnCache[key] = columns.map(\.name)
                }
            }
        }
    }
}

enum WorkspaceTab: Identifiable {
    case table(TableTabModel)
    case query(QueryTabModel)
    case design(TableDesignModel)
    case model(ModelTabModel)
    case redis(RedisTabModel)
    case document(any DocumentTab)
    /// Navicat's Automation, as a workspace tab (one at most).
    case automation(AutomationTabModel)

    var id: UUID {
        switch self {
        case .automation(let model): model.id
        case .redis(let model): model.id
        case .table(let model): model.id
        case .query(let model): model.id
        case .design(let model): model.id
        case .model(let model): model.id
        case .document(let tab): tab.id
        }
    }

    /// "payment@dvdrental.public (My Server)".
    @MainActor var title: String {
        switch self {
        case .table(let model): "\(model.object.name)\(model.location)"
        case .query(let model): "\(model.title)\(model.location)"
        case .design(let model): "\(model.displayName)\(model.location)"
        case .model(let model): "Model \(model.location)"
        case .redis(let model): model.title
        case .document(let tab): tab.title
        case .automation: "Automation"
        }
    }

    /// The word Navicat puts in the window title: "Table", "View", "Query", "Table Design".
    @MainActor var kindName: String {
        switch self {
        case .table(let model): model.object.kind == .table ? "Table" : "View"
        case .query: "Query"
        case .design: "Table Design"
        case .model: "Model"
        case .redis(let model): model.kindName
        case .document(let tab): tab.kindName
        case .automation: "Automation"
        }
    }

    /// Illustrated icon (Resources/Icons) for the tab.
    var systemImage: String {
        switch self {
        case .table(let model): model.object.kind.iconName
        case .query: "query"
        case .design: "table"
        case .model: "model"
        case .redis(let model): model.iconName
        case .document(let tab): tab.systemImage
        case .automation: "automation"
        }
    }

    @MainActor var connectionID: UUID? {
        switch self {
        case .table(let model): model.connectionID
        case .query(let model): model.connectionID
        case .design(let model): model.connectionID
        case .model(let model): model.connectionID
        case .redis(let model): model.connectionID
        case .document(let tab): tab.connectionID
        case .automation: nil
        }
    }

    @MainActor var hasUnsavedChanges: Bool {
        switch self {
        case .table(let model): model.hasChanges || model.isInTransaction
        // A new query counts as unsaved when Options › General asks to save new queries before closing.
        case .query(let model): model.isDirty && (model.savedQueryID != nil || (AppOptions.shared.values.askToSaveNewQueries && !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        case .design(let model): model.hasChanges
        case .model: false
        case .redis(let model): model.hasUnsavedChanges
        case .document(let tab): tab.hasUnsavedChanges
        case .automation: false
        }
    }

    @MainActor var tableObject: DatabaseObject? {
        if case .table(let model) = self { model.object } else { nil }
    }

    @MainActor func cancel() {
        switch self {
        case .query(let model): model.close()
        case .table(let model): model.abandonTransaction()
        case .design, .model: break
        case .redis(let model): model.close()
        case .document(let tab): tab.cancel()
        case .automation: break
        }
    }
}

/// An Initial Query that failed, so the connection error names the statement.
struct InitialQueryError: LocalizedError {
    let statement: String
    let message: String

    var errorDescription: String? { "Initial query failed (\(statement.prefix(80))): \(message)" }
}
