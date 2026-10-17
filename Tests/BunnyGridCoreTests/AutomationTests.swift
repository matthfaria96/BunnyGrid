import Foundation
import Testing
@testable import BunnyGridCore

private func scratchDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "bunnygrid-\(name)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func date(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    return formatter.date(from: text)!
}

@Suite struct JobModelTests {
    @Test func jobRoundTripsThroughJSON() throws {
        let connection = UUID()
        let target = JobTarget(connectionID: connection, database: "main")
        let job = BatchJob(name: "Nightly", steps: [
            JobStep(action: .savedQuery(queryID: UUID())),
            JobStep(action: .sql(target: target, sql: "DELETE FROM logs")),
            JobStep(enabled: false, action: .sqlFile(target: target, path: "~/x.sql", options: ScriptRunOptions(stopOnError: false, useTransaction: true))),
            JobStep(action: .backup(target: JobTarget(connectionID: connection, database: "app", schema: "public"),
                                    options: BackupOptions(objects: [BackupObject(schema: "public", name: "users", kind: .table)], comment: "nightly"))),
            JobStep(action: .export(ExportStepSettings(target: target, format: .xlsx, outputDirectory: "/tmp/out"))),
        ], schedule: .weekly(weekdays: [2, 4], hour: 3, minute: 30), continueOnError: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode([job])
        let back = try decoder.decode([BatchJob].self, from: data)
        #expect(back.count == 1)
        #expect(back[0].name == job.name)
        #expect(back[0].steps == job.steps)
        #expect(back[0].schedule == job.schedule)
        #expect(back[0].continueOnError)
        #expect(back[0].launchdLabel == "app.bunnygrid.job." + job.id.uuidString.lowercased())
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"xlsx\""))
        #expect(text.contains("\"weekly\""))
    }

    @Test func everyScheduleKindEncodes() throws {
        let schedules: [JobSchedule] = [.manual, .once(date("2026-12-24T18:00:00Z")), .hourly(minute: 5), .daily(hour: 1, minute: 2),
                                        .weekly(weekdays: [1], hour: 0, minute: 0), .monthly(day: 15, hour: 12, minute: 0), .cron("*/5 * * * *")]
        for schedule in schedules {
            let data = try JSONEncoder().encode(schedule)
            #expect(try JSONDecoder().decode(JobSchedule.self, from: data) == schedule)
        }
    }

    @Test func storeKeepsRunsInSeparateFilesAndPrunes() throws {
        var store = JobStore(directory: try scratchDirectory("jobstore"))
        store.historyLimit = 2
        let job = BatchJob(name: "A")
        try store.saveJobs([job])
        #expect(try store.loadJobs().map(\.id) == [job.id])
        for i in 0..<4 {
            try store.save(JobRun(jobID: job.id, jobName: "A", trigger: .manual, status: .succeeded, startedAt: Date(timeIntervalSince1970: Double(i) * 60)))
        }
        try store.save(JobRun(jobID: UUID(), jobName: "B", trigger: .manual))
        #expect(store.loadRuns(jobID: job.id).count == 4)
        store.pruneRuns(jobID: job.id)
        let kept = store.loadRuns(jobID: job.id)
        #expect(kept.map(\.startedAt) == [Date(timeIntervalSince1970: 180), Date(timeIntervalSince1970: 120)])
        #expect(store.loadRuns().count == 3)
    }
}

@Suite struct JobScheduleTests {
    @Test func dailyHourlyWeeklyMonthlyNextRuns() {
        let start = date("2026-10-17T10:20:00Z") // a Saturday
        #expect(JobSchedule.daily(hour: 3, minute: 0).nextRuns(after: start, count: 2, calendar: utc)
                == [date("2026-10-18T03:00:00Z"), date("2026-10-19T03:00:00Z")])
        #expect(JobSchedule.daily(hour: 10, minute: 30).nextRun(after: start, calendar: utc) == date("2026-10-17T10:30:00Z"))
        #expect(JobSchedule.hourly(minute: 15).nextRuns(after: start, count: 2, calendar: utc)
                == [date("2026-10-17T11:15:00Z"), date("2026-10-17T12:15:00Z")])
        // Monday (2) and Wednesday (4).
        #expect(JobSchedule.weekly(weekdays: [4, 2], hour: 8, minute: 0).nextRuns(after: start, count: 3, calendar: utc)
                == [date("2026-10-19T08:00:00Z"), date("2026-10-21T08:00:00Z"), date("2026-10-26T08:00:00Z")])
        // Day 31 skips November.
        #expect(JobSchedule.monthly(day: 31, hour: 0, minute: 0).nextRuns(after: start, count: 2, calendar: utc)
                == [date("2026-10-31T00:00:00Z"), date("2026-12-31T00:00:00Z")])
        #expect(JobSchedule.manual.nextRun(after: start) == nil)
        #expect(JobSchedule.once(date("2026-10-18T00:00:00Z")).nextRuns(after: start, count: 3) == [date("2026-10-18T00:00:00Z")])
        #expect(JobSchedule.once(date("2026-10-01T00:00:00Z")).nextRun(after: start) == nil)
    }

    @Test func cronNextRuns() throws {
        let start = date("2026-10-16T17:50:00Z") // Friday
        // Every 15 minutes during working hours on weekdays.
        let work = JobSchedule.cron("*/15 9-17 * * 1-5")
        #expect(work.nextRuns(after: start, count: 3, calendar: utc)
                == [date("2026-10-19T09:00:00Z"), date("2026-10-19T09:15:00Z"), date("2026-10-19T09:30:00Z")])
        #expect(work.nextRun(after: date("2026-10-16T17:20:00Z"), calendar: utc) == date("2026-10-16T17:30:00Z"))
        // Both day fields restricted: the 1st of the month or any Sunday (cron's either-day rule).
        let either = JobSchedule.cron("0 0 1 * 0")
        #expect(either.nextRuns(after: start, count: 3, calendar: utc)
                == [date("2026-10-18T00:00:00Z"), date("2026-10-25T00:00:00Z"), date("2026-11-01T00:00:00Z")])
        // 7 is Sunday too; lists and single months.
        #expect(JobSchedule.cron("30 6 * 2 7").nextRun(after: start, calendar: utc) == date("2027-02-07T06:30:00Z"))
        #expect(JobSchedule.cron("0 12 29 2 *").nextRun(after: start, calendar: utc) == date("2028-02-29T12:00:00Z"))
    }

    @Test func cronRejectsBadExpressions() {
        #expect(throws: CronExpression.ParseError.fieldCount(4)) { try CronExpression("* * * *") }
        #expect(throws: CronExpression.ParseError.invalidField("60")) { try CronExpression("60 * * * *") }
        #expect(throws: CronExpression.ParseError.invalidField("*/0")) { try CronExpression("*/0 * * * *") }
        #expect(throws: CronExpression.ParseError.invalidField("5-2")) { try CronExpression("0 5-2 * * *") }
        #expect(JobSchedule.cron("nonsense").nextRun(after: Date()) == nil)
    }

    @Test func launchdCalendarIntervals() throws {
        #expect(try JobSchedule.manual.launchdCalendarIntervals() == [])
        #expect(try JobSchedule.hourly(minute: 7).launchdCalendarIntervals() == [["Minute": 7]])
        #expect(try JobSchedule.daily(hour: 3, minute: 0).launchdCalendarIntervals() == [["Hour": 3, "Minute": 0]])
        // Calendar weekdays 2 and 4 (Monday, Wednesday) become launchd's 1 and 3.
        #expect(try JobSchedule.weekly(weekdays: [4, 2], hour: 8, minute: 30).launchdCalendarIntervals()
                == [["Hour": 8, "Minute": 30, "Weekday": 1], ["Hour": 8, "Minute": 30, "Weekday": 3]])
        #expect(try JobSchedule.monthly(day: 1, hour: 0, minute: 5).launchdCalendarIntervals() == [["Day": 1, "Hour": 0, "Minute": 5]])
        #expect(try JobSchedule.once(date("2026-12-24T18:45:00Z")).launchdCalendarIntervals(calendar: utc)
                == [["Month": 12, "Day": 24, "Hour": 18, "Minute": 45]])
        let quarterHours = try JobSchedule.cron("*/15 9 * * *").launchdCalendarIntervals()
        #expect(quarterHours.count == 4)
        #expect(quarterHours.contains(["Minute": 45, "Hour": 9]))
        // Either-day rule: one set for the day of month, one for the weekday.
        #expect(try JobSchedule.cron("0 0 1 * 0").launchdCalendarIntervals()
                == [["Minute": 0, "Hour": 0, "Day": 1], ["Minute": 0, "Hour": 0, "Weekday": 0]])
        #expect(try JobSchedule.cron("* * * * *").launchdCalendarIntervals() == [[:]])
        #expect(throws: CronExpression.ParseError.tooManyIntervals(1357)) { try CronExpression("0-58 0-22 * * *").launchdCalendarIntervals(limit: 1000) }
    }
}

/// Records launchctl calls instead of running them.
private final class RecordingLaunchControl: LaunchControl, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }

    func bootstrap(plist: URL, label: String) throws { lock.withLock { _calls.append("bootstrap \(label) \(plist.lastPathComponent)") } }
    func bootout(label: String) { lock.withLock { _calls.append("bootout \(label)") } }
}

@Suite struct LaunchAgentTests {
    @Test func writesPlistOnlyForActiveSchedulesAndRemovesIt() throws {
        let root = try scratchDirectory("launchagents")
        let control = RecordingLaunchControl()
        let scheduler = LaunchAgentScheduler(directory: root.appending(path: "LaunchAgents"), executablePath: "/Applications/BunnyGrid.app/Contents/MacOS/BunnyGrid",
                                             dataDirectory: "/tmp/bg-data", logDirectory: root.appending(path: "logs"), control: control)
        var job = BatchJob(name: "Nightly", schedule: .manual)
        #expect(try scheduler.sync(job) == false)
        #expect(!scheduler.isInstalled(job.id))

        job.schedule = .daily(hour: 2, minute: 15)
        #expect(try scheduler.sync(job))
        let url = scheduler.plistURL(for: job.id)
        #expect(url.lastPathComponent == "app.bunnygrid.job.\(job.id.uuidString.lowercased()).plist")
        let plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == job.launchdLabel)
        #expect(plist["ProgramArguments"] as? [String] == ["/Applications/BunnyGrid.app/Contents/MacOS/BunnyGrid", "--run-job", job.id.uuidString, "--scheduled"])
        #expect(plist["StartCalendarInterval"] as? [[String: Int]] == [["Hour": 2, "Minute": 15]])
        #expect((plist["EnvironmentVariables"] as? [String: String])?["BUNNYGRID_DATA_DIR"] == "/tmp/bg-data")
        #expect(plist["RunAtLoad"] as? Bool == false)
        #expect(scheduler.installedJobIDs() == [job.id])
        #expect(control.calls.last == "bootstrap \(job.launchdLabel) \(url.lastPathComponent)")

        job.scheduleEnabled = false
        #expect(try scheduler.sync(job) == false)
        #expect(!scheduler.isInstalled(job.id))
        #expect(control.calls.last == "bootout \(job.launchdLabel)")
        #expect(scheduler.installedJobIDs().isEmpty)
    }

    @Test func commandLineRequest() {
        let id = UUID()
        #expect(HeadlessJobRunner.jobRequest(in: ["BunnyGrid", "--run-job", id.uuidString])?.id == id)
        #expect(HeadlessJobRunner.jobRequest(in: ["BunnyGrid", "--run-job", id.uuidString, "--scheduled"])?.scheduled == true)
        #expect(HeadlessJobRunner.jobRequest(in: ["BunnyGrid", "--run-job"])?.id == nil)
        #expect(HeadlessJobRunner.jobRequest(in: ["BunnyGrid", "demo.sqlite"]) == nil)
    }
}

@Suite struct HeadlessRunnerTests {
    /// A data directory as the app leaves it: a SQLite connection, a saved query and a job with every local step kind.
    private func makeDataDirectory() async throws -> (dir: URL, job: BatchJob, connection: ConnectionConfig, exportDir: URL) {
        let dir = try scratchDirectory("headless")
        let dbPath = dir.appending(path: "shop.sqlite").path
        let seed = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: dbPath))
        try await seed.connect()
        _ = try await seed.execute("""
            CREATE TABLE orders (id INTEGER PRIMARY KEY, total REAL NOT NULL, status TEXT);
            INSERT INTO orders (total, status) VALUES (10.5, 'open'), (20, 'open'), (7, 'closed');
            CREATE TABLE audit (id INTEGER PRIMARY KEY, note TEXT);
            """)
        await seed.disconnect()
        let connection = ConnectionConfig(name: "Shop", kind: .sqlite, filePath: dbPath)
        try ConnectionStore(fileURL: dir.appending(path: "connections.json")).save([connection])
        let query = SavedQuery(connectionID: connection.id, database: "main", name: "Close old", sql: "UPDATE orders SET status = 'closed' WHERE total < 15;")
        try JSONListStore<SavedQuery>(fileURL: dir.appending(path: "queries.json")).save([query])
        let sqlFile = dir.appending(path: "audit.sql")
        try "INSERT INTO audit (note) VALUES ('from file');\nINSERT INTO audit (note) VALUES ('again');".write(to: sqlFile, atomically: true, encoding: .utf8)
        let exportDir = dir.appending(path: "exports")
        let target = JobTarget(connectionID: connection.id, database: "main")
        let job = BatchJob(name: "Nightly", steps: [
            JobStep(action: .savedQuery(queryID: query.id)),
            JobStep(action: .sql(target: target, sql: "INSERT INTO audit (note) VALUES ('inline')")),
            JobStep(action: .sqlFile(target: target, path: sqlFile.path, options: ScriptRunOptions())),
            JobStep(action: .backup(target: target, options: BackupOptions(comment: "nightly"))),
            JobStep(action: .export(ExportStepSettings(target: target, objects: [BackupObject(schema: nil, name: "orders", kind: .table)],
                                                       format: .csv, outputDirectory: exportDir.path, timestampedFolder: false))),
        ], schedule: .daily(hour: 3, minute: 0))
        try JobStore(directory: dir.appending(path: "automation")).saveJobs([job])
        return (dir, job, connection, exportDir)
    }

    @Test func runsAJobAgainstASQLiteDatabase() async throws {
        let (dir, job, connection, exportDir) = try await makeDataDirectory()
        let runner = HeadlessJobRunner(dataDirectory: dir, secrets: { _ in ConnectionSecrets() }, output: { _ in })
        let outcome = await runner.run(jobID: job.id, scheduled: true)
        guard case .finished(let run) = outcome else { Issue.record("expected a run, got \(outcome)"); return }
        #expect(run.status == .succeeded, "\(run.log)")
        #expect(run.trigger == .scheduled)
        #expect(run.steps.map(\.status) == Array(repeating: .succeeded, count: 5))
        #expect(outcome.exitCode == 0)

        let check = SQLiteDriver(config: connection)
        try await check.connect()
        #expect(try await check.countRows(table: "audit", schema: nil) == 3)
        #expect(try await check.execute("SELECT COUNT(*) FROM orders WHERE status = 'closed'").first?.rows == [[.integer(2)]])
        await check.disconnect()

        let backups = runner.backupStore.list(connectionID: connection.id, database: "main", schema: nil)
        #expect(backups.count == 1)
        #expect(backups.first?.manifest.comment == "nightly")
        let csv = try String(contentsOf: exportDir.appending(path: "orders.csv"), encoding: .utf8)
        #expect(csv.hasPrefix("id,total,status"))
        let saved = runner.jobStore.loadRuns(jobID: job.id)
        #expect(saved.map(\.id) == [run.id])
        #expect(saved.first?.status == .succeeded)
        #expect(saved.first?.log.contains("Backup") == true)
        let logs = try FileManager.default.contentsOfDirectory(atPath: runner.jobStore.logsDirectory.path)
        #expect(logs == ["\(job.id.uuidString)-\(run.id.uuidString).log"])
    }

    @Test func stopsAtAFailingStepUnlessToldToContinue() async throws {
        let (dir, job, _, _) = try await makeDataDirectory()
        let store = JobStore(directory: dir.appending(path: "automation"))
        var failing = job
        failing.steps.insert(JobStep(action: .sql(target: job.steps[1].action.target!, sql: "INSERT INTO nowhere VALUES (1)")), at: 0)
        try store.saveJobs([failing])
        let runner = HeadlessJobRunner(dataDirectory: dir, secrets: { _ in ConnectionSecrets() }, output: { _ in })
        guard case .finished(let run) = await runner.run(jobID: job.id, scheduled: false) else { Issue.record("no run"); return }
        #expect(run.status == .failed)
        #expect(run.steps.first?.status == .failed)
        #expect(run.steps.dropFirst().allSatisfy { $0.status == .skipped })

        failing.continueOnError = true
        try store.saveJobs([failing])
        guard case .finished(let second) = await runner.run(jobID: job.id, scheduled: false) else { Issue.record("no run"); return }
        #expect(second.status == .failed)
        #expect(second.steps.dropFirst().allSatisfy { $0.status == .succeeded })
        #expect(second.summary.hasPrefix("5 of 6 steps succeeded"))
    }

    @Test func dataTransferStepCopiesIntoAnotherDatabase() async throws {
        let (dir, _, connection, _) = try await makeDataDirectory()
        let copyPath = dir.appending(path: "copy.sqlite").path
        let copy = ConnectionConfig(name: "Copy", kind: .sqlite, filePath: copyPath)
        try ConnectionStore(fileURL: dir.appending(path: "connections.json")).save([connection, copy])
        let job = BatchJob(name: "Transfer", steps: [JobStep(action: .dataTransfer(DataTransferStepSettings(
            source: JobTarget(connectionID: connection.id, database: "main"), destination: JobTarget(connectionID: copy.id, database: "main"),
            tables: ["orders"])))])
        let encoded = try JSONEncoder().encode(job)
        #expect(try JSONDecoder().decode(BatchJob.self, from: encoded) == job)
        try JobStore(directory: dir.appending(path: "automation")).saveJobs([job])
        let runner = HeadlessJobRunner(dataDirectory: dir, secrets: { _ in ConnectionSecrets() }, output: { _ in })
        guard case .finished(let run) = await runner.run(jobID: job.id, scheduled: false) else { Issue.record("no run"); return }
        #expect(run.status == .succeeded, "\(run.log)")
        let check = SQLiteDriver(config: copy)
        try await check.connect()
        #expect(try await check.countRows(table: "orders", schema: nil) == 3)
        await check.disconnect()
    }

    @Test func scheduledStartsOfInactiveJobsAreSkipped() async throws {
        let (dir, job, _, _) = try await makeDataDirectory()
        var off = job
        off.scheduleEnabled = false
        try JobStore(directory: dir.appending(path: "automation")).saveJobs([off])
        let runner = HeadlessJobRunner(dataDirectory: dir, secrets: { _ in ConnectionSecrets() }, output: { _ in })
        guard case .skipped = await runner.run(jobID: job.id, scheduled: true) else { Issue.record("expected skip"); return }
        #expect(runner.jobStore.loadRuns().isEmpty)
        guard case .failed = await runner.run(jobID: UUID(), scheduled: false) else { Issue.record("expected failure"); return }
    }
}
