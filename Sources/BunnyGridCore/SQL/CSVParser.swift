import Foundation

/// RFC 4180 CSV reader: quoted fields, doubled quotes, embedded delimiters and newlines, CRLF or LF.
public enum CSVParser {
    public static func parse(_ text: String, delimiter: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character? = nil

        func nextChar() -> Character? {
            if let c = pending { pending = nil; return c }
            return iterator.next()
        }

        while let c = nextChar() {
            if inQuotes {
                if c == "\"" {
                    if let following = nextChar() {
                        if following == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = following
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty {
                inQuotes = true
            } else if c == delimiter {
                row.append(field)
                field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    /// Picks the most likely delimiter from the first lines: comma, semicolon, tab or pipe.
    public static func detectDelimiter(_ text: String) -> Character {
        let sample = text.split(separator: "\n", maxSplits: 5, omittingEmptySubsequences: true).prefix(5)
        let candidates: [Character] = [",", ";", "\t", "|"]
        return candidates.max { a, b in
            score(sample, a) < score(sample, b)
        } ?? ","
    }

    private static func score(_ lines: ArraySlice<Substring>, _ delimiter: Character) -> Int {
        let counts = lines.map { $0.filter { $0 == delimiter }.count }
        guard let first = counts.first, first > 0 else { return 0 }
        // Consistent counts across lines matter more than raw frequency.
        return counts.allSatisfy { $0 == first } ? first * 10 : first
    }
}
