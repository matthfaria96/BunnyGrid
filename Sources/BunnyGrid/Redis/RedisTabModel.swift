import BunnyGridCore
import Foundation
import Observation
import SwiftUI

/// A Redis workspace tab: a key viewer, the console, or the server monitor. One `WorkspaceTab` case
/// (`.redis`) covers all three so shared switches gain a single line.
@MainActor
@Observable
final class RedisTabModel: Identifiable {
    enum Content {
        case key(RedisKeyModel)
        case console(RedisConsoleModel)
        case server(RedisServerModel)
    }

    let id = UUID()
    let content: Content
    let connectionID: UUID?
    let connectionName: String

    init(content: Content, session: Session) {
        self.content = content
        connectionID = session.id
        connectionName = session.config.displayName
        iconName = switch content {
        case .key: "engine-redis"
        case .console: "query"
        case .server: "others"
        }
    }

    var title: String {
        switch content {
        case .key(let model): "\(model.key) @\(connectionName).db\(model.database) (Redis)"
        case .console(let model): "Console @\(connectionName).db\(model.database) (Redis)"
        case .server: "Server Monitor @\(connectionName) (Redis)"
        }
    }

    var kindName: String {
        switch content {
        case .key: "Key"
        case .console: "Console"
        case .server: "Server Monitor"
        }
    }

    /// Illustrated icon of the tab bar (Resources/Icons).
    nonisolated let iconName: String

    var hasUnsavedChanges: Bool {
        if case .key(let model) = content { model.hasUnsavedText } else { false }
    }

    var statusText: String {
        switch content {
        case .key(let model): model.statusText
        case .console(let model): model.entries.isEmpty ? "" : "\(model.entries.count) commands"
        case .server(let model): model.statusText
        }
    }

    var error: String? {
        switch content {
        case .key(let model): model.error
        case .console: nil
        case .server(let model): model.error
        }
    }

    func close() {
        switch content {
        case .console(let model): model.close()
        case .server(let model): model.stop()
        case .key: break
        }
    }
}

// MARK: - Key viewer

@MainActor
@Observable
final class RedisKeyModel {
    /// Elements read per load; "Load More" raises it.
    static let pageSize = 500

    let database: Int
    private(set) var key: String
    let driver: RedisDriver
    @ObservationIgnored weak var browser: RedisBrowserModel?
    private(set) var info: RedisKeyInfo?
    private(set) var value: RedisValue?
    private(set) var isLoading = false
    var error: String?
    private(set) var limit = RedisKeyModel.pageSize
    /// The string / JSON editor's text and whether it differs from the stored value.
    var draftText = "" { didSet { if draftText != oldValue { hasUnsavedText = draftText != savedText } } }
    private(set) var hasUnsavedText = false
    @ObservationIgnored private var savedText = ""
    /// Bumped after every reload so editors reset their selection.
    private(set) var revision = 0

    init(database: Int, key: String, driver: RedisDriver, browser: RedisBrowserModel?) {
        self.database = database
        self.key = key
        self.driver = driver
        self.browser = browser
    }

    var isReadOnly: Bool { driver.config.readOnly }

    var isTruncated: Bool {
        guard let length = info?.length, let value else { return false }
        if case .string = value { return false }
        return value.count < Int(length)
    }

    var statusText: String {
        guard let info else { return "" }
        var parts = [info.type.displayName]
        if let length = info.length {
            if case .string = info.type { parts.append("\(length.formatted()) bytes") } else {
                parts.append(value.map { "\($0.count.formatted()) of \(length.formatted()) items" } ?? "\(length) items")
            }
        }
        if let memory = info.memoryBytes { parts.append("memory \(ByteCountFormatter.string(fromByteCount: memory, countStyle: .memory))") }
        parts.append(info.ttl >= 0 ? "TTL \(info.ttl) s" : "no expiry")
        return parts.joined(separator: " · ")
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let info = try await driver.keyInfo(database: database, key: key)
            self.info = info
            guard info.exists else {
                value = nil
                error = "The key “\(key)” no longer exists."
                return
            }
            let value = try await driver.readValue(database: database, key: key, type: info.type, limit: limit)
            self.value = value
            switch value {
            case .string(let data): savedText = String(decoding: data, as: UTF8.self)
            case .json(let text): savedText = (try? JSONFormatter.pretty(text)) ?? text
            default: savedText = ""
            }
            draftText = savedText
            hasUnsavedText = false
            error = nil
            revision += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMore() async {
        limit += Self.pageSize
        await load()
    }

    /// Runs a change, then reloads; errors show in the footer.
    func perform(_ change: @escaping (RedisDriver) async throws -> Void) async {
        do {
            try await change(driver)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func saveText() async {
        guard let info else { return }
        let text = draftText
        let key = key, db = database
        switch info.type {
        case .json:
            await perform { try await $0.setJSON(database: db, key: key, json: text) }
        default:
            await perform { try await $0.setString(database: db, key: key, value: Data(text.utf8)) }
        }
    }

    /// Stores raw bytes (hex editor, file import).
    func saveBytes(_ data: Data) async {
        let key = key, db = database
        await perform { try await $0.setString(database: db, key: key, value: data) }
    }

    func setTTL(_ seconds: Int64?) async {
        let key = key, db = database
        await perform { try await $0.setTTL(database: db, key: key, seconds: seconds) }
    }

    func rename(to newKey: String) async {
        let newKey = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newKey.isEmpty, newKey != key else { return }
        do {
            try await driver.rename(database: database, key: key, to: newKey)
            browser?.didRename(key, to: newKey, in: database)
            key = newKey
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Deletes the key; returns whether it worked (the tab then closes).
    func deleteKey() async -> Bool {
        do {
            try await driver.delete(database: database, keys: [key])
            browser?.didDelete([key], in: database)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

// MARK: - Console

@MainActor
@Observable
final class RedisConsoleModel {
    struct Entry: Identifiable {
        let id = UUID()
        let database: Int
        let command: String
        let reply: RESPValue?
        let error: String?
        let duration: Duration
    }

    private let driver: RedisDriver
    private(set) var database: Int
    private(set) var entries: [Entry] = []
    private(set) var isRunning = false
    private(set) var isConnected = false
    var input = ""
    /// Earlier commands, oldest first, for ↑ / ↓.
    private(set) var history: [String] = UserDefaults.standard.stringArray(forKey: "redisConsoleHistory") ?? []
    @ObservationIgnored private var historyIndex: Int?

    /// The console has its own connection, so SELECT, MULTI or a blocking command don't disturb the browser.
    init(driver: RedisDriver, database: Int) {
        self.driver = driver
        self.database = database
    }

    var prompt: String {
        let config = driver.config
        let place = config.activeSocketPath ?? "\(config.host):\(config.port)"
        return database == 0 ? "\(place)> " : "\(place)[\(database)]> "
    }

    func connect() async {
        do {
            try await driver.connect()
            isConnected = true
        } catch {
            entries.append(Entry(database: database, command: "", reply: nil, error: error.localizedDescription, duration: .zero))
        }
    }

    /// Runs the input; several lines run one after another.
    func run() async {
        let lines = input.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty, !isRunning else { return }
        input = ""
        historyIndex = nil
        isRunning = true
        defer { isRunning = false }
        if !isConnected { await connect() }
        for line in lines {
            remember(line)
            if line.lowercased() == "clear" { entries = []; continue }
            let clock = ContinuousClock(), start = clock.now
            do {
                let (reply, db) = try await driver.runCommandLine(line, database: database)
                entries.append(Entry(database: database, command: line, reply: reply, error: nil, duration: clock.now - start))
                database = db
            } catch {
                entries.append(Entry(database: database, command: line, reply: nil, error: error.localizedDescription, duration: clock.now - start))
            }
        }
    }

    private func remember(_ line: String) {
        if history.last != line { history.append(line) }
        if history.count > 200 { history.removeFirst(history.count - 200) }
        UserDefaults.standard.set(history, forKey: "redisConsoleHistory")
    }

    /// ↑ (-1) and ↓ (+1) through the history.
    func step(_ offset: Int) {
        guard !history.isEmpty else { return }
        let next = (historyIndex ?? history.count) + offset
        if next >= history.count {
            historyIndex = nil
            input = ""
        } else {
            historyIndex = max(0, next)
            input = history[historyIndex!]
        }
    }

    func clear() { entries = [] }

    func close() {
        let driver = driver
        Task { await driver.disconnect() }
    }
}

// MARK: - Server monitor

@MainActor
@Observable
final class RedisServerModel {
    let driver: RedisDriver
    private(set) var sections: [RedisInfo.Section] = []
    private(set) var clients: [[String: String]] = []
    private(set) var slowlog: [RedisInfo.SlowlogEntry] = []
    private(set) var lastRefresh: Date?
    var error: String?
    var autoRefresh = false { didSet { autoRefresh ? start() : stop() } }
    @ObservationIgnored private var timer: Task<Void, Never>?

    init(driver: RedisDriver) {
        self.driver = driver
    }

    func value(_ key: String) -> String? {
        for section in sections { if let entry = section.entries.first(where: { $0.key == key }) { return entry.value } }
        return nil
    }

    var statusText: String {
        lastRefresh.map { "Refreshed \($0.formatted(date: .omitted, time: .standard))" } ?? ""
    }

    /// keyspace_hits / (hits + misses).
    var hitRate: Double? {
        guard let hits = value("keyspace_hits").flatMap(Double.init), let misses = value("keyspace_misses").flatMap(Double.init),
              hits + misses > 0 else { return nil }
        return hits / (hits + misses)
    }

    func refresh() async {
        do {
            sections = RedisInfo.parse(try await driver.info(section: "everything"))
            clients = (try? await driver.clientList()) ?? []
            slowlog = (try? await driver.slowlog()) ?? []
            lastRefresh = Date()
            error = nil
        } catch {
            // Some managed services refuse INFO everything; fall back to the default sections.
            if let text = try? await driver.info() {
                sections = RedisInfo.parse(text)
                lastRefresh = Date()
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    private func start() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

/// The content of a `.redis` workspace tab.
struct RedisTabView: View {
    let model: RedisTabModel

    var body: some View {
        switch model.content {
        case .key(let key): RedisKeyView(model: key, tabID: model.id)
        case .console(let console): RedisConsoleView(model: console)
        case .server(let server): RedisServerView(model: server)
        }
    }
}
