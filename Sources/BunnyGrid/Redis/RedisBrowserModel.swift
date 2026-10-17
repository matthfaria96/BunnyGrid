import BunnyGridCore
import Foundation
import Observation

/// Key browser state of a Redis connection: key counts per database and, per opened database, the keys
/// loaded so far by SCAN (in pages, never KEYS), the filter, and the folder tree built from them.
@MainActor
@Observable
final class RedisBrowserModel {
    /// Keys read per "Load More" (SCAN COUNT is a hint; pages stop once this many new keys arrived).
    static let pageSize = 500

    @MainActor
    @Observable
    final class DatabaseKeys {
        let index: Int
        private(set) var keys: [String: RedisKeyEntry] = [:]
        private(set) var cursor = "0"
        private(set) var isComplete = false
        private(set) var isLoading = false
        private(set) var error: String?
        private(set) var tree: [RedisKeyTree.Node] = []
        fileprivate var started = false

        init(index: Int) { self.index = index }

        fileprivate func reset() {
            keys = [:]; cursor = "0"; isComplete = false; error = nil; tree = []; started = false
        }

        fileprivate func add(_ names: [String], types: [String: RedisKeyType]) {
            for name in names { keys[name] = RedisKeyEntry(key: name, type: types[name] ?? keys[name]?.type) }
        }

        fileprivate func remove(_ names: [String]) { for name in names { keys[name] = nil } }

        fileprivate func rebuild(separator: String) {
            tree = RedisKeyTree.build(Array(keys.values), separator: separator)
        }

        fileprivate func setState(cursor: String? = nil, complete: Bool? = nil, loading: Bool? = nil, error: String?? = nil) {
            if let cursor { self.cursor = cursor }
            if let complete { isComplete = complete }
            if let loading { isLoading = loading }
            if let error { self.error = error }
        }
    }

    let driver: RedisDriver
    @ObservationIgnored weak var session: Session?
    private(set) var keyspace: [Int: RedisKeyspace] = [:]
    private(set) var databases: [Int: DatabaseKeys] = [:]
    /// SCAN MATCH pattern applied to every database ("*" or empty for all keys).
    var pattern = "" { didSet { if oldValue != pattern { reloadAll() } } }
    var typeFilter: RedisKeyType? { didSet { if oldValue != typeFilter { reloadAll() } } }
    /// Folder separator (":" by default; empty shows a flat list), remembered between launches.
    var separator: String = UserDefaults.standard.string(forKey: "redisKeySeparator") ?? ":" {
        didSet {
            UserDefaults.standard.set(separator, forKey: "redisKeySeparator")
            for db in databases.values { db.rebuild(separator: separator) }
        }
    }

    init(driver: RedisDriver, session: Session) {
        self.driver = driver
        self.session = session
    }

    static func index(of database: String) -> Int? {
        database.hasPrefix("db") ? Int(database.dropFirst(2)) : Int(database)
    }

    func keyCount(_ database: String) -> Int? {
        Self.index(of: database).flatMap { keyspace[$0]?.keys }
    }

    func refreshKeyspace() async {
        if let counts = try? await driver.keyspace() { keyspace = counts }
    }

    func keys(_ index: Int) -> DatabaseKeys {
        if let existing = databases[index] { return existing }
        let created = DatabaseKeys(index: index)
        databases[index] = created
        return created
    }

    /// First page when a database is expanded.
    func open(_ index: Int) {
        let db = keys(index)
        guard !db.started else { return }
        db.started = true
        Task { await loadMore(index) }
    }

    /// Reads SCAN pages until `pageSize` new keys arrived or the scan is complete.
    func loadMore(_ index: Int) async {
        let db = keys(index)
        guard !db.isLoading, !db.isComplete else { return }
        db.setState(loading: true, error: .some(nil))
        defer { db.setState(loading: false) }
        let pattern = pattern.trimmingCharacters(in: .whitespaces)
        var added = 0
        var cursor = db.cursor
        do {
            repeat {
                let page = try await driver.scan(database: index, cursor: cursor, pattern: pattern.isEmpty ? nil : pattern,
                                                 type: typeFilter, count: 1000)
                let types = try await driver.keyTypes(database: index, keys: page.keys)
                db.add(page.keys, types: types)
                added += page.keys.count
                cursor = page.cursor
                db.setState(cursor: cursor, complete: page.isComplete)
            } while cursor != "0" && added < Self.pageSize
            db.rebuild(separator: separator)
        } catch {
            db.setState(error: .some(error.localizedDescription))
        }
    }

    func reload(_ index: Int) {
        let db = keys(index)
        db.reset()
        db.started = true
        Task {
            await refreshKeyspace()
            await loadMore(index)
        }
    }

    private func reloadAll() {
        for index in databases.keys where databases[index]?.started == true { reload(index) }
    }

    // MARK: - Changes made by the key editor

    func didCreate(_ key: String, type: RedisKeyType, in index: Int) {
        let db = keys(index)
        db.add([key], types: [key: type])
        db.rebuild(separator: separator)
        Task { await refreshKeyspace() }
    }

    func didDelete(_ keys: [String], in index: Int) {
        let db = self.keys(index)
        db.remove(keys)
        db.rebuild(separator: separator)
        Task { await refreshKeyspace() }
    }

    func didRename(_ key: String, to newKey: String, in index: Int) {
        let db = keys(index)
        let type = db.keys[key]?.type
        db.remove([key])
        db.add([newKey], types: type.map { [newKey: $0] } ?? [:])
        db.rebuild(separator: separator)
    }

    /// Every loaded key under a folder prefix (for "Delete Folder").
    func keys(under prefix: String, in index: Int) -> [String] {
        keys(index).keys.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }
}
