import Foundation

/// Options for running a .sql file (Navicat's "Execute SQL File").
public struct ScriptRunOptions: Sendable, Equatable {
    /// Stop at the first failing statement; otherwise log it and go on.
    public var stopOnError: Bool
    /// Wrap the whole script in one transaction, rolled back if it stops on an error.
    public var useTransaction: Bool

    public init(stopOnError: Bool = true, useTransaction: Bool = false) {
        self.stopOnError = stopOnError
        self.useTransaction = useTransaction
    }
}

public struct ScriptStatementError: Sendable, Equatable, Identifiable {
    public var id: Int { index }
    /// Zero-based position of the statement in the script.
    public var index: Int
    public var statement: String
    public var message: String
}

/// Progress and outcome of a script run.
public struct ScriptRunReport: Sendable, Equatable {
    public var total: Int
    public var executed = 0
    public var succeeded = 0
    public var affectedRows = 0
    public var errors: [ScriptStatementError] = []
    /// True when the run ended early (an error with stopOnError, or cancellation).
    public var stopped = false
    public var rolledBack = false

    public init(total: Int) {
        self.total = total
    }

    public var fractionDone: Double { total == 0 ? 1 : Double(executed) / Double(total) }
}

extension DatabaseDriver {
    /// Runs the statements of a script one by one, reporting progress at most every `progressInterval`
    /// (and once at the end). Errors never throw: they are collected in the report; cancellation stops the run.
    public func runScript(_ statements: [String], options: ScriptRunOptions = ScriptRunOptions(),
                          progressInterval: Duration = .milliseconds(100),
                          progress: @Sendable (ScriptRunReport) async -> Void = { _ in }) async -> ScriptRunReport {
        var report = ScriptRunReport(total: statements.count)
        if config.readOnly, let first = statements.enumerated().first(where: { !Self.isReadOnlyStatement($0.element) }) {
            report.errors.append(ScriptStatementError(index: first.offset, statement: first.element,
                                                      message: DatabaseError.readOnly.localizedDescription))
            report.stopped = true
            await progress(report)
            return report
        }
        if options.useTransaction {
            do {
                _ = try await executeStatement(dialect.beginTransaction)
            } catch {
                report.errors.append(ScriptStatementError(index: 0, statement: dialect.beginTransaction, message: error.localizedDescription))
                report.stopped = true
                return report
            }
        }
        let clock = ContinuousClock()
        var lastReport = clock.now
        for (index, statement) in statements.enumerated() {
            if Task.isCancelled { report.stopped = true; break }
            do {
                let result = try await executeStatement(statement)
                report.succeeded += 1
                report.affectedRows += result.affectedRows ?? 0
            } catch {
                report.errors.append(ScriptStatementError(index: index, statement: statement, message: error.localizedDescription))
                if options.stopOnError {
                    report.executed += 1
                    report.stopped = true
                    break
                }
            }
            report.executed += 1
            if clock.now - lastReport >= progressInterval {
                lastReport = clock.now
                await progress(report)
            }
        }
        if options.useTransaction {
            if report.stopped {
                _ = try? await executeStatement("ROLLBACK")
                report.rolledBack = true
            } else {
                do {
                    _ = try await executeStatement("COMMIT")
                } catch {
                    report.errors.append(ScriptStatementError(index: statements.count, statement: "COMMIT", message: error.localizedDescription))
                    _ = try? await executeStatement("ROLLBACK")
                    report.rolledBack = true
                }
            }
        }
        await progress(report)
        return report
    }
}
