import Foundation

/// A column type split as Navicat's designer shows it: base type, Size and Scale
/// (`numeric(10,2)` → `numeric`, `10`, `2`; `varchar(255)` → `varchar`, `255`, ``).
public struct SQLTypeParts: Equatable, Sendable {
    public var base: String
    public var size: String
    public var scale: String

    public init(base: String, size: String = "", scale: String = "") {
        self.base = base
        self.size = size
        self.scale = scale
    }

    /// Parses `base(size[,scale])[suffix]`. Types whose parentheses aren't plain numbers (enum('a','b')) keep them in `base`.
    public init(_ type: String) {
        let trimmed = type.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(of: "("), let close = trimmed[open...].firstIndex(of: ")") else {
            self.init(base: trimmed)
            return
        }
        let inner = trimmed[trimmed.index(after: open)..<close].split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(inner.count), inner.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            self.init(base: trimmed)
            return
        }
        let head = trimmed[..<open].trimmingCharacters(in: .whitespaces)
        let tail = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
        self.init(base: tail.isEmpty ? head : head + " " + tail, size: inner[0], scale: inner.count == 2 ? inner[1] : "")
    }

    /// The type text again; a scale without a size is dropped. Suffixes such as `unsigned` go after the parentheses.
    public var type: String {
        let size = size.trimmingCharacters(in: .whitespaces)
        let scale = scale.trimmingCharacters(in: .whitespaces)
        guard !size.isEmpty else { return base }
        let args = scale.isEmpty ? size : "\(size),\(scale)"
        let words = base.split(separator: " ", maxSplits: 1).map(String.init)
        return words.count == 2 ? "\(words[0])(\(args)) \(words[1])" : "\(base)(\(args))"
    }
}
