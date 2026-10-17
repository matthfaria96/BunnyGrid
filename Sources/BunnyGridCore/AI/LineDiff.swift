import Foundation

/// Line-level diff (longest common subsequence), used to highlight what an AI suggestion changed.
public enum LineDiff {
    public enum Kind: Hashable, Sendable {
        case same
        case added
        case removed
    }

    public struct Line: Hashable, Sendable {
        public var kind: Kind
        public var text: String
    }

    public static func diff(old: String, new: String) -> [Line] {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        // Queries are small; past this size the table would be large, so fall back to remove-all/add-all.
        guard a.count * b.count <= 4_000_000 else {
            return a.map { Line(kind: .removed, text: $0) } + b.map { Line(kind: .added, text: $0) }
        }
        let normalizedA = a.map(normalize), normalizedB = b.map(normalize)
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = normalizedA[i] == normalizedB[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [Line] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if normalizedA[i] == normalizedB[j] {
                result.append(Line(kind: .same, text: b[j]))
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                result.append(Line(kind: .removed, text: a[i]))
                i += 1
            } else {
                result.append(Line(kind: .added, text: b[j]))
                j += 1
            }
        }
        result += a[i...].map { Line(kind: .removed, text: $0) }
        result += b[j...].map { Line(kind: .added, text: $0) }
        return result
    }

    /// Trailing whitespace differences don't count as changes.
    private static func normalize(_ line: String) -> String {
        var line = line
        while let last = line.last, last == " " || last == "\t" { line.removeLast() }
        return line
    }

    public static func hasChanges(_ lines: [Line]) -> Bool {
        lines.contains { $0.kind != .same }
    }
}
