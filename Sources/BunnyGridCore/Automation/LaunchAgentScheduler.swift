import Foundation

/// Loads and unloads launch agents. The real one calls `launchctl`; tests record the calls instead.
public protocol LaunchControl: Sendable {
    func bootstrap(plist: URL, label: String) throws
    func bootout(label: String)
}

/// `launchctl bootstrap gui/<uid> <plist>` / `launchctl bootout gui/<uid>/<label>`.
public struct SystemLaunchControl: LaunchControl {
    public init() {}

    public enum LaunchError: LocalizedError {
        case failed(String)
        public var errorDescription: String? {
            switch self { case .failed(let message): "launchctl could not load the job: \(message)" }
        }
    }

    private var domain: String { "gui/\(getuid())" }

    public func bootstrap(plist: URL, label: String) throws {
        let (status, output) = Self.launchctl(["bootstrap", domain, plist.path])
        if status != 0 { throw LaunchError.failed(output.isEmpty ? "exit status \(status)" : output) }
    }

    public func bootout(label: String) {
        _ = Self.launchctl(["bootout", "\(domain)/\(label)"])
    }

    @discardableResult
    static func launchctl(_ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        process.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Schedules jobs as per-user launch agents, so they run while BunnyGrid is closed.
///
/// `SMAppService.agent(plistName:)` only registers plists shipped inside the signed bundle
/// (`Contents/Library/LaunchAgents`), which are fixed at build time; a schedule per job needs its own
/// `StartCalendarInterval`, so each scheduled job gets `~/Library/LaunchAgents/app.bunnygrid.job.<id>.plist`,
/// written only when the user saves a schedule and removed when the schedule is turned off or the job is deleted.
/// The agent starts `BunnyGrid --run-job <id> --scheduled`. A run missed while the Mac slept starts on wake (launchd's rule).
public struct LaunchAgentScheduler: Sendable {
    public static let labelPrefix = "app.bunnygrid.job."

    public static func label(for jobID: UUID) -> String { labelPrefix + jobID.uuidString.lowercased() }

    /// Where plists go (`~/Library/LaunchAgents`; a scratch folder in tests).
    public let directory: URL
    /// The BunnyGrid executable launchd starts.
    public let executablePath: String
    /// `BUNNYGRID_DATA_DIR` for the headless run, when the app itself runs with one.
    public let dataDirectory: String?
    /// launchd's stdout/stderr of each run.
    public let logDirectory: URL
    public let control: any LaunchControl

    public init(directory: URL = Self.userLaunchAgentsDirectory, executablePath: String, dataDirectory: String? = nil,
                logDirectory: URL, control: any LaunchControl = SystemLaunchControl()) {
        self.directory = directory
        self.executablePath = executablePath
        self.dataDirectory = dataDirectory
        self.logDirectory = logDirectory
        self.control = control
    }

    public static var userLaunchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
    }

    public func plistURL(for jobID: UUID) -> URL {
        directory.appending(path: Self.label(for: jobID) + ".plist")
    }

    /// The launch agent's property list.
    public func propertyList(for job: BatchJob) throws -> [String: Any] {
        var plist: [String: Any] = [
            "Label": job.launchdLabel,
            "ProgramArguments": [executablePath, "--run-job", job.id.uuidString, "--scheduled"],
            "StartCalendarInterval": try job.schedule.launchdCalendarIntervals(),
            "RunAtLoad": false,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "StandardOutPath": logDirectory.appending(path: "launchd-\(job.id.uuidString).log").path,
            "StandardErrorPath": logDirectory.appending(path: "launchd-\(job.id.uuidString).log").path,
        ]
        if let dataDirectory { plist["EnvironmentVariables"] = ["BUNNYGRID_DATA_DIR": dataDirectory] }
        return plist
    }

    public func plistData(for job: BatchJob) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: try propertyList(for: job), format: .xml, options: 0)
    }

    /// Installs or removes the job's agent to match its schedule. Returns whether an agent is installed.
    @discardableResult
    public func sync(_ job: BatchJob) throws -> Bool {
        guard job.runsOnSchedule else {
            remove(jobID: job.id)
            return false
        }
        let data = try plistData(for: job)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let url = plistURL(for: job.id)
        control.bootout(label: job.launchdLabel)
        try data.write(to: url, options: .atomic)
        try control.bootstrap(plist: url, label: job.launchdLabel)
        return true
    }

    public func remove(jobID: UUID) {
        let url = plistURL(for: jobID)
        control.bootout(label: Self.label(for: jobID))
        try? FileManager.default.removeItem(at: url)
    }

    public func isInstalled(_ jobID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: plistURL(for: jobID).path)
    }

    /// Jobs with a plist in the directory.
    public func installedJobIDs() -> [UUID] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.compactMap { name in
            guard name.hasPrefix(Self.labelPrefix), name.hasSuffix(".plist") else { return nil }
            return UUID(uuidString: String(name.dropFirst(Self.labelPrefix.count).dropLast(".plist".count)))
        }
    }
}
