import Foundation

/// What a job run needs from the app's saved state. The headless runner fills it from the data directory and the Keychain.
public struct JobEnvironment: Sendable {
    public var connections: [ConnectionConfig]
    public var savedQueries: [SavedQuery]
    public var backupStore: BackupStore
    /// The connection's Keychain secrets (password, SSH, SSL key), read only for server connections.
    public var secrets: @Sendable (UUID) -> ConnectionSecrets
    public var makeDriver: @Sendable (ConnectionConfig, ConnectionSecrets) -> any DatabaseDriver

    public init(connections: [ConnectionConfig], savedQueries: [SavedQuery], backupStore: BackupStore,
                secrets: @escaping @Sendable (UUID) -> ConnectionSecrets = { _ in ConnectionSecrets() },
                makeDriver: @escaping @Sendable (ConnectionConfig, ConnectionSecrets) -> any DatabaseDriver = { DriverFactory.make(config: $0, secrets: $1) }) {
        self.connections = connections
        self.savedQueries = savedQueries
        self.backupStore = backupStore
        self.secrets = secrets
        self.makeDriver = makeDriver
    }
}

public enum JobError: LocalizedError {
    case missingConnection(UUID)
    case missingSavedQuery(UUID)
    case statementFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingConnection: "The step's connection no longer exists."
        case .missingSavedQuery: "The saved query no longer exists."
        case .statementFailed(let message): message
        }
    }
}

/// Runs a batch job's steps in order, with a connection of its own per database (through `DriverFactory`,
/// so SSH tunnels, SSL and Initial Queries behave as in the app).
public actor JobRunner {
    private let environment: JobEnvironment
    private var drivers: [String: any DatabaseDriver] = [:]
    private var run: JobRun
    private let onUpdate: @Sendable (JobRun) async -> Void

    public init(environment: JobEnvironment, job: BatchJob, trigger: JobTrigger, onUpdate: @escaping @Sendable (JobRun) async -> Void = { _ in }) {
        self.environment = environment
        self.run = JobRun(jobID: job.id, jobName: job.name, trigger: trigger)
        self.onUpdate = onUpdate
        self.job = job
    }

    private let job: BatchJob

    /// Runs the job and returns the finished run. Cancelling the task stops after the current statement.
    public func start() async -> JobRun {
        log("Job “\(job.name)” started (\(run.trigger.rawValue)).")
        await onUpdate(run)
        var failed = false
        for step in job.steps where step.enabled {
            if Task.isCancelled {
                run.status = .cancelled
                break
            }
            if failed && !job.continueOnError {
                run.steps.append(JobStepResult(stepID: step.id, title: title(of: step), status: .skipped,
                                               message: "Skipped after an earlier step failed.", finishedAt: Date()))
                continue
            }
            let index = run.steps.count
            run.steps.append(JobStepResult(stepID: step.id, title: title(of: step)))
            log("▸ \(run.steps[index].title)")
            await onUpdate(run)
            do {
                let message = try await perform(step.action)
                run.steps[index].status = .succeeded
                run.steps[index].message = message
                log("  ✓ \(message)")
            } catch is CancellationError {
                run.steps[index].status = .cancelled
                run.steps[index].message = "Cancelled."
                run.status = .cancelled
                log("  Cancelled.")
            } catch {
                run.steps[index].status = .failed
                run.steps[index].message = error.localizedDescription
                failed = true
                log("  ✗ \(error.localizedDescription)")
            }
            run.steps[index].finishedAt = Date()
            await onUpdate(run)
            if run.status == .cancelled { break }
        }
        for driver in drivers.values { await driver.disconnect() }
        drivers = [:]
        if run.status != .cancelled { run.status = failed ? .failed : .succeeded }
        run.finishedAt = Date()
        log("Job \(run.status.displayName.lowercased()) in \(String(format: "%.1f", run.duration ?? 0)) s.")
        await onUpdate(run)
        return run
    }

    private func log(_ line: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withFullTime, .withSpaceBetweenDateAndTime])
        run.log += "[\(stamp)] \(line)\n"
    }

    public func title(of step: JobStep) -> String {
        Self.title(of: step.action, connections: environment.connections, savedQueries: environment.savedQueries)
    }

    /// "Backup — Demo › main", "Run Saved Query — Top customers".
    public static func title(of action: JobAction, connections: [ConnectionConfig], savedQueries: [SavedQuery]) -> String {
        func place(_ target: JobTarget) -> String {
            let name = connections.first { $0.id == target.connectionID }?.displayName ?? "missing connection"
            return "\(name) › \(target.database)\(target.schema.map { ".\($0)" } ?? "")"
        }
        switch action {
        case .savedQuery(let id):
            return "Run Saved Query — " + (savedQueries.first { $0.id == id }?.name ?? "missing query")
        case .sql(let target, _): return "Run SQL — " + place(target)
        case .sqlFile(let target, let path, _): return "Execute \(URL(fileURLWithPath: path).lastPathComponent) — " + place(target)
        case .backup(let target, _): return "Backup — " + place(target)
        case .export(let settings): return "Export \(settings.format.displayName) — " + place(settings.target)
        case .dataTransfer(let s): return "Data Transfer — \(place(s.source)) → \(place(s.destination))"
        }
    }

    // MARK: - Steps

    private func perform(_ action: JobAction) async throws -> String {
        switch action {
        case .savedQuery(let id):
            guard let query = environment.savedQueries.first(where: { $0.id == id }) else { throw JobError.missingSavedQuery(id) }
            let driver = try await driver(for: JobTarget(connectionID: query.connectionID, database: query.database))
            return try await runStatements(SQLSplitter.split(query.sql), on: driver, options: ScriptRunOptions())
        case .sql(let target, let sql):
            return try await runStatements(SQLSplitter.split(sql), on: try await driver(for: target), options: ScriptRunOptions())
        case .sqlFile(let target, let path, let options):
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let text = try String(contentsOf: url, encoding: .utf8)
            return try await runStatements(SQLSplitter.split(text), on: try await driver(for: target), options: options)
        case .backup(let target, let options):
            let config = try connection(target.connectionID)
            let driver = try await driver(for: target)
            let entry = try await BackupEngine.create(from: driver, connection: config, database: target.database, schema: target.schema,
                                                      options: options, store: environment.backupStore)
            let size = ByteCountFormatter.string(fromByteCount: Int64(entry.fileSize), countStyle: .file)
            return "Backup \(entry.name) (\(entry.manifest.objects.count) objects\(entry.manifest.rowCount.map { ", \($0) rows" } ?? ""), \(size))"
        case .export(let settings):
            return try await export(settings)
        case .dataTransfer(let settings):
            return try await transfer(settings)
        }
    }

    private func runStatements(_ statements: [String], on driver: any DatabaseDriver, options: ScriptRunOptions) async throws -> String {
        let report = await driver.runScript(statements, options: options)
        try Task.checkCancellation()
        if let error = report.errors.first, options.stopOnError || report.succeeded == 0 {
            throw JobError.statementFailed("Statement \(error.index + 1) failed: \(error.message)")
        }
        var text = "\(report.succeeded) of \(report.total) statement\(report.total == 1 ? "" : "s") ran, \(report.affectedRows) row\(report.affectedRows == 1 ? "" : "s") affected"
        if !report.errors.isEmpty { text += ", \(report.errors.count) failed (continued)" }
        return text
    }

    private func export(_ settings: ExportStepSettings) async throws -> String {
        let driver = try await driver(for: settings.target)
        let config = try connection(settings.target.connectionID)
        let listSchema: String? = switch config.kind {
        case .postgresql: settings.target.schema ?? "public"
        case .mysql, .mariadb: settings.target.database
        case .sqlite: nil
        case .redis: nil
        }
        let all = try await driver.listObjects(schema: listSchema).filter { $0.kind != .routine }
        let wanted = Set(settings.objects.map(\.name))
        let objects = settings.objects.isEmpty ? all : all.filter { wanted.contains($0.name) }
        guard !objects.isEmpty else { throw BackupError.nothingToBackUp }
        var folder = URL(fileURLWithPath: (settings.outputDirectory as NSString).expandingTildeInPath, isDirectory: true)
        if settings.timestampedFolder {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HHmmss"
            folder = folder.appending(path: formatter.string(from: Date()), directoryHint: .isDirectory)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if settings.format == .xlsx && settings.singleWorkbook {
            let data = try await TableExporter.workbook(objects, from: driver, includeHeader: settings.includeHeader)
            try data.write(to: folder.appending(path: Self.fileName(settings.target.database, extension: "xlsx")), options: .atomic)
        } else {
            for object in objects {
                try Task.checkCancellation()
                let data = try await TableExporter.export(object, from: driver, as: settings.format, options: settings.exportOptions)
                try data.write(to: folder.appending(path: Self.fileName(object.name, extension: settings.format.fileExtension)), options: .atomic)
            }
        }
        return "Exported \(objects.count) object\(objects.count == 1 ? "" : "s") to \(folder.path)"
    }

    /// Navicat's Data Transfer between two saved connections (`DataTransfer`).
    private func transfer(_ settings: DataTransferStepSettings) async throws -> String {
        let sourceConfig = try connection(settings.source.connectionID)
        let targetConfig = try connection(settings.destination.connectionID)
        let source = try await driver(for: settings.source)
        let destination = try await driver(for: settings.destination)
        func schema(_ config: ConnectionConfig, _ target: JobTarget) -> String? {
            switch config.kind {
            case .postgresql: target.schema ?? "public"
            case .mysql, .mariadb: target.database
            case .sqlite: nil
            case .redis: nil
            }
        }
        let sourceSchema = schema(sourceConfig, settings.source)
        var tables = settings.tables
        if tables.isEmpty {
            tables = try await source.listObjects(schema: sourceSchema).filter { $0.kind == .table }.map(\.name)
        }
        guard !tables.isEmpty else { throw BackupError.nothingToBackUp }
        let job = DataTransfer(source: source, sourceSchema: sourceSchema, tables: tables,
                               destination: .database(destination, schema: schema(targetConfig, settings.destination)),
                               options: settings.options)
        let summary = try await job.run()
        if summary.errors > 0 && !settings.continueOnError {
            throw JobError.statementFailed("Data Transfer finished with \(summary.errors) error\(summary.errors == 1 ? "" : "s").")
        }
        return "Transferred \(summary.tables) table\(summary.tables == 1 ? "" : "s"), \(summary.rows) rows\(summary.errors > 0 ? ", \(summary.errors) errors (continued)" : "")"
    }

    /// A file name for an object, without path separators.
    public static func fileName(_ name: String, extension ext: String) -> String {
        let safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return "\(safe.isEmpty ? "export" : safe).\(ext)"
    }

    // MARK: - Connections

    private func connection(_ id: UUID) throws -> ConnectionConfig {
        guard let config = environment.connections.first(where: { $0.id == id }) else { throw JobError.missingConnection(id) }
        return config
    }

    private func driver(for target: JobTarget) async throws -> any DatabaseDriver {
        let key = "\(target.connectionID.uuidString)/\(target.database)"
        if let existing = drivers[key] { return existing }
        var config = try connection(target.connectionID)
        if config.kind != .sqlite, !target.database.isEmpty { config.database = target.database }
        let secrets = config.kind.isFileBased ? ConnectionSecrets() : environment.secrets(config.id)
        let driver = environment.makeDriver(config, secrets)
        try await driver.connect()
        do {
            try await Self.runInitialQueries(config, on: driver)
        } catch {
            await driver.disconnect()
            throw error
        }
        drivers[key] = driver
        return driver
    }

    /// The connection's Initial Queries (Advanced tab), as a session runs them.
    public static func runInitialQueries(_ config: ConnectionConfig, on driver: any DatabaseDriver) async throws {
        guard let script = config.initialQueries, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        for statement in SQLSplitter.split(script) {
            do {
                _ = try await driver.executeTimed(statement)
            } catch {
                throw JobError.statementFailed("Initial query failed (\(statement.prefix(80))): \(error.localizedDescription)")
            }
        }
    }
}
