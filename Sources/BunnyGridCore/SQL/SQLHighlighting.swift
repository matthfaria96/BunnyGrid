import Foundation

/// What the SQL editor colours.
public enum SQLTokenKind: UInt8, Sendable {
    case keyword, number, string, comment
}

/// A coloured run, in UTF-16 offsets (NSString / NSTextStorage coordinates).
public struct SQLToken: Equatable, Sendable {
    public var location: Int
    public var length: Int
    public var kind: SQLTokenKind

    public init(location: Int, length: Int, kind: SQLTokenKind) {
        self.location = location
        self.length = length
        self.kind = kind
    }

    public var range: NSRange { NSRange(location: location, length: length) }
}

/// Where a line starts: inside nothing, or inside a construct that spans lines.
public enum SQLLexState: UInt8, Sendable {
    case normal, blockComment, string, quotedIdentifier, backtickIdentifier
}

/// A line-oriented SQL scanner: keywords, numbers, `'strings'` (with `''`), `-- comments` and
/// `/* block comments */`. Quoted identifiers (`"…"`, `` `…` ``) are plain text. Each line is scanned from the
/// state the previous line ended in, which is what makes incremental re-highlighting possible.
public enum SQLLexer {
    private static let newline: UInt16 = 0x0A

    /// Scans `chars[start..<end]` (one line, its `\n` included) from `state`; appends tokens
    /// (offset by `base`) and returns the state the line ends in.
    static func scan(_ chars: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int, base: Int,
                     state initial: SQLLexState, into tokens: inout [SQLToken]) -> SQLLexState {
        var i = start
        var state = initial
        func emit(_ from: Int, _ to: Int, _ kind: SQLTokenKind) {
            guard to > from else { return }
            tokens.append(SQLToken(location: base + from, length: to - from, kind: kind))
        }
        while i < end {
            switch state {
            case .blockComment:
                let from = i
                while i < end {
                    if chars[i] == 0x2A /* * */, i + 1 < end, chars[i + 1] == 0x2F /* / */ { i += 2; state = .normal; break }
                    i += 1
                }
                emit(from, i, .comment)
            case .string:
                let from = i
                while i < end {
                    if chars[i] == 0x27 /* ' */ {
                        if i + 1 < end, chars[i + 1] == 0x27 { i += 2; continue }
                        i += 1
                        state = .normal
                        break
                    }
                    i += 1
                }
                emit(from, i, .string)
            case .quotedIdentifier, .backtickIdentifier:
                let quote: UInt16 = state == .quotedIdentifier ? 0x22 : 0x60
                while i < end {
                    if chars[i] == quote { i += 1; state = .normal; break }
                    i += 1
                }
            case .normal:
                let c = chars[i]
                if c == 0x2D /* - */, i + 1 < end, chars[i + 1] == 0x2D {
                    // To the end of the line, without the line break.
                    var to = end
                    if to > i, chars[to - 1] == newline { to -= 1 }
                    emit(i, to, .comment)
                    i = end
                } else if c == 0x2F /* / */, i + 1 < end, chars[i + 1] == 0x2A {
                    let from = i
                    i += 2
                    state = .blockComment
                    while i < end {
                        if chars[i] == 0x2A, i + 1 < end, chars[i + 1] == 0x2F { i += 2; state = .normal; break }
                        i += 1
                    }
                    emit(from, i, .comment)
                } else if c == 0x27 {
                    let from = i
                    i += 1
                    state = .string
                    while i < end {
                        if chars[i] == 0x27 {
                            if i + 1 < end, chars[i + 1] == 0x27 { i += 2; continue }
                            i += 1
                            state = .normal
                            break
                        }
                        i += 1
                    }
                    emit(from, i, .string)
                } else if c == 0x22 || c == 0x60 {
                    state = c == 0x22 ? .quotedIdentifier : .backtickIdentifier
                    i += 1
                } else if isWord(c) {
                    let from = i
                    while i < end, isWord(chars[i]) { i += 1 }
                    if isDigit(chars[from]) {
                        // \b\d+(\.\d+)?\b: a word made only of digits, optionally ".digits".
                        if allDigits(chars, from, i) {
                            if i + 1 < end, chars[i] == 0x2E, isDigit(chars[i + 1]) {
                                var j = i + 1
                                while j < end, isWord(chars[j]) { j += 1 }
                                if allDigits(chars, i + 1, j) { i = j }
                            }
                            emit(from, i, .number)
                        }
                    } else if isKeyword(chars, from, i) {
                        emit(from, i, .keyword)
                    }
                } else {
                    i += 1
                }
            }
        }
        return state
    }

    @inline(__always) static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

    /// Regex `\w`: letters, digits and `_`; anything outside ASCII counts as a letter.
    @inline(__always) static func isWord(_ c: UInt16) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c > 0x7F
    }

    @inline(__always) private static func allDigits(_ chars: UnsafeBufferPointer<UInt16>, _ from: Int, _ to: Int) -> Bool {
        var k = from
        while k < to { if !isDigit(chars[k]) { return false }; k += 1 }
        return true
    }

    /// Keywords packed 5 bits per lowercase letter (up to 12 letters) for allocation-free lookup.
    private static let packedKeywords: Set<UInt64> = Set(SQLKeywords.all.compactMap { pack(Array($0.utf16)[...]) })
    private static let longKeywords: Set<String> = Set(SQLKeywords.all.filter { $0.utf16.count > 12 })

    private static func pack(_ word: ArraySlice<UInt16>) -> UInt64? {
        guard word.count <= 12 else { return nil }
        var value: UInt64 = 0
        for c in word {
            let lower = c >= 0x41 && c <= 0x5A ? c + 0x20 : c
            let code: UInt64
            if lower >= 0x61 && lower <= 0x7A { code = UInt64(lower - 0x61 + 1) } else if lower == 0x5F { code = 27 } else { return nil }
            value = value << 5 | code
        }
        return value
    }

    private static func isKeyword(_ chars: UnsafeBufferPointer<UInt16>, _ from: Int, _ to: Int) -> Bool {
        let count = to - from
        if count > 12 {
            guard !longKeywords.isEmpty else { return false }
            return longKeywords.contains(String(utf16CodeUnits: Array(chars[from..<to]), count: count).lowercased())
        }
        var value: UInt64 = 0
        var k = from
        while k < to {
            let c = chars[k]
            let lower = c >= 0x41 && c <= 0x5A ? c + 0x20 : c
            guard lower >= 0x61 && lower <= 0x7A || lower == 0x5F else { return false }
            value = value << 5 | (lower == 0x5F ? 27 : UInt64(lower - 0x61 + 1))
            k += 1
        }
        return packedKeywords.contains(value)
    }

    /// Every token of `text`, scanned in one pass (the reference the incremental highlighter must match).
    public static func tokenize(_ text: NSString) -> [SQLToken] {
        let chars = SQLText(text)
        var tokens: [SQLToken] = []
        var state = SQLLexState.normal
        chars.withBuffer { buffer in
            var start = 0
            while start < buffer.count {
                var end = start
                while end < buffer.count, buffer[end] != newline { end += 1 }
                if end < buffer.count { end += 1 }
                state = scan(buffer, start, end, base: 0, state: state, into: &tokens)
                start = end
            }
        }
        return tokens
    }
}

/// The UTF-16 of a range of an NSString, copied once for scanning.
struct SQLText {
    let units: [UInt16]

    init(_ text: NSString, range: NSRange? = nil) {
        let range = range ?? NSRange(location: 0, length: text.length)
        var units = [UInt16](repeating: 0, count: range.length)
        if range.length > 0 { units.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: range) } }
        self.units = units
    }

    func withBuffer<R>(_ body: (UnsafeBufferPointer<UInt16>) -> R) -> R {
        units.withUnsafeBufferPointer(body)
    }
}

/// Keeps a line table (start offset and starting lexer state of every line) in step with the editor's
/// text, so an edit re-scans only the edited lines and the lines after them whose starting state changed
/// (opening `/*` recolours to the end; typing a word recolours one line). Also answers "which line is
/// offset N on" by binary search, for the line-number gutter and the status bar.
public final class SQLIncrementalHighlighter {
    /// UTF-16 offset where each line starts; the first is 0. A trailing `\n` starts an empty last line.
    public private(set) var lineStarts: [Int] = [0]
    private var startStates: [SQLLexState] = [.normal]
    public private(set) var length = 0

    public init() {}

    public var lineCount: Int { lineStarts.count }

    /// Rebuilds the table for `text`.
    public func reset(_ text: NSString) {
        length = text.length
        var starts = [0]
        var states: [SQLLexState] = [.normal]
        let chars = SQLText(text)
        var scratch: [SQLToken] = []
        chars.withBuffer { buffer in
            var start = 0
            var state = SQLLexState.normal
            while start < buffer.count {
                var end = start
                while end < buffer.count, buffer[end] != 0x0A { end += 1 }
                guard end < buffer.count else { break }
                end += 1
                scratch.removeAll(keepingCapacity: true)
                state = SQLLexer.scan(buffer, start, end, base: 0, state: state, into: &scratch)
                starts.append(end)
                states.append(state)
                start = end
            }
        }
        lineStarts = starts
        startStates = states
    }

    /// The line holding `offset` (0-based); offsets at or past the end give the last line.
    public func line(containing offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func lineEnd(_ index: Int) -> Int {
        index + 1 < lineStarts.count ? lineStarts[index + 1] : length
    }

    /// Applies an edit that already happened in `text`: `editedRange` is the changed range in the new
    /// text and `changeInLength` how much longer it got (NSTextStorage's `editedRange` / `changeInLength`).
    /// Returns the range of whole lines whose colours may have changed.
    @discardableResult
    public func edit(_ text: NSString, editedRange: NSRange, changeInLength delta: Int) -> NSRange {
        let oldLength = length
        let location = min(max(editedRange.location, 0), oldLength)
        let oldEnd = min(max(editedRange.location + editedRange.length - delta, location), oldLength)
        let first = line(containing: location)
        let last = line(containing: oldEnd)
        let lastIsFinal = last == lineStarts.count - 1
        let regionStart = lineStarts[first]
        let newLength = text.length
        length = newLength
        let regionStop = lastIsFinal ? newLength : lineEnd(last) + delta

        // New line starts inside the edited lines.
        var newStarts: [Int] = []
        if regionStop > regionStart {
            let chars = SQLText(text, range: NSRange(location: regionStart, length: regionStop - regionStart))
            chars.withBuffer { buffer in
                for (index, unit) in buffer.enumerated() where unit == 0x0A { newStarts.append(regionStart + index + 1) }
            }
        }
        if !lastIsFinal, newStarts.last == regionStop { newStarts.removeLast() }

        // Shift the lines after the edit, then splice in the new ones.
        if delta != 0 {
            for index in (last + 1)..<lineStarts.count { lineStarts[index] += delta }
        }
        lineStarts.replaceSubrange((first + 1)..<(last + 1), with: newStarts)
        startStates.replaceSubrange((first + 1)..<(last + 1), with: Array(repeating: .normal, count: newStarts.count))
        let lastNew = first + newStarts.count

        // Re-scan from the first edited line until a line starts in the state it had before.
        var index = first
        var scratch: [SQLToken] = []
        var stopAt = lineEnd(lastNew)
        let window = max(stopAt - regionStart, 0)
        var chunk = SQLText(text, range: NSRange(location: regionStart, length: min(max(window, 4_096), newLength - regionStart)))
        var chunkStart = regionStart
        while true {
            let start = lineStarts[index], end = lineEnd(index)
            if end - chunkStart > chunk.units.count {
                // Grow the copied window geometrically as the re-scan runs on (an opened block comment).
                let wanted = min(max((end - start) * 2, chunk.units.count * 2, 4_096), newLength - start)
                chunk = SQLText(text, range: NSRange(location: start, length: wanted))
                chunkStart = start
            }
            scratch.removeAll(keepingCapacity: true)
            let endState = chunk.withBuffer { buffer in
                SQLLexer.scan(buffer, start - chunkStart, end - chunkStart, base: chunkStart, state: startStates[index], into: &scratch)
            }
            guard index + 1 < lineStarts.count else { stopAt = end; break }
            if index + 1 > lastNew && startStates[index + 1] == endState { stopAt = end; break }
            startStates[index + 1] = endState
            index += 1
        }
        return NSRange(location: regionStart, length: max(stopAt - regionStart, 0))
    }

    /// Tokens of the whole lines covering `range`, scanned from their recorded starting states.
    public func tokens(in range: NSRange, of text: NSString) -> [SQLToken] {
        guard length > 0 else { return [] }
        let first = line(containing: range.location)
        let last = line(containing: max(range.location, NSMaxRange(range) - 1))
        let start = lineStarts[first], end = lineEnd(last)
        guard end > start else { return [] }
        let chars = SQLText(text, range: NSRange(location: start, length: end - start))
        var tokens: [SQLToken] = []
        chars.withBuffer { buffer in
            for index in first...last {
                _ = SQLLexer.scan(buffer, lineStarts[index] - start, lineEnd(index) - start, base: start, state: startStates[index], into: &tokens)
            }
        }
        return tokens
    }

    /// The range of whole lines covering `range`.
    public func lineRange(for range: NSRange) -> NSRange {
        let first = line(containing: range.location)
        let last = line(containing: max(range.location, NSMaxRange(range) - 1))
        return NSRange(location: lineStarts[first], length: lineEnd(last) - lineStarts[first])
    }
}
