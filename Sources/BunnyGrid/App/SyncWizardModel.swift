import BunnyGridCore
import Foundation
import Observation

/// The Tools menu's transfer and synchronization wizards.
enum SyncTool: String, CaseIterable, Identifiable {
    case dataTransfer, dataSync, structureSync
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dataTransfer: "Data Transfer"
        case .dataSync: "Data Synchronization"
        case .structureSync: "Structure Synchronization"
        }
    }

    var symbol: String {
        switch self {
        case .dataTransfer: "arrow.left.arrow.right.square"
        case .dataSync: "arrow.triangle.2.circlepath"
        case .structureSync: "square.stack.3d.up.badge.automatic"
        }
    }
}

/// Opens a wizard, with the source preset from where it was chosen.
struct SyncWizardRequest: Identifiable {
    let id = UUID()
    var tool: SyncTool
    var connectionID: UUID?
    var database: String?
    var schema: String?
    /// Debug: a second connection to preselect as the target.
    var targetConnectionID: UUID?
}

/// One side of a wizard: connection → database → schema, picked from the saved connections.
/// Work runs on a dedicated driver made by the session, so SSH, SSL and Keychain secrets apply.
@MainActor
@Observable
final class SyncEndpoint {
    @ObservationIgnored weak var app: AppModel?
    var connectionID: UUID? { didSet { if connectionID != oldValue { database = nil; schema = nil; connect() } } }
    var database: String? { didSet { if database != oldValue { schema = nil; openDatabase() } } }
    var schema: String?

    init(app: AppModel, connectionID: UUID? = nil, database: String? = nil, schema: String? = nil) {
        self.app = app
        self.connectionID = connectionID
        connect()
        self.database = database
        openDatabase()
        self.schema = schema
    }

    var config: ConnectionConfig? { connectionID.flatMap { app?.connection(id: $0) } }
    var session: Session? { connectionID.flatMap { app?.sessions[$0] } }
    var kind: DatabaseKind? { config?.kind }
    var databases: [String] { session?.databases ?? [] }
    var context: DatabaseContext? { database.flatMap { session?.context($0) } }
    var schemas: [String] { context?.schemas ?? [] }
    var usesSchemas: Bool { kind == .postgresql }

    var isReady: Bool {
        guard let context, context.isOpen else { return false }
        return !usesSchemas || schema != nil
    }

    /// The schema argument the drivers take (PostgreSQL schema, MySQL database, nil on SQLite).
    var driverSchema: String? { context?.driverSchema(schema) }

    var tables: [DatabaseObject] { context?.objects(in: schema, category: .tables) ?? [] }

    var label: String {
        guard let config else { return "—" }
        return [config.name, database, schema].compactMap { $0 }.joined(separator: " › ")
    }

    private func connect() {
        guard let connectionID, let app else { return }
        let session = app.connect(connectionID)
        if database == nil, let config = session?.config, config.kind == .sqlite { database = "main" }
    }

    private func openDatabase() {
        guard let database, let session else { return }
        let context = session.openDatabase(database)
        if schema == nil, context.usesSchemas { schema = context.defaultSchema }
    }

    func loadTables() async {
        guard let context else { return }
        while context.state == .opening { try? await Task.sleep(for: .milliseconds(50)) }
        await context.loadObjects(schema: schema)
    }

    /// A connected driver of its own for the wizard's work; the caller disconnects it.
    func makeDriver() async throws -> any DatabaseDriver {
        guard let session, let database else { throw DatabaseError.notConnected }
        let driver = session.makeDedicatedDriver(database: database)
        try await driver.connect()
        try await Session.runInitialQueries(session.config, on: driver)
        return driver
    }
}

extension AppModel {
    /// Opens a wizard from the selected navigator node (or tab).
    func openSyncWizard(_ tool: SyncTool, node: NavNode? = nil) {
        let node = node ?? navSelection
        let id = node?.connectionID ?? currentSession?.id
        syncWizard = SyncWizardRequest(tool: tool, connectionID: id, database: node?.databaseName ?? currentContext?.name,
                                       schema: node?.schemaName ?? currentSchema)
    }

    #if DEBUG
    /// `--data-transfer`, `--data-sync`, `--structure-sync` open a wizard on the opened connection; `--sync-target PATH`
    /// preselects a SQLite file as the target and `--sync-compare` runs the comparison.
    func runSyncDebugFlags(opened: UUID?) {
        let args = CommandLine.arguments
        guard let tool = [("--data-transfer", SyncTool.dataTransfer), ("--data-sync", .dataSync), ("--structure-sync", .structureSync)]
            .first(where: { args.contains($0.0) })?.1 else { return }
        var target: UUID?
        if let index = args.firstIndex(of: "--sync-target"), args.indices.contains(index + 1) {
            let path = URL(fileURLWithPath: args[index + 1]).standardizedFileURL.path
            if let existing = connections.first(where: { $0.kind == .sqlite && $0.filePath == path }) {
                target = existing.id
            } else {
                let config = ConnectionConfig(name: (path as NSString).lastPathComponent, kind: .sqlite, filePath: path)
                save(config, password: nil)
                target = config.id
            }
        }
        syncWizard = SyncWizardRequest(tool: tool, connectionID: opened, database: "main", targetConnectionID: target)
    }
    #endif
}
