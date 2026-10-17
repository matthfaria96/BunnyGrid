import Foundation

/// Whether a connection has an open transaction, followed from the statements it runs. A driver that lost its
/// connection inside a transaction must not reconnect silently: the server rolled the transaction back, and the
/// statements after it would autocommit one by one on the new connection.
public enum TransactionState {
    private static let beginSecondWords: Set<String> = ["TRAN", "TRANSACTION", "WORK", "DEFERRED", "IMMEDIATE", "EXCLUSIVE", "ISOLATION", "READ"]

    /// The state after running `sql` on a connection whose transaction was `wasOpen`.
    public static func after(_ sql: String, wasOpen: Bool) -> Bool {
        let words = sql.split(whereSeparator: { $0.isWhitespace || $0 == ";" }).prefix(3).map { $0.uppercased() }
        guard let first = words.first else { return wasOpen }
        let second = words.dropFirst().first
        switch first {
        case "BEGIN":
            // SQL Server's BEGIN TRY / BEGIN … END blocks aren't transactions; BEGIN, BEGIN TRAN[SACTION], BEGIN WORK are.
            guard let second else { return true }
            return beginSecondWords.contains(second) ? true : wasOpen
        case "START":
            return second == "TRANSACTION" ? true : wasOpen
        case "COMMIT", "END", "ABORT":
            return false
        case "ROLLBACK":
            // ROLLBACK TO [SAVEPOINT] x keeps the transaction open.
            return words.dropFirst().contains("TO") ? wasOpen : false
        default:
            return wasOpen
        }
    }
}
