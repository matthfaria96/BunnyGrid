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
    /// Called when the selection or cursor moves (status bar Line / Col).
    var onCursorChange: ((NSTextView) -> Void)?
    /// Commands put at the top of the context menu (Run Current Statement, Explain…).
    var menuItems: [MenuItem] = []

    /// A context-menu command. The shortcut is shown in the menu; the owner registers the real one.
    struct MenuItem {
        let title: String
        var key = ""
        var modifiers: NSEvent.ModifierFlags = []
        let isEnabled: Bool
        let action: () -> Void
    }

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
        textView.menuItems = menuItems
        SQLHighlighter.highlight(textView)

        scrollView.documentView = textView
        context.coordinator.observeOptions(scrollView: scrollView, textView: textView)
        EditorOptionsApplier.apply(AppOptions.shared.values, to: scrollView, textView: textView)
        onTextView?(textView)
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        (scrollView.documentView as? SQLTextView)?.menuItems = menuItems
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        SQLHighlighter.highlight(textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditorView

        private var optionsObserver: NSObjectProtocol?

        init(_ parent: SQLEditorView) {
            self.parent = parent
        }

        /// Re-applies Options › Editor and Code Completion when the Options window saves.
        func observeOptions(scrollView: NSScrollView, textView: NSTextView) {
            optionsObserver = NotificationCenter.default.addObserver(forName: .optionsDidChange, object: nil, queue: .main) { [weak scrollView, weak textView] _ in
                MainActor.assumeIsolated {
                    guard let scrollView, let textView else { return }
                    EditorOptionsApplier.apply(AppOptions.shared.values, to: scrollView, textView: textView)
                    SQLHighlighter.highlight(textView)
                }
            }
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
            if AppOptions.shared.values.useBraceHighlighting { BraceHighlighter.update(textView) }
            parent.onCursorChange?(textView)
        }

        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            guard AppOptions.shared.values.useCodeCompletion, let provider = parent.completions else { return [] }
            let string = textView.string as NSString
            let prefix = string.substring(with: charRange)
            let qualifier = SQLTextView.qualifier(in: string, before: charRange.location)
            let results = provider(prefix, qualifier)
            // With a single exact candidate, preselect it so Return accepts it; otherwise nothing is
            // inserted until the user picks, which keeps auto-triggered completion out of the way.
            // Options › Code Completion › "Auto select first suggestion".
            index?.pointee = results.count == 1 || (AppOptions.shared.values.autoSelectFirstSuggestion && !results.isEmpty) ? 0 : -1
            return results
        }
    }
}

/// Text view that completes identifiers (including `alias.column`) instead of dictionary words.
final class SQLTextView: NSTextView {
    var menuItems: [SQLEditorView.MenuItem] = []

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard !menuItems.isEmpty else { return menu }
        menu.insertItem(.separator(), at: 0)
        for item in menuItems.reversed() {
            menu.insertItem(ClosureMenuItem(item), at: 0)
        }
        return menu
    }

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
        if (string as? String) == ".", AppOptions.shared.values.useCodeCompletion {
            complete(nil)
        }
    }

    /// Options › Editor › "Insert spaces when pressing Tab".
    override func insertTab(_ sender: Any?) {
        let options = AppOptions.shared.values
        if options.insertSpacesForTab {
            insertText(String(repeating: " ", count: max(options.tabWidth, 1)), replacementRange: selectedRange())
        } else {
            super.insertTab(sender)
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

/// A context-menu item that runs a closure and is enabled as its `MenuItem` says.
private final class ClosureMenuItem: NSMenuItem, NSMenuItemValidation {
    private let handler: () -> Void
    private let allowsAction: Bool

    init(_ item: SQLEditorView.MenuItem) {
        handler = item.action
        allowsAction = item.isEnabled
        super.init(title: item.title, action: #selector(runHandler), keyEquivalent: item.key)
        keyEquivalentModifierMask = item.modifiers
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func runHandler() { handler() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { allowsAction }
}

@MainActor
enum SQLHighlighter {
    static let defaultFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    static var font: NSFont { AppOptions.shared.values.editorFont?.nsFont ?? defaultFont }

    private static let keywordRule = regex("\\b(" + SQLKeywords.all.joined(separator: "|") + ")\\b", options: .caseInsensitive)
    private static let numberRule = regex("\\b\\d+(\\.\\d+)?\\b")
    private static let stringRule = regex("'(?:[^']|'')*'?")
    private static let commentRule = regex("--[^\\n]*|/\\*[\\s\\S]*?(\\*/|$)")

    private static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are compile-time constants; a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    static func highlight(_ textView: NSTextView) {
        highlight(textView, options: AppOptions.shared.values)
    }

    /// Colors from Options › Editor (system colors where none was chosen); off above the size limit.
    static func highlight(_ textView: NSTextView, options: OptionsValues) {
        guard let storage = textView.textStorage else { return }
        let colors = options.syntaxColors
        let font = options.editorFont?.nsFont ?? defaultFont
        let common = NSColor(hex: colors.common) ?? .labelColor
        textView.backgroundColor = NSColor(hex: colors.background) ?? .textBackgroundColor
        textView.insertionPointColor = common
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: common], range: full)
        let limit = max(options.disableHighlightAboveMB, 1) * 1_000_000
        if options.useSyntaxHighlighting, storage.length * 2 <= limit {
            let rules: [(NSRegularExpression, NSColor)] = [
                (keywordRule, NSColor(hex: colors.keyword) ?? .systemPink),
                (numberRule, NSColor(hex: colors.number) ?? .systemBlue),
                (stringRule, NSColor(hex: colors.string) ?? .systemRed),
                (commentRule, NSColor(hex: colors.comment) ?? .secondaryLabelColor),
            ]
            // Later rules win, so strings and comments override keywords inside them.
            for (regex, color) in rules {
                regex.enumerateMatches(in: storage.string, range: full) { match, _, _ in
                    if let range = match?.range { storage.addAttribute(.foregroundColor, value: color, range: range) }
                }
            }
        }
        storage.endEditing()
        textView.typingAttributes = [.font: font, .foregroundColor: common]
    }
}

/// Applies Options › Editor to an editor: line numbers, word wrap and tab width.
@MainActor
enum EditorOptionsApplier {
    static func apply(_ options: OptionsValues, to scrollView: NSScrollView, textView: NSTextView) {
        // Line numbers.
        if options.showLineNumbers {
            if !(scrollView.verticalRulerView is LineNumberRuler) {
                scrollView.verticalRulerView = LineNumberRuler(textView: textView)
            }
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
        } else {
            scrollView.rulersVisible = false
        }
        // Word wrap.
        if options.wordWrap {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
            textView.frame.size.width = scrollView.contentSize.width
        } else {
            scrollView.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
        // Tab width for tab characters.
        let font = options.editorFont?.nsFont ?? SQLHighlighter.defaultFont
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        let paragraph = NSMutableParagraphStyle()
        paragraph.defaultTabInterval = space * CGFloat(max(options.tabWidth, 1))
        paragraph.tabStops = []
        textView.defaultParagraphStyle = paragraph
        if let storage = textView.textStorage {
            storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length))
        }
        textView.typingAttributes[.paragraphStyle] = paragraph
        scrollView.verticalRulerView?.needsDisplay = true
    }
}

/// Line numbers in the editor's gutter.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func refresh() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        (textView.backgroundColor.blended(withFraction: 0.04, of: .labelColor) ?? textView.backgroundColor).setFill()
        bounds.fill()
        let string = textView.string as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: max((textView.font?.pointSize ?? 13) - 2, 9), weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let visible = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        // Line number of the first visible character.
        var line = 1
        string.enumerateSubstrings(in: NSRange(location: 0, length: characterRange.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        let inset = textView.textContainerInset.height
        let offset = convert(NSPoint.zero, from: textView).y
        var index = characterRange.location
        let widthNeeded = ("\(line + 999)" as NSString).size(withAttributes: attributes).width + 14
        if widthNeeded > ruleThickness { ruleThickness = widthNeeded }
        repeat {
            let lineRange = string.lineRange(for: NSRange(location: min(index, max(string.length - 1, 0)), length: 0))
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: lineRange.location, length: max(lineRange.length, 0)), actualCharacterRange: nil)
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: min(glyphs.location, max(layoutManager.numberOfGlyphs - 1, 0)), effectiveRange: nil)
            lineRect.origin.y += inset + offset
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: lineRect.minY + (lineRect.height - size.height) / 2), withAttributes: attributes)
            line += 1
            index = NSMaxRange(lineRange)
        } while index < NSMaxRange(characterRange) && index < string.length
        // The extra empty line after a trailing newline.
        if string.length == 0 || string.hasSuffix("\n"), index >= string.length {
            var rect = layoutManager.extraLineFragmentRect
            if string.length == 0 { rect = NSRect(x: 0, y: 0, width: 0, height: font.boundingRectForFont.height + 2) }
            rect.origin.y += inset + offset
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: rect.minY + (rect.height - size.height) / 2), withAttributes: attributes)
        }
    }
}

/// Options › Editor › "Use brace highlighting": marks the bracket matching the one beside the cursor.
@MainActor
enum BraceHighlighter {
    private static let pairs: [unichar: (match: unichar, forward: Bool)] = [
        0x28: (0x29, true), 0x29: (0x28, false), 0x5B: (0x5D, true), 0x5D: (0x5B, false), 0x7B: (0x7D, true), 0x7D: (0x7B, false),
    ]

    static func update(_ textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let string = textView.string as NSString
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: string.length))
        let cursor = textView.selectedRange()
        guard cursor.length == 0 else { return }
        for position in [cursor.location - 1, cursor.location] where position >= 0 && position < string.length {
            let character = string.character(at: position)
            guard let pair = pairs[character], let match = matchIndex(in: string, from: position, open: character, close: pair.match, forward: pair.forward) else { continue }
            let color = NSColor.systemYellow.withAlphaComponent(0.35)
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: NSRange(location: position, length: 1))
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: NSRange(location: match, length: 1))
            return
        }
    }

    private static func matchIndex(in string: NSString, from start: Int, open: unichar, close: unichar, forward: Bool) -> Int? {
        var depth = 0
        var index = start
        let limit = 200_000
        var steps = 0
        while index >= 0 && index < string.length && steps < limit {
            let c = string.character(at: index)
            if c == open { depth += 1 } else if c == close { depth -= 1; if depth == 0 { return index } }
            index += forward ? 1 : -1
            steps += 1
        }
        return nil
    }
}
