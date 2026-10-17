import Foundation

extension TableExportFormat: Codable {}

/// Where a step runs: a saved connection and one of its databases ("main" on SQLite).
public struct JobTarget: Codable, Hashable, Sendable {
    public var connectionID: UUID
    public var database: String
    /// PostgreSQL schema (backups and exports); nil elsewhere.
    public var schema: String?

    public init(connectionID: UUID, database: String, schema: String? = nil) {
        self.connectionID = connectionID
        self.database = database
        self.schema = schema
    }
}

/// An Export Wizard run saved in a job: the wizard's format and options, the objects and the output folder.
public struct ExportStepSettings: Codable, Hashable, Sendable {
    public var target: JobTarget
    /// Empty exports every table and view.
    public var objects: [BackupObject]
    public var format: TableExportFormat
    public var csvDelimiter: String
    public var includeHeader: Bool
    public var sqlStructure: Bool
    public var sqlDrop: Bool
    public var sqlData: Bool
    public var rowsPerInsert: Int
    /// Excel: one workbook with a sheet per object.
    public var singleWorkbook: Bool
    public var outputDirectory: String
    /// Write into a new `yyyy-MM-dd HHmmss` folder on every run, so earlier exports are kept.
    public var timestampedFolder: Bool

    public init(target: JobTarget, objects: [BackupObject] = [], format: TableExportFormat = .csv, csvDelimiter: String = ",",
                includeHeader: Bool = true, sqlStructure: Bool = true, sqlDrop: Bool = true, sqlData: Bool = true,
                rowsPerInsert: Int = 1, singleWorkbook: Bool = true, outputDirectory: String = "", timestampedFolder: Bool = true) {
        self.target = target
        self.objects = objects
        self.format = format
        self.csvDelimiter = csvDelimiter
        self.includeHeader = includeHeader
        self.sqlStructure = sqlStructure
        self.sqlDrop = sqlDrop
        self.sqlData = sqlData
        self.rowsPerInsert = rowsPerInsert
        self.singleWorkbook = singleWorkbook
        self.outputDirectory = outputDirectory
        self.timestampedFolder = timestampedFolder
    }

    public var exportOptions: TableExportOptions {
        TableExportOptions(csvDelimiter: csvDelimiter.first ?? ",", includeHeader: includeHeader,
                           sql: SQLDumpOptions(includeDrop: sqlDrop, includeStructure: sqlStructure, includeData: sqlData,
                                               rowsPerInsert: rowsPerInsert))
    }
}

/// A Data Transfer saved in a job: source and target databases, the tables (empty = every table) and the options.
public struct DataTransferStepSettings: Codable, Hashable, Sendable {
    public var source: JobTarget
    public var destination: JobTarget
    public var tables: [String]
    public var createTables: Bool
    public var dropTargetTables: Bool
    public var transferData: Bool
    public var createIndexes: Bool
    public var createForeignKeys: Bool
    public var continueOnError: Bool

    public init(source: JobTarget, destination: JobTarget, tables: [String] = [], createTables: Bool = true, dropTargetTables: Bool = false,
                transferData: Bool = true, createIndexes: Bool = true, createForeignKeys: Bool = true, continueOnError: Bool = false) {
        self.source = source
        self.destination = destination
        self.tables = tables
        self.createTables = createTables
        self.dropTargetTables = dropTargetTables
        self.transferData = transferData
        self.createIndexes = createIndexes
        self.createForeignKeys = createForeignKeys
        self.continueOnError = continueOnError
    }

    public var options: DataTransferOptions {
        DataTransferOptions(createTables: createTables, dropTargetTables: dropTargetTables, transferData: transferData,
                            createIndexes: createIndexes, createForeignKeys: createForeignKeys, continueOnError: continueOnError)
    }
}

/// What one step of a batch job does.
public enum JobAction: Codable, Hashable, Sendable {
    /// A query from the navigator's Queries folder (it carries its own connection and database).
    case savedQuery(queryID: UUID)
    /// SQL typed into the step.
    case sql(target: JobTarget, sql: String)
    /// Navicat's Execute SQL File.
    case sqlFile(target: JobTarget, path: String, options: ScriptRunOptions)
    case backup(target: JobTarget, options: BackupOptions)
    case export(ExportStepSettings)
    case dataTransfer(DataTransferStepSettings)

    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case savedQuery, sql, sqlFile, backup, export, dataTransfer
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .savedQuery: "Run Saved Query"
            case .sql: "Run SQL"
            case .sqlFile: "Execute SQL File"
            case .backup: "Backup"
            case .export: "Export"
            case .dataTransfer: "Data Transfer"
            }
        }
        public var systemImage: String {
            switch self {
            case .savedQuery: "doc.text.magnifyingglass"
            case .sql: "terminal"
            case .sqlFile: "doc.text"
            case .backup: "clock.arrow.circlepath"
            case .export: "square.and.arrow.up"
            case .dataTransfer: "arrow.left.arrow.right"
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .savedQuery: .savedQuery
        case .sql: .sql
        case .sqlFile: .sqlFile
        case .backup: .backup
        case .export: .export
        case .dataTransfer: .dataTransfer
        }
    }

    /// The step's database, when it names one itself (a saved query brings its own).
    public var target: JobTarget? {
        switch self {
        case .savedQuery: nil
        case .sql(let target, _), .sqlFile(let target, _, _), .backup(let target, _): target
        case .export(let settings): settings.target
        case .dataTransfer(let settings): settings.source
        }
    }
}

extension ScriptRunOptions: Codable {
    enum CodingKeys: String, CodingKey { case stopOnError, useTransaction }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(stopOnError: try c.decodeIfPresent(Bool.self, forKey: .stopOnError) ?? true,
                  useTransaction: try c.decodeIfPresent(Bool.self, forKey: .useTransaction) ?? false)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(stopOnError, forKey: .stopOnError)
        try c.encode(useTransaction, forKey: .useTransaction)
    }
}

extension ScriptRunOptions: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(stopOnError)
        hasher.combine(useTransaction)
    }
}

public struct JobStep: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var enabled: Bool
    public var action: JobAction

    public init(id: UUID = UUID(), enabled: Bool = true, action: JobAction) {
        self.id = id
        self.enabled = enabled
        self.action = action
    }
}

/// Navicat's batch job: steps run in order, by hand or on a schedule (also while the app is closed).
public struct BatchJob: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var steps: [JobStep]
    public var schedule: JobSchedule
    /// The schedule is active (a launch agent is installed).
    public var scheduleEnabled: Bool
    /// Go on with the next step when one fails.
    public var continueOnError: Bool
    public var notifyOnSuccess: Bool
    public var notifyOnFailure: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, steps: [JobStep] = [], schedule: JobSchedule = .manual, scheduleEnabled: Bool = true,
                continueOnError: Bool = false, notifyOnSuccess: Bool = true, notifyOnFailure: Bool = true,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.steps = steps
        self.schedule = schedule
        self.scheduleEnabled = scheduleEnabled
        self.continueOnError = continueOnError
        self.notifyOnSuccess = notifyOnSuccess
        self.notifyOnFailure = notifyOnFailure
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Whether launchd should start this job.
    public var runsOnSchedule: Bool { scheduleEnabled && schedule.isScheduled }

    public var launchdLabel: String { LaunchAgentScheduler.label(for: id) }
}

public enum JobRunStatus: String, Codable, Sendable {
    case running, succeeded, failed, cancelled, skipped

    public var displayName: String {
        switch self {
        case .running: "Running"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .skipped: "Skipped"
        }
    }
}

public enum JobTrigger: String, Codable, Sendable {
    case manual, scheduled
}

public struct JobStepResult: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID { stepID }
    public var stepID: UUID
    public var title: String
    public var status: JobRunStatus
    public var message: String
    public var startedAt: Date
    public var finishedAt: Date?

    public init(stepID: UUID, title: String, status: JobRunStatus = .running, message: String = "", startedAt: Date = Date(), finishedAt: Date? = nil) {
        self.stepID = stepID
        self.title = title
        self.status = status
        self.message = message
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

/// One run of a job, kept in the job's history with its log.
public struct JobRun: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var jobID: UUID
    public var jobName: String
    public var trigger: JobTrigger
    public var status: JobRunStatus
    public var startedAt: Date
    public var finishedAt: Date?
    public var steps: [JobStepResult]
    public var log: String

    public init(id: UUID = UUID(), jobID: UUID, jobName: String, trigger: JobTrigger, status: JobRunStatus = .running,
                startedAt: Date = Date(), finishedAt: Date? = nil, steps: [JobStepResult] = [], log: String = "") {
        self.id = id
        self.jobID = jobID
        self.jobName = jobName
        self.trigger = trigger
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.steps = steps
        self.log = log
    }

    public var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }

    /// "3 of 3 steps succeeded", for notifications.
    public var summary: String {
        let ok = steps.filter { $0.status == .succeeded }.count
        let failed = steps.first { $0.status == .failed }
        var text = "\(ok) of \(steps.count) step\(steps.count == 1 ? "" : "s") succeeded"
        if let failed { text += ". \(failed.title): \(failed.message)" }
        return text
    }
}

/// Jobs in `automation/jobs.json`; each run in its own `automation/runs/<run id>.json`, so the app and a
/// headless run started by launchd never write the same file.
public struct JobStore: Sendable {
    public let directory: URL
    /// Runs kept per job.
    public var historyLimit = 50

    public init(directory: URL) {
        self.directory = directory
    }

    private var jobsStore: JSONListStore<BatchJob> { JSONListStore(fileURL: directory.appending(path: "jobs.json")) }
    public var runsDirectory: URL { directory.appending(path: "runs", directoryHint: .isDirectory) }
    public var logsDirectory: URL { directory.appending(path: "logs", directoryHint: .isDirectory) }

    public func loadJobs() throws -> [BatchJob] { try jobsStore.load() }
    public func saveJobs(_ jobs: [BatchJob]) throws { try jobsStore.save(jobs) }

    public func save(_ run: JobRun) throws {
        try FileManager.default.createDirectory(at: runsDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(run).write(to: runsDirectory.appending(path: "\(run.id.uuidString).json"), options: .atomic)
    }

    /// Runs, newest first; only one job's with `jobID`.
    public func loadRuns(jobID: UUID? = nil) -> [JobRun] {
        let files = (try? FileManager.default.contentsOfDirectory(at: runsDirectory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let runs = files.filter { $0.pathExtension == "json" }.compactMap { url -> JobRun? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(JobRun.self, from: data)
        }
        return runs.filter { jobID == nil || $0.jobID == jobID }.sorted { $0.startedAt > $1.startedAt }
    }

    /// Drops a job's oldest runs beyond `historyLimit`.
    public func pruneRuns(jobID: UUID) {
        for run in loadRuns(jobID: jobID).dropFirst(historyLimit) { deleteRun(run.id) }
    }

    public func deleteRun(_ id: UUID) {
        try? FileManager.default.removeItem(at: runsDirectory.appending(path: "\(id.uuidString).json"))
    }

    public func deleteRuns(jobID: UUID) {
        for run in loadRuns(jobID: jobID) { deleteRun(run.id) }
    }
}
