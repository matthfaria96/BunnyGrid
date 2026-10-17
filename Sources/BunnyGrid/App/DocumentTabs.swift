import BunnyGridCore
import Foundation

/// A workspace tab for a document store (MongoDB): the collection viewer and the shell. `WorkspaceTab.document`
/// wraps one, so each shared switch over tabs needs a single line for all of them.
@MainActor
protocol DocumentTab: AnyObject {
    nonisolated var id: UUID { get }
    var title: String { get }
    var kindName: String { get }
    nonisolated var systemImage: String { get }
    var connectionID: UUID? { get }
    var hasUnsavedChanges: Bool { get }
    /// Status bar: the statement that ran, a warning, and the record summary.
    var lastStatement: String { get }
    var warning: String? { get }
    var recordText: String { get }
    /// What "Attach Tabs" sends to the AI Assistant.
    var attachmentText: String { get }
    var canSave: Bool { get }
    func save()
    /// The tab is closing.
    func cancel()
    /// The Simple / Advanced feature it belongs to (BI workspaces); nil for the everyday ones.
    var feature: Feature? { get }
}

extension DocumentTab {
    var feature: Feature? { nil }
}

extension DatabaseContext {
    /// Navigator folders of a document store: Collections (`.tables`), Views, GridFS buckets and Indexes.
    func documentObjects(_ all: [DatabaseObject]?, category: ObjectCategory) -> [DatabaseObject]? {
        guard let all else { return nil }
        return all.filter { object in
            switch (DocumentCatalog.classify(object), category) {
            case (.collection, .tables), (.view, .views), (.gridFSBucket, .gridFS), (.index, .indexes): true
            default: false
            }
        }
    }

    var mongoDriver: MongoDriver? { driver as? MongoDriver }
}

extension ObjectCategory {
    /// The folder name for an engine: MongoDB calls tables "Collections".
    func title(for kind: DatabaseKind) -> String {
        kind.isDocumentStore && self == .tables ? "Collections" : rawValue
    }
}

extension AppModel {
    private static var shellCounter = 0

    /// Opens a collection, view, GridFS bucket or index's collection in the collection viewer (reusing an open tab).
    func openCollection(_ object: DatabaseObject, in context: DatabaseContext) {
        let name = DocumentCatalog.collectionName(object)
        if let existing = tabs.first(where: {
            if case .document(let tab) = $0, let viewer = tab as? CollectionTabModel {
                viewer.collection == name && viewer.databaseName == context.name && viewer.connectionID == context.session?.id
            } else {
                false
            }
        }) {
            selectedTabID = existing.id
            return
        }
        let tab = WorkspaceTab.document(CollectionTabModel(context: context, object: object))
        appendTab(tab)
    }

    /// A MongoDB shell tab on the database.
    func openMongoShell(text: String = "", in context: DatabaseContext) {
        Self.shellCounter += 1
        let tab = WorkspaceTab.document(MongoShellTabModel(title: "Shell \(Self.shellCounter)", text: text, context: context))
        appendTab(tab)
    }

    var selectedDocumentTab: (any DocumentTab)? {
        if case .document(let tab) = selectedTab { tab } else { nil }
    }

    /// Debug flags: `--open-collection NAME [--mongo-view tree|json] [--edit-document]`, `--mongo-shell TEXT`.
    func openMongoLaunchArguments(context: DatabaseContext) {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--open-collection"), args.indices.contains(index + 1) {
            let name = args[index + 1]
            Task {
                while context.objects(in: nil) == nil { try? await Task.sleep(for: .milliseconds(50)) }
                let object = context.objects(in: nil)?.first { $0.name == name } ?? DatabaseObject(schema: nil, name: name, kind: .table)
                openCollection(object, in: context)
                guard case .document(let tab)? = selectedTab, let viewer = tab as? CollectionTabModel else { return }
                if let i = args.firstIndex(of: "--mongo-view"), args.indices.contains(i + 1),
                   let mode = CollectionTabModel.ViewMode.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(args[i + 1]) }) {
                    viewer.viewMode = mode
                }
                if let i = args.firstIndex(of: "--mongo-filter"), args.indices.contains(i + 1) {
                    viewer.filterText = args[i + 1]
                }
                await viewer.reload()
                if args.contains("--edit-document"), !viewer.documents.isEmpty {
                    viewer.selectedRows = [0]
                    viewer.editSelected()
                }
            }
        }
        if let index = args.firstIndex(of: "--mongo-shell"), args.indices.contains(index + 1) {
            openMongoShell(text: args[index + 1], in: context)
            if case .document(let tab)? = selectedTab, let shell = tab as? MongoShellTabModel {
                if args.contains("--explain") { shell.explain() } else { shell.run() }
            }
        }
    }
}
