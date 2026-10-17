import AppKit
import BunnyGridCore
import Foundation
import Observation
import UserNotifications

/// Database a Backup wizard or the Backups list works on.
struct BackupTarget: Identifiable {
    let id = UUID()
    let context: DatabaseContext
    let schema: String?
    var objects: [DatabaseObject] = []
}

/// Backup chosen for the Restore sheet.
struct RestoreTarget: Identifiable {
    let id = UUID()
    let entry: BackupEntry
    let context: DatabaseContext
}

/// Batch jobs, their history and launch agents, and backups (state for the Automation window and Backup sheets).
@MainActor
@Observable
final class AutomationCenter {
    private(set) var jobs: [BatchJob] = []
    private(set) var runs: [JobRun] = []
    /// Runs started from the app, by job.
    private(set) var running: [UUID: Task<Void, Never>] = [:]
    var backupTarget: BackupTarget?
    var restoreTarget: RestoreTarget?
    /// Backup selected in the Objects tab's Backups list.
    var selectedBackupID: UUID?
    var errorMessage: String?
    /// Bumped when backups change, so the Backups list reloads.
    private(set) var backupRevision = 0

    @ObservationIgnored let dataDirectory: URL
    @ObservationIgnored let jobStore: JobStore
    @ObservationIgnored let backupStore: BackupStore
    @ObservationIgnored let scheduler: LaunchAgentScheduler
    @ObservationIgnored private var refreshTimer: Timer?

    init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
        jobStore = JobStore(directory: dataDirectory.appending(path: "automation", directoryHint: .isDirectory))
        backupStore = BackupStore(directory: dataDirectory.appending(path: "backups", directoryHint: .isDirectory))
        let env = ProcessInfo.processInfo.environment
        // BUNNYGRID_LAUNCH_AGENTS_DIR keeps development runs out of ~/Library/LaunchAgents.
        let agents = env["BUNNYGRID_LAUNCH_AGENTS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? LaunchAgentScheduler.userLaunchAgentsDirectory
        scheduler = LaunchAgentScheduler(directory: agents,
                                         executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0],
                                         dataDirectory: env["BUNNYGRID_DATA_DIR"],
                                         logDirectory: jobStore.logsDirectory,
                                         control: env["BUNNYGRID_LAUNCH_AGENTS_DIR"] != nil ? NoLaunchControl() : SystemLaunchControl())
        jobs = (try? jobStore.loadJobs()) ?? []
        reloadRuns()
    }

    /// Picks up runs written by scheduled (headless) runs while the window shows.
    func startWatching() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadRuns() }
        }
    }

    func stopWatching() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func reloadRuns() {
        let loaded = jobStore.loadRuns()
        if loaded != runs { runs = loaded }
    }

    func runs(for jobID: UUID) -> [JobRun] { runs.filter { $0.jobID == jobID } }

    func isScheduleInstalled(_ job: BatchJob) -> Bool { scheduler.isInstalled(job.id) }

    // MARK: - Jobs

    func newJob() -> BatchJob {
        var name = "New Batch Job"
        var n = 2
        while jobs.contains(where: { $0.name == name }) { name = "New Batch Job \(n)"; n += 1 }
        let job = BatchJob(name: name)
        jobs.append(job)
        persist()
        return job
    }

    /// Saves a job and installs or removes its launch agent to match the schedule.
    func save(_ job: BatchJob) {
        var job = job
        job.updatedAt = Date()
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.append(job) }
        persist()
        do {
            if job.runsOnSchedule || scheduler.isInstalled(job.id) { try scheduler.sync(job) }
        } catch {
            errorMessage = "The schedule could not be installed: \(error.localizedDescription)"
        }
        if job.runsOnSchedule { requestNotificationPermission() }
    }

    func delete(_ jobID: UUID) {
        running[jobID]?.cancel()
        scheduler.remove(jobID: jobID)
        jobs.removeAll { $0.id == jobID }
        jobStore.deleteRuns(jobID: jobID)
        persist()
        reloadRuns()
    }

    func deleteRun(_ id: UUID) {
        jobStore.deleteRun(id)
        reloadRuns()
    }

    private func persist() {
        do { try jobStore.saveJobs(jobs) } catch { errorMessage = "Could not save jobs: \(error.localizedDescription)" }
    }

    /// Runs a job now, in the app, with the same runner launchd uses.
    func run(_ job: BatchJob, app: AppModel) {
        guard running[job.id] == nil else { return }
        let environment = JobEnvironment(connections: app.connections, savedQueries: app.savedQueries, backupStore: backupStore,
                                         secrets: { KeychainStore().secrets(for: $0) })
        let store = jobStore
        requestNotificationPermission()
        running[job.id] = Task {
            let runner = JobRunner(environment: environment, job: job, trigger: .manual) { run in
                try? store.save(run)
                await MainActor.run { [weak self] in self?.reloadRuns() }
            }
            let run = await runner.start()
            try? store.save(run)
            store.pruneRuns(jobID: job.id)
            running[job.id] = nil
            reloadRuns()
            backupRevision += 1
            Self.notify(run, job: job)
        }
    }

    func cancel(_ jobID: UUID) { running[jobID]?.cancel() }

    // MARK: - Notifications

    /// UI scenarios (scripts/ui-test.sh sets BUNNYGRID_UI_RUN) never ask for or post notifications.
    nonisolated static var notificationsDisabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["BUNNYGRID_UI_RUN"] != nil
        #else
        false
        #endif
    }

    func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil, !Self.notificationsDisabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts "Job finished/failed". Needs a bundled app (UserNotifications refuses bare executables).
    nonisolated static func notify(_ run: JobRun, job: BatchJob, completion: (@Sendable () -> Void)? = nil) {
        let wanted = run.status == .succeeded ? job.notifyOnSuccess : job.notifyOnFailure
        guard wanted, Bundle.main.bundleIdentifier != nil, run.status != .skipped, !notificationsDisabled else { completion?(); return }
        let content = UNMutableNotificationContent()
        content.title = "\(job.name) \(run.status == .succeeded ? "finished" : run.status.displayName.lowercased())"
        content.body = run.summary
        if run.status != .succeeded { content.sound = .default }
        let request = UNNotificationRequest(identifier: run.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in completion?() }
    }

    // MARK: - Backups

    func backups(for target: BackupTarget) -> [BackupEntry] {
        guard let id = target.context.session?.id else { return [] }
        return backupStore.list(connectionID: id, database: target.context.name, schema: target.context.usesSchemas ? target.schema : nil)
    }

    func backupsChanged() { backupRevision += 1 }
}

/// For BUNNYGRID_LAUNCH_AGENTS_DIR: plists are written there but never loaded into launchd.
struct NoLaunchControl: LaunchControl {
    func bootstrap(plist: URL, label: String) throws {}
    func bootout(label: String) {}
}

/// `BunnyGrid --run-job <id> [--scheduled]`: runs the job without UI and exits (launchd starts it this way).
@MainActor
enum HeadlessEntry {
    static func runIfRequested() {
        guard let request = HeadlessJobRunner.jobRequest(in: CommandLine.arguments) else { return }
        guard let id = request.id else {
            FileHandle.standardError.write(Data("usage: BunnyGrid --run-job <job id> [--scheduled]\n".utf8))
            exit(64)
        }
        let runner = HeadlessJobRunner(dataDirectory: AppModel.dataDirectory)
        Task {
            let outcome = await runner.run(jobID: id, scheduled: request.scheduled)
            if case .finished(let run) = outcome, let job = try? runner.jobStore.loadJobs().first(where: { $0.id == id }) {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    AutomationCenter.notify(run, job: job) { done.resume() }
                }
            }
            exit(outcome.exitCode)
        }
        dispatchMain()
    }
}


/// The Automation workspace tab. Its state (jobs, runs) lives in `AutomationCenter`; the tab only needs an identity.
@MainActor @Observable
final class AutomationTabModel {
    nonisolated let id = UUID()
}

extension AppModel {
    /// Shows the Automation tab, opening it the first time (⇧⌘J, the toolbar button, Tools › Automation).
    func openAutomation() {
        guard Feature.automation.isAvailable else { return }
        if let existing = tabs.first(where: { if case .automation = $0 { true } else { false } }) {
            selectedTabID = existing.id
        } else {
            appendTab(.automation(AutomationTabModel()))
        }
    }
}
