import BunnyGridCore
import Foundation

extension AppModel {
    /// With `--connect-first` on a Redis connection: `--redis-expand db0[,prefix:…]` expands the tree,
    /// `--redis-key KEY` opens a key (in the default database), `--redis-console [COMMANDS]` runs commands,
    /// `--redis-server` opens the Server Monitor, `--redis-new-key` shows the New Key sheet.
    func runRedisLaunchFlags() {
        #if DEBUG
        let args = CommandLine.arguments
        guard args.contains("--connect-first"), let first = connections.first, first.kind == .redis else { return }
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1), !args[i + 1].hasPrefix("--") else { return nil }
            return args[i + 1]
        }
        Task {
            while sessions[first.id]?.redis == nil { try? await Task.sleep(for: .milliseconds(50)) }
            guard let session = sessions[first.id] else { return }
            let db = (session.driver as? RedisDriver)?.defaultDatabase ?? 0
            if let expand = value("--redis-expand") {
                let parts = expand.split(separator: ",").map(String.init)
                let dbName = parts.first ?? "db\(db)"
                setExpanded(.database(first.id, dbName), true)
                navSelection = .database(first.id, dbName)
                try? await Task.sleep(for: .milliseconds(600))
                for prefix in parts.dropFirst() { expanded.insert(.redisFolder(first.id, RedisBrowserModel.index(of: dbName) ?? 0, prefix)) }
            }
            if let key = value("--redis-key") {
                openRedisKey(key, database: db, connectionID: first.id)
            }
            if args.contains("--redis-console") {
                openRedisConsole(connectionID: first.id, database: db)
                if case .redis(let model) = selectedTab, case .console(let console) = model.content {
                    await console.connect()
                    console.input = value("--redis-console") ?? "PING\nHGETALL user:1\nZRANGE leaderboard 0 -1 WITHSCORES\nGET missing\nNOSUCH"
                    await console.run()
                }
            }
            if args.contains("--redis-server") { openRedisServerMonitor(connectionID: first.id) }
            if args.contains("--redis-new-key") { redisNewKey = RedisNewKeyTarget(connectionID: first.id, database: db, prefix: "user:") }
        }
        #endif
    }
}
