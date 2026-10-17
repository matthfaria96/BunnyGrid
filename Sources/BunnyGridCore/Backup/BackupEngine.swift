import Foundation
import SQLite3

/// What a new backup contains (Navicat's Backup wizard: General comment, Object Selection, Advanced).
public struct BackupOptions: Codable, Hashable, Sendable {
    /// Tables and views to back up; nil backs up every table and view of the database or schema.
    public var objects: [BackupObject]?
    public var includeStructure: Bool
    public var includeData: Bool
    public var method: BackupMethod
    public var comment: String

    public init(objects: [BackupObject]? = nil, includeStructure: Bool = true, includeData: Bool = true,
                method: BackupMethod = .sql, comment: String = "") {
        self.objects = objects
        self.includeStructure = includeStructure
        self.includeData = includeData
        self.method = method
        self.comment = comment
    }
}

/// Navicat's Restore Backup options.
public struct RestoreOptions: Codable, Hashable, Sendable {
    /// Run the backup's DROP … IF EXISTS before each CREATE; off leaves existing objects alone (their CREATE fails).
    public var dropExisting: Bool
    /// Log failing statements and go on instead of stopping at the first one.
    public var continueOnError: Bool
    /// Run everything in one transaction, rolled back if the restore stops on an error.
    public var useTransaction: Bool

    public init(dropExisting: Bool = true, continueOnError: Bool = false, useTransaction: Bool = false) {
        self.dropExisting = dropExisting
        self.continueOnError = continueOnError
        self.useTransaction = useTransaction
    }
}

public enum BackupError: LocalizedError {
    case nothingToBackUp
    case sqliteOnly
    case noFile
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case .nothingToBackUp: "There are no tables or views to back up."
        case .sqliteOnly: "A SQLite file copy can only be made of, and restored into, a SQLite database file."
        case .noFile: "The SQLite database has no file (in-memory databases cannot be copied)."
        case .sqlite(let message): "SQLite backup failed: \(message)"
        }
    }
}

/// Creates, restores and extracts backups, on top of `SQLDumper` and `runScript`.
public enum BackupEngine {
    /// Backs up a database (or one PostgreSQL schema). `schema` is the driver's schema argument
    /// (the schema on PostgreSQL, nil on SQLite; MySQL backups use the database).
    public static func create(from driver: any DatabaseDriver, connection: ConnectionConfig, database: String, schema: String?,
                              options: BackupOptions, store: BackupStore,
                              progress: @Sendable (String) async -> Void = { _ in }) async throws -> BackupEntry {
        let listSchema: String? = switch connection.kind {
        case .postgresql: schema ?? "public"
        case .mysql, .mariadb, .mongodb: schema ?? database
        case .sqlite: nil
        case .redis: nil
        }
        let manifestSchema = connection.kind == .postgresql ? listSchema : nil
        await progress("Reading the object list…")
        let all = try await driver.listObjects(schema: listSchema).filter { $0.kind == .table || $0.kind == .view || $0.kind == .materializedView }
        let objects: [DatabaseObject]
        if let chosen = options.objects {
            let wanted = Set(chosen.map { $0.name })
            objects = all.filter { wanted.contains($0.name) }
        } else {
            objects = all
        }
        let version = try? await driver.serverVersion()
        var manifest = BackupManifest(connectionID: connection.id, connectionName: connection.displayName, engine: connection.kind,
                                      database: database, schema: manifestSchema, comment: options.comment, method: options.method,
                                      objects: objects.map(BackupObject.init), includeStructure: options.includeStructure,
                                      includeData: options.includeData, serverVersion: version)
        let payload: Data
        switch options.method {
        case .sqliteFile:
            guard connection.kind == .sqlite else { throw BackupError.sqliteOnly }
            let path = (connection.filePath as NSString).expandingTildeInPath
            guard !connection.filePath.isEmpty else { throw BackupError.noFile }
            await progress("Copying \(URL(fileURLWithPath: path).lastPathComponent)…")
            payload = try SQLiteFileBackup.snapshot(of: path)
        case .sql:
            guard !objects.isEmpty else { throw BackupError.nothingToBackUp }
            var rows = 0
            var parts: [String] = []
            let header = """
                BunnyGrid backup of \(connection.displayName) › \(database)\(manifestSchema.map { ".\($0)" } ?? "")
                \(connection.kind.displayName)\(version.map { " (\($0))" } ?? "")
                Created \(ISO8601DateFormatter().string(from: manifest.createdAt))\(options.comment.isEmpty ? "" : "\nComment: \(options.comment)")
                """
            parts.append(header.split(separator: "\n", omittingEmptySubsequences: false).map { "-- " + $0 }.joined(separator: "\n"))
            if connection.kind == .postgresql, let s = manifestSchema, s != "public", options.includeStructure {
                parts.append("CREATE SCHEMA IF NOT EXISTS \(driver.dialect.quoteIdentifier(s));")
            }
            await progress("Writing \(objects.count) object\(objects.count == 1 ? "" : "s")…")
            let dump = try await SQLDumper.dump(objects, from: driver,
                                                options: SQLDumpOptions(includeDrop: true, includeStructure: options.includeStructure,
                                                                        includeData: options.includeData, rowsPerInsert: 100))
            parts.append(dump)
            if options.includeData {
                for object in objects where object.kind == .table {
                    rows += (try? await driver.countRows(table: object.name, schema: object.schema)) ?? 0
                }
            }
            manifest.rowCount = options.includeData ? rows : nil
            payload = Data(parts.joined(separator: "\n\n").utf8)
        }
        manifest.uncompressedSize = payload.count
        await progress("Compressing…")
        return try store.write(manifest, payload: payload)
    }

    /// The backup as a runnable SQL script (Navicat's "Extract SQL"). A SQLite file copy is dumped from a temporary copy.
    public static func extractSQL(_ entry: BackupEntry, store: BackupStore) async throws -> String {
        let payload = try store.payload(of: entry)
        switch entry.manifest.method {
        case .sql:
            return String(decoding: payload, as: UTF8.self)
        case .sqliteFile:
            let temp = FileManager.default.temporaryDirectory.appending(path: "bunnygrid-extract-\(UUID().uuidString).sqlite")
            try payload.write(to: temp)
            defer { try? FileManager.default.removeItem(at: temp) }
            var config = ConnectionConfig(name: entry.manifest.connectionName, kind: .sqlite, filePath: temp.path)
            config.readOnly = true
            let driver = SQLiteDriver(config: config)
            try await driver.connect()
            do {
                let objects = try await driver.listObjects(schema: nil)
                let sql = try await SQLDumper.dump(objects, from: driver, options: SQLDumpOptions(rowsPerInsert: 100),
                                                   header: "BunnyGrid backup \(entry.name) of \(entry.manifest.connectionName) (SQLite file copy)")
                await driver.disconnect()
                return sql
            } catch {
                await driver.disconnect()
                throw error
            }
        }
    }

    /// The statements a restore runs: the backup script, without its DROPs unless `dropExisting`.
    /// The DROPs run first, in reverse order (views and referencing tables before what they depend on);
    /// on PostgreSQL with CASCADE, so objects outside the backup that depend on them don't block the restore.
    public static func restoreStatements(_ sql: String, options: RestoreOptions, engine: DatabaseKind? = nil) -> [String] {
        let statements = SQLSplitter.split(sql)
        let rest = statements.filter { !isDrop($0) }
        guard options.dropExisting else { return rest }
        let drops = statements.filter(isDrop).reversed().map { engine == .postgresql ? $0 + " CASCADE" : $0 }
        return drops + rest
    }

    static func isDrop(_ statement: String) -> Bool {
        let code = statement.split(separator: "\n", omittingEmptySubsequences: false)
            .drop { $0.trimmingCharacters(in: .whitespaces).hasPrefix("--") || $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n").uppercased()
        return ["DROP TABLE IF EXISTS ", "DROP VIEW IF EXISTS ", "DROP MATERIALIZED VIEW IF EXISTS "].contains { code.hasPrefix($0) }
    }

    /// Restores into `driver`'s database: the same one or another database of the same engine.
    /// A SQLite file copy replaces the target file's content page by page (`sqlite3_backup`).
    public static func restore(_ entry: BackupEntry, store: BackupStore, into driver: any DatabaseDriver,
                               options: RestoreOptions = RestoreOptions(),
                               progress: @Sendable (ScriptRunReport) async -> Void = { _ in }) async throws -> ScriptRunReport {
        if driver.config.readOnly { throw DatabaseError.readOnly }
        let payload = try store.payload(of: entry)
        switch entry.manifest.method {
        case .sqliteFile:
            guard driver.config.kind == .sqlite else { throw BackupError.sqliteOnly }
            guard !driver.config.filePath.isEmpty else { throw BackupError.noFile }
            try SQLiteFileBackup.restore(payload, into: (driver.config.filePath as NSString).expandingTildeInPath)
            var report = ScriptRunReport(total: 1)
            report.executed = 1
            report.succeeded = 1
            await progress(report)
            return report
        case .sql:
            let statements = restoreStatements(String(decoding: payload, as: UTF8.self), options: options, engine: entry.manifest.engine)
            return await driver.runScript(statements, options: ScriptRunOptions(stopOnError: !options.continueOnError,
                                                                                 useTransaction: options.useTransaction),
                                          progress: progress)
        }
    }
}

/// File-level copies of SQLite databases with the online backup API, safe while other connections use the file.
public enum SQLiteFileBackup {
    /// The bytes of a consistent copy of the database at `path`.
    public static func snapshot(of path: String) throws -> Data {
        let temp = FileManager.default.temporaryDirectory.appending(path: "bunnygrid-backup-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: temp) }
        try copy(from: path, sourceFlags: SQLITE_OPEN_READONLY, to: temp.path)
        return try Data(contentsOf: temp)
    }

    /// Replaces the content of the database at `path` with the database in `data`.
    public static func restore(_ data: Data, into path: String) throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: "bunnygrid-restore-\(UUID().uuidString).sqlite")
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        try copy(from: temp.path, sourceFlags: SQLITE_OPEN_READONLY, to: path)
    }

    static func copy(from source: String, sourceFlags: Int32, to destination: String) throws {
        var src: OpaquePointer?, dst: OpaquePointer?
        defer {
            sqlite3_close_v2(src)
            sqlite3_close_v2(dst)
        }
        guard sqlite3_open_v2(source, &src, sourceFlags, nil) == SQLITE_OK else {
            throw BackupError.sqlite(src.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(source)")
        }
        guard sqlite3_open_v2(destination, &dst, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw BackupError.sqlite(dst.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(destination)")
        }
        sqlite3_busy_timeout(dst, 5_000)
        sqlite3_busy_timeout(src, 5_000)
        guard let backup = sqlite3_backup_init(dst, "main", src, "main") else {
            throw BackupError.sqlite(String(cString: sqlite3_errmsg(dst)))
        }
        var rc: Int32
        repeat {
            rc = sqlite3_backup_step(backup, 256)
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED { sqlite3_sleep(25) }
        } while rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED
        sqlite3_backup_finish(backup)
        guard rc == SQLITE_DONE else { throw BackupError.sqlite(String(cString: sqlite3_errstr(rc))) }
    }
}
