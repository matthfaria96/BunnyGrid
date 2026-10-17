import Foundation

/// `BunnyGrid --run-job <id> [--scheduled]`: runs a saved job without any UI, from the data directory's
/// connections, saved queries and jobs, with secrets from the Keychain. Writes the run (with its log) to
/// `automation/runs/` and a plain-text copy of the log to `automation/logs/`.
public struct HeadlessJobRunner: Sendable {
    public let dataDirectory: URL
    public var secrets: @Sendable (UUID) -> ConnectionSecrets
    /// Lines for stdout (launchd sends them to the agent's log file).
    public var output: @Sendable (String) -> Void
    public var now: @Sendable () -> Date

    public init(dataDirectory: URL,
                secrets: @escaping @Sendable (UUID) -> ConnectionSecrets = { KeychainStore().secrets(for: $0) },
                output: @escaping @Sendable (String) -> Void = { print($0) },
                now: @escaping @Sendable () -> Date = Date.init) {
        self.dataDirectory = dataDirectory
        self.secrets = secrets
        self.output = output
        self.now = now
    }

    public var jobStore: JobStore { JobStore(directory: dataDirectory.appending(path: "automation", directoryHint: .isDirectory)) }
    public var backupStore: BackupStore { BackupStore(directory: dataDirectory.appending(path: "backups", directoryHint: .isDirectory)) }

    public enum Outcome: Equatable, Sendable {
        case finished(JobRun)
        /// A scheduled start that should not run (schedule off, or a once schedule's later years).
        case skipped(String)
        case failed(String)

        public var exitCode: Int32 {
            switch self {
            case .finished(let run): run.status == .succeeded ? 0 : 1
            case .skipped: 0
            case .failed: 2
            }
        }
    }

    /// Parses `--run-job <id> [--scheduled]`; nil when the arguments don't ask for a headless run.
    public static func jobRequest(in arguments: [String]) -> (id: UUID?, scheduled: Bool)? {
        guard let index = arguments.firstIndex(of: "--run-job") else { return nil }
        let id = arguments.indices.contains(index + 1) ? UUID(uuidString: arguments[index + 1]) : nil
        return (id, arguments.contains("--scheduled"))
    }

    public func run(jobID: UUID, scheduled: Bool) async -> Outcome {
        let jobs: [BatchJob]
        do { jobs = try jobStore.loadJobs() } catch { return fail("Could not read jobs: \(error.localizedDescription)") }
        guard let job = jobs.first(where: { $0.id == jobID }) else { return fail("No job with id \(jobID.uuidString).") }
        if scheduled {
            if !job.runsOnSchedule { return skip("“\(job.name)” has no active schedule.") }
            if case .once(let date) = job.schedule, abs(now().timeIntervalSince(date)) > 12 * 3600 {
                return skip("“\(job.name)” was scheduled once, on \(date.formatted()).")
            }
        }
        let connections: [ConnectionConfig]
        do {
            connections = try ConnectionStore(fileURL: dataDirectory.appending(path: "connections.json")).load()
        } catch {
            return fail("Could not read connections: \(error.localizedDescription)")
        }
        let queries = (try? JSONListStore<SavedQuery>(fileURL: dataDirectory.appending(path: "queries.json")).load()) ?? []
        let environment = JobEnvironment(connections: connections, savedQueries: queries, backupStore: backupStore, secrets: secrets)
        let store = jobStore
        let runner = JobRunner(environment: environment, job: job, trigger: scheduled ? .scheduled : .manual) { run in
            // Saved as it goes, so the app shows a running job and a crash still leaves a log.
            try? store.save(run)
        }
        let run = await runner.start()
        try? store.save(run)
        store.pruneRuns(jobID: job.id)
        writeLog(run)
        output(run.log)
        return .finished(run)
    }

    private func writeLog(_ run: JobRun) {
        let folder = jobStore.logsDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(run.log.utf8).write(to: folder.appending(path: "\(run.jobID.uuidString)-\(run.id.uuidString).log"), options: .atomic)
    }

    private func skip(_ message: String) -> Outcome {
        output(message)
        return .skipped(message)
    }

    private func fail(_ message: String) -> Outcome {
        output(message)
        return .failed(message)
    }
}
