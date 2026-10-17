import AppKit
import BunnyGridCore
import SwiftUI

/// Plain-text SQL editor on `NSTextView` with lightweight syntax highlighting and completion.
/// A tree-sitter based editor (e.g. CodeEditSourceEditor) can replace it later.
struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedText: String
    /// Returns suggestions for the word being typed; `qualifier` is the identifier before a `.`.
    var completions: ((_ prefix: String, _ qualifier: String?) -> [String])?
    /// Hands the text view to the owner (for AI inserts with undo).
    var onTextView: ((NSTextView) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let size = scrollView.contentSize

        let textView = SQLTextView(frame: NSRect(origin: .zero, size: size))
        textView.minSize = NSSize(width: 0, height: size.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = SQLHighlighter.font
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.string = text
        SQLHighlighter.highlight(textView)

        scrollView.documentView = textView
        onTextView?(textView)
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        SQLHighlighter.highlight(textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditorView

        init(_ parent: SQLEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            SQLHighlighter.highlight(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            parent.selectedText = range.length > 0 ? (textView.string as NSString).substring(with: range) : ""
        }

        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            guard let provider = parent.completions else { return [] }
            let string = textView.string as NSString
            let prefix = string.substring(with: charRange)
            let qualifier = SQLTextView.qualifier(in: string, before: charRange.location)
            let results = provider(prefix, qualifier)
            // With a single exact candidate, preselect it so Return accepts it; otherwise nothing is
            // inserted until the user picks, which keeps auto-triggered completion out of the way.
            index?.pointee = results.count == 1 ? 0 : -1
            return results
        }
    }
}

/// Text view that completes identifiers (including `alias.column`) instead of dictionary words.
final class SQLTextView: NSTextView {
    private static func isIdentifierChar(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || c == 0x5F /* _ */ || c == 0x24 /* $ */
    }

    /// The identifier right before the cursor, possibly empty (e.g. just after `o.`).
    override var rangeForUserCompletion: NSRange {
        let cursor = selectedRange().location
        let string = self.string as NSString
        var start = cursor
        while start > 0 && Self.isIdentifierChar(string.character(at: start - 1)) { start -= 1 }
        return NSRange(location: start, length: cursor - start)
    }

    /// The identifier before a `.` that ends at `location`, unquoted.
    static func qualifier(in string: NSString, before location: Int) -> String? {
        guard location > 0, string.character(at: location - 1) == 0x2E /* . */ else { return nil }
        var start = location - 1
        let quoteChars: Set<unichar> = [0x22, 0x60] // " `
        while start > 0 {
            let c = string.character(at: start - 1)
            guard isIdentifierChar(c) || quoteChars.contains(c) else { break }
            start -= 1
        }
        let raw = string.substring(with: NSRange(location: start, length: location - 1 - start))
        let unquoted = raw.filter { $0 != "\"" && $0 != "`" }
        return unquoted.isEmpty ? nil : unquoted
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        if (string as? String) == "." {
            complete(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        // ⌃Space opens completion, like most code editors (Esc also works, as in every NSTextView).
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control, event.charactersIgnoringModifiers == " " {
            complete(nil)
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
enum SQLHighlighter {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private static let rules: [(NSRegularExpression, NSColor)] = [
        (regex("\\b(" + SQLKeywords.all.joined(separator: "|") + ")\\b", options: .caseInsensitive), .systemPink),
        (regex("\\b\\d+(\\.\\d+)?\\b"), .systemBlue),
        (regex("'(?:[^']|'')*'?"), .systemRed),
        (regex("--[^\\n]*|/\\*[\\s\\S]*?(\\*/|$)"), .secondaryLabelColor),
    ]

    private static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are compile-time constants; a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    static func highlight(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: full)
        // Later rules win, so strings and comments override keywords inside them.
        for (regex, color) in rules {
            regex.enumerateMatches(in: storage.string, range: full) { match, _, _ in
                if let range = match?.range { storage.addAttribute(.foregroundColor, value: color, range: range) }
            }
        }
        storage.endEditing()
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
    }
}
