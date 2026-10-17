import AppKit
import BunnyGridCore
import Foundation

/// The open query and table tabs, saved for Options › Auto Recovery and "Continue where you left off".
struct WorkspaceSnapshot: Codable {
    struct Tab: Codable {
        enum Kind: String, Codable { case query, table }

        var kind: Kind
        var connectionID: UUID
        var database: String
        var title: String
        var text: String?
        var savedQueryID: UUID?
        var objectName: String?
        var schema: String?
    }

    var tabs: [Tab] = []
    /// False while the app runs; set when it quits normally. Still false at launch means a crash or forced quit.
    var cleanExit = false
}

extension AppModel {
    static var workspaceURL: URL { dataDirectory.appending(path: "workspace.json") }

    func workspaceSnapshot(cleanExit: Bool) -> WorkspaceSnapshot {
        var snapshot = WorkspaceSnapshot(cleanExit: cleanExit)
        for tab in tabs {
            switch tab {
            case .query(let model):
                guard let id = model.connectionID else { continue }
                snapshot.tabs.append(.init(kind: .query, connectionID: id, database: model.databaseName, title: model.title,
                                           text: model.text, savedQueryID: model.savedQueryID))
            case .table(let model):
                guard let id = model.connectionID else { continue }
                snapshot.tabs.append(.init(kind: .table, connectionID: id, database: model.databaseName, title: model.object.name,
                                           objectName: model.object.name, schema: model.object.schema))
            case .design, .model:
                continue
            }
        }
        return snapshot
    }

    /// Flags the saved workspace as "running" so a crash is detected next launch, keeping its tabs.
    func markWorkspaceRunning() {
        guard let data = try? Data(contentsOf: Self.workspaceURL),
              var snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data) else { return }
        snapshot.cleanExit = false
        try? JSONEncoder().encode(snapshot).write(to: Self.workspaceURL, options: .atomic)
    }

    func saveWorkspace(cleanExit: Bool) {
        guard let data = try? JSONEncoder().encode(workspaceSnapshot(cleanExit: cleanExit)) else { return }
        try? FileManager.default.createDirectory(at: Self.dataDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.workspaceURL, options: .atomic)
    }

    /// Autosaves on the Options › Auto Recovery interval for as long as the app runs.
    func startAutosave() {
        Task { [weak self] in
            while true {
                let seconds = AppOptions.shared.values.autosaveQueries.rawValue
                try? await Task.sleep(for: .seconds(seconds == 0 ? 30 : seconds))
                guard let self else { return }
                if seconds > 0 { self.saveWorkspace(cleanExit: false) }
            }
        }
    }

    /// Reopens the last session's tabs when the user chose "Continue where you left off",
    /// or the unsaved queries when the app didn't quit normally.
    func restoreWorkspaceIfNeeded() {
        guard let data = try? Data(contentsOf: Self.workspaceURL),
              let snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data) else { return }
        let continueSession = AppOptions.shared.values.startupTabs == .continueWhereLeft
        let recovering = !snapshot.cleanExit && AppOptions.shared.values.autosaveQueries != .never
        let tabs = snapshot.tabs.filter { tab in
            continueSession || (recovering && tab.kind == .query && !(tab.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        guard !tabs.isEmpty else { return }
        Task {
            for tab in tabs {
                guard connection(id: tab.connectionID) != nil, let session = connect(tab.connectionID) else { continue }
                var waited = 0
                while !session.isConnected && !session.isFailed && waited < 150 {
                    try? await Task.sleep(for: .milliseconds(100))
                    waited += 1
                }
                guard session.isConnected else { continue }
                let context = session.openDatabase(tab.database)
                waited = 0
                while !context.isOpen && !context.isFailed && waited < 150 {
                    try? await Task.sleep(for: .milliseconds(100))
                    waited += 1
                }
                guard context.isOpen else { continue }
                switch tab.kind {
                case .query:
                    if let id = tab.savedQueryID, let saved = savedQueries.first(where: { $0.id == id }) {
                        openSavedQuery(saved, in: context)
                        if let text = tab.text, text != saved.sql { selectedQueryTab?.text = text }
                    } else {
                        openQuery(text: tab.text ?? "", in: context)
                        selectedQueryTab?.title = tab.title
                    }
                case .table:
                    if context.objects(in: tab.schema ?? context.defaultSchema) == nil {
                        await context.loadObjects(schema: tab.schema ?? context.defaultSchema)
                    }
                    if let object = context.objects(in: tab.schema ?? context.defaultSchema)?.first(where: { $0.name == tab.objectName }) {
                        openTable(object, in: context)
                    }
                }
            }
        }
    }
}
