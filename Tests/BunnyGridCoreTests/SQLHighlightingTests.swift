import Foundation
import Testing
@testable import BunnyGridCore

@Suite("SQL highlighting")
struct SQLHighlightingTests {
    /// One kind (or nil) per UTF-16 unit, so tokens split differently across lines still compare equal.
    private func kinds(_ tokens: [SQLToken], length: Int) -> [SQLTokenKind?] {
        var map = [SQLTokenKind?](repeating: nil, count: length)
        for token in tokens { for i in token.location..<(token.location + token.length) { map[i] = token.kind } }
        return map
    }

    private func spans(_ sql: String) -> [(String, SQLTokenKind)] {
        let text = sql as NSString
        return SQLLexer.tokenize(text).map { (text.substring(with: $0.range), $0.kind) }
    }

    @Test func classifiesTokens() {
        let result = spans("SELECT id, 'it''s' FROM t1 WHERE x = 1.5 -- note\n/* a\nb */ select")
        #expect(result.map(\.0) == ["SELECT", "'it''s'", "FROM", "WHERE", "1.5", "-- note", "/* a\n", "b */", "select"])
        #expect(result.map(\.1) == [.keyword, .string, .keyword, .keyword, .number, .comment, .comment, .comment, .keyword])
    }

    @Test func wordBoundaries() {
        // Identifiers containing digits or keywords are not coloured; quoted identifiers are plain.
        let result = spans("table_0001 x1 123abc selected \"select\" `from` 42")
        #expect(result.map(\.0) == ["42"])
    }

    @Test func commentsInsideStringsStayStrings() {
        let result = spans("'a -- b' /* 'c' */")
        #expect(result.map(\.1) == [.string, .comment])
    }

    @Test func lineTableMatchesReset() {
        let text = "a\nb\n\nc" as NSString
        let highlighter = SQLIncrementalHighlighter()
        highlighter.reset(text)
        #expect(highlighter.lineStarts == [0, 2, 4, 5])
        #expect(highlighter.line(containing: 3) == 1)
        #expect(highlighter.line(containing: 99) == 3)
    }

    /// The incremental highlighter must colour exactly like a full re-tokenize after any edit.
    @Test func incrementalMatchesFullOnRandomEdits() {
        var rng = SplitMix(seed: 7)
        let pieces = ["SELECT ", "from ", "'", "''", "\"", "`", "--", "/*", "*/", "\n", "\n", " ", "42", "1.5", "x", "é", "where", ";", "\r\n"]
        let storage = NSMutableString(string: "SELECT 1;\n-- hi\n/* x */ 'a'\n")
        let highlighter = SQLIncrementalHighlighter()
        highlighter.reset(storage)
        for step in 0..<3_000 {
            let length = storage.length
            let location = Int(rng.next() % UInt64(length + 1))
            let removeLength = rng.next() % 3 == 0 ? Int(rng.next() % UInt64(min(length - location, 12) + 1)) : 0
            var insertion = ""
            for _ in 0..<Int(rng.next() % 4) { insertion += pieces[Int(rng.next() % UInt64(pieces.count))] }
            // Don't split a surrogate pair or \r\n meaningfully: plain replace like NSTextStorage does.
            storage.replaceCharacters(in: NSRange(location: location, length: removeLength), with: insertion)
            let inserted = (insertion as NSString).length
            highlighter.edit(storage, editedRange: NSRange(location: location, length: inserted), changeInLength: inserted - removeLength)

            let reference = SQLIncrementalHighlighter()
            reference.reset(storage)
            #expect(highlighter.lineStarts == reference.lineStarts, "line starts after step \(step)")
            let full = kinds(SQLLexer.tokenize(storage), length: storage.length)
            let incremental = kinds(highlighter.tokens(in: NSRange(location: 0, length: storage.length), of: storage), length: storage.length)
            #expect(incremental == full, "colours after step \(step): \(storage)")
            if incremental != full { break }
        }
    }

    @Test func editReportsOnlyTheEditedLineForAWord() {
        let text = NSMutableString(string: (0..<100).map { "SELECT \($0);" }.joined(separator: "\n"))
        let highlighter = SQLIncrementalHighlighter()
        highlighter.reset(text)
        let at = highlighter.lineStarts[50] + 3
        text.insert("x", at: at)
        let dirty = highlighter.edit(text, editedRange: NSRange(location: at, length: 1), changeInLength: 1)
        #expect(dirty.location == highlighter.lineStarts[50])
        #expect(NSMaxRange(dirty) == highlighter.lineStarts[51])
        // Opening a block comment recolours to the end.
        text.insert("/*", at: at)
        let opened = highlighter.edit(text, editedRange: NSRange(location: at, length: 2), changeInLength: 2)
        #expect(NSMaxRange(opened) == text.length)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUNNYGRID_BENCH"] == "1"))
    func benchmarkLargeScript() {
        let line = "SELECT id, name, 'it''s' AS s FROM events WHERE id > 42 /* c */ -- tail\n"
        let text = NSMutableString(string: String(repeating: line, count: 20_000))
        let clock = ContinuousClock()
        let highlighter = SQLIncrementalHighlighter()
        let full = clock.measure { _ = SQLLexer.tokenize(text) }
        let reset = clock.measure { highlighter.reset(text) }
        let middle = text.length / 2
        let keystrokes = clock.measure {
            for i in 0..<1_000 {
                text.insert("a", at: middle + i)
                let range = highlighter.edit(text, editedRange: NSRange(location: middle + i, length: 1), changeInLength: 1)
                _ = highlighter.tokens(in: range, of: text)
            }
        }
        print("[bench] tokenize 20k lines: \(full), reset: \(reset), 1000 keystrokes: \(keystrokes)")
    }
}

/// Deterministic generator for the random-edit test.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
