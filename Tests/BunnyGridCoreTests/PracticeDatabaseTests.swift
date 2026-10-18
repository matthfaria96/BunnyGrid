import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct PracticeDatabaseTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "practice-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Every template builds, its tables exist with rows, and every example query runs.
    @Test(arguments: PracticeDatabase.templates)
    func templateBuildsAndExamplesRun(_ template: PracticeTemplate) async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = PracticeDatabase.availableURL(named: "bunnygrid", in: directory)
        try PracticeDatabase.create(template, at: url)
        let driver = SQLiteDriver(config: ConnectionConfig(kind: .sqlite, filePath: url.path))
        try await driver.connect()
        let objects = try await driver.listObjects(schema: nil).filter { $0.kind == .table }.map(\.name)
        #expect(Set(objects) == Set(template.tables))
        for table in template.tables {
            let count = try await driver.executeStatement("SELECT count(*) FROM \(table)").rows.first?.first
            if case .integer(let n) = count { #expect(n > 0, "\(table) is empty") } else { Issue.record("no count for \(table)") }
        }
        let violations = try await driver.executeStatement("PRAGMA foreign_key_check").rows
        #expect(violations.isEmpty, "foreign keys broken in \(template.id)")
        #expect(!template.examples.isEmpty)
        for example in template.examples {
            for statement in SQLSplitter.split(example.sql) {
                _ = try await driver.executeStatement(statement)
            }
        }
    }

    @Test func namesAreUniqueAndSafe() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = PracticeDatabase.availableURL(named: "bunnygrid", in: directory)
        #expect(first.lastPathComponent == "bunnygrid.sqlite")
        try PracticeDatabase.create(PracticeDatabase.template(id: "notes")!, at: first)
        #expect(PracticeDatabase.availableURL(named: "bunnygrid", in: directory).lastPathComponent == "bunnygrid 2.sqlite")
        #expect(PracticeDatabase.sanitized("  a/b:c  ") == "a-b-c")
        #expect(PracticeDatabase.sanitized("...") == "bunnygrid")
    }

    @Test func refusesToOverwriteAndCleansUpOnFailure() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "x.sqlite")
        try PracticeDatabase.create(PracticeDatabase.template(id: "store")!, at: url)
        #expect(throws: PracticeDatabase.CreateError.self) { try PracticeDatabase.create(PracticeDatabase.template(id: "store")!, at: url) }
        let broken = PracticeTemplate(id: "broken", name: "Broken", summary: "", symbol: "", tint: 0, tables: [], script: "CREATE TABLE t (; ", examples: [])
        let other = directory.appending(path: "broken.sqlite")
        #expect(throws: PracticeDatabase.CreateError.self) { try PracticeDatabase.create(broken, at: other) }
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }
}
