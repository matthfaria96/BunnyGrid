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
        // Lay out only what is shown: large scripts would otherwise be laid out in full on every change.
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.highlighter = context.coordinator.highlighter
        textView.flushText = { [weak coordinator = context.coordinator] in coordinator?.flush() }
        textView.string = text
        // After the text: `highlight` below colours it in chunks; the delegate colours later edits.
        textView.textStorage?.delegate = context.coordinator
        context.coordinator.lastText = text
        textView.menuItems = menuItems
        PerfTrace.measure("editor.fullHighlight") { SQLHighlighter.highlight(textView) }

        scrollView.documentView = textView
        context.coordinator.observeOptions(scrollView: scrollView, textView: textView)
        EditorOptionsApplier.apply(AppOptions.shared.values, to: scrollView, textView: textView)
        onTextView?(textView)
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        CompletionWarmUp.scheduleOnce()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        // Reading `text` below must not push pending typing into the model in the middle of a view update.
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }
        (scrollView.documentView as? SQLTextView)?.menuItems = menuItems
        // The text this editor last pushed comes back unchanged on every SwiftUI update: comparing it with
        // the same string is O(1) (shared storage), unlike comparing against the text view's string.
        guard text != context.coordinator.lastText, let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.lastText = text
        guard textView.string != text else { return }
        // Replaced wholesale: `highlight` rebuilds the line table and colours in chunks, so the per-edit
        // colouring is skipped for this one.
        let delegate = textView.textStorage?.delegate
        textView.textStorage?.delegate = nil
        textView.string = text
        textView.textStorage?.delegate = delegate
        SQLHighlighter.highlight(textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: SQLEditorView
        /// Line table and lexer states, so each edit re-colours only the lines it touched.
        let highlighter = SQLIncrementalHighlighter()
        /// The text last sent to (or received from) the binding.
        var lastText = ""

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

        /// Typed text not yet sent to the binding.
        private var hasPendingText = false
        var isUpdating = false
        private weak var pendingTextView: NSTextView?

        /// Copying a large script into the binding on every keystroke costs more than the keystroke itself,
        /// so the text goes out shortly after typing pauses, or as soon as someone asks for it
        /// (`SQLTextView.flushText`, which `QueryTabModel.text` calls before reading).
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            pendingTextView = textView
            guard !hasPendingText else { return }
            hasPendingText = true
            let length = (textView.string as NSString).length
            // Small documents sync at once (cheap); large ones are coalesced.
            if length < 20_000 { flush(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.flush() }
        }

        func flush() {
            guard !isUpdating, hasPendingText, let textView = pendingTextView else { return }
            hasPendingText = false
            PerfTrace.measure("editor.flushText") {
                let text = Self.nativeString(textView.string as NSString)
                lastText = text
                parent.text = text
            }
        }

        /// A native Swift copy of the text (one optimized transcode), so later comparisons and
        /// reads don't go through the bridged NSString character by character.
        static func nativeString(_ string: NSString) -> String {
            let length = string.length
            guard length > 0 else { return "" }
            var units = [UInt16](repeating: 0, count: length)
            units.withUnsafeMutableBufferPointer { string.getCharacters($0.baseAddress!, range: NSRange(location: 0, length: length)) }
            return String(decoding: units, as: UTF16.self)
        }

        /// Colours the edited lines (and any after them whose state changed) as part of the same edit.
        nonisolated func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                                     range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            // The text view's storage: only ever edited on the main thread.
            nonisolated(unsafe) let storage = textStorage
            MainActor.assumeIsolated {
                let dirty = highlighter.edit(storage.string as NSString, editedRange: editedRange, changeInLength: delta)
                let options = AppOptions.shared.values
                guard let textView = storage.layoutManagers.first?.firstTextView as? SQLTextView else {
                    SQLHighlighter.colour(storage, range: dirty, highlighter: highlighter, options: options)
                    return
                }
                // Keep pending chunked colouring in step with the edit.
                if textView.colouredUpTo != .max, editedRange.location < textView.colouredUpTo {
                    textView.colouredUpTo = max(textView.colouredUpTo + delta, editedRange.location)
                }
                // A stray quote or `/*` can change the colours of everything after it: colour the part at the
                // edit now and the rest a chunk per run-loop turn, instead of hundreds of thousands of characters
                // inside the keystroke.
                var now = dirty
                if dirty.length > SQLHighlighter.colourChunk {
                    now = highlighter.lineRange(for: NSRange(location: dirty.location, length: SQLHighlighter.colourChunk))
                    SQLHighlighter.colourLater(textView, from: NSMaxRange(now), options: options)
                }
                SQLHighlighter.colour(storage, range: now, highlighter: highlighter, options: options)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            let selected = range.length > 0 ? (textView.string as NSString).substring(with: range) : ""
            if selected != parent.selectedText { parent.selectedText = selected }
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
    /// The editor's line table (kept current by the coordinator); also answers line numbers.
    var highlighter: SQLIncrementalHighlighter?
    /// Sends typed text that is still pending to the binding (see `Coordinator.textDidChange`).
    var flushText: (() -> Void)?
    /// Progress of the chunked colouring of a newly loaded text (`SQLHighlighter.highlight`).
    /// `.max` when nothing is pending.
    var colouredUpTo = Int.max
    var colourGeneration = 0

    /// Replaces the whole text (Beautify, AI "Replace All") as one undoable step. NSTextView's own undo would put
    /// back the old text as an attributed string with tens of thousands of colour runs, which NSTextStorage inserts
    /// run by run (12 s for a 20,000-line script); here both directions are plain strings, and the new text is
    /// coloured in chunks after the edit like a newly opened file. Ends with the whole text selected.
    func replaceAllText(_ newText: String) {
        guard let storage = textStorage else { return }
        let oldText = string
        breakUndoCoalescing()
        undoManager?.registerUndo(withTarget: self) { view in
            MainActor.assumeIsolated { view.replaceAllText(oldText) }
        }
        // The per-edit colouring is skipped; `highlight` rebuilds the line table and colours in chunks.
        let delegate = storage.delegate
        storage.delegate = nil
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: newText)
        storage.endEditing()
        storage.delegate = delegate
        SQLHighlighter.highlight(self)
        didChangeText()
        setSelectedRange(NSRange(location: 0, length: storage.length))
        scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

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

/// The first completion popup of a launch pays for AppKit's one-time setup of its table-based window (classes,
/// cells, fonts). Once an editor has appeared and the app is idle, the same kind of window is built and drawn
/// off screen (never ordered in), so the first "." in the editor doesn't stall.
@MainActor
enum CompletionWarmUp {
    private static var scheduled = false

    static func scheduleOnce() {
        guard !scheduled else { return }
        scheduled = true
        // In the default mode only: not during scrolling or a drag.
        RunLoop.main.perform(inModes: [.default]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                RunLoop.main.perform(inModes: [.default]) { MainActor.assumeIsolated { warmUp() } }
            }
        }
    }

    private static func warmUp() {
        PerfTrace.measure("editor.completionWarmUp") {
            let panel = NSPanel(contentRect: NSRect(x: -10_000, y: -10_000, width: 240, height: 160),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isReleasedWhenClosed = false
            let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
            column.width = 240
            table.addTableColumn(column)
            table.headerView = nil
            let scroll = NSScrollView(frame: table.frame)
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            panel.contentView = scroll
            let cell = NSTextFieldCell(textCell: "warm_up_identifier")
            cell.font = SQLHighlighter.font
            let image = NSImage(size: NSSize(width: 240, height: 20), flipped: false) { rect in
                cell.draw(withFrame: rect, in: table)
                return true
            }
            _ = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            scroll.layoutSubtreeIfNeeded()
            if let rep = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) { scroll.cacheDisplay(in: scroll.bounds, to: rep) }
            panel.close()
        }
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
    /// Navicat's default editor font (Options › Editor shows it as "Menlo-Regular 11.0").
    static let defaultFont = NSFont(name: "Menlo-Regular", size: 11) ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    static var font: NSFont { AppOptions.shared.values.editorFont?.nsFont ?? defaultFont }

    static func highlight(_ textView: NSTextView) {
        highlight(textView, options: AppOptions.shared.values)
    }

    /// Colours from Options › Editor (system colors where none was chosen); off above the size limit.
    /// Rebuilds the line table of an `SQLTextView` and colours the whole text.
    static func highlight(_ textView: NSTextView, options: OptionsValues) {
        guard let storage = textView.textStorage else { return }
        let colors = options.syntaxColors
        let font = options.editorFont?.nsFont ?? defaultFont
        let common = NSColor(hex: colors.common) ?? .labelColor
        textView.backgroundColor = NSColor(hex: colors.background) ?? .textBackgroundColor
        textView.insertionPointColor = common
        let highlighter = (textView as? SQLTextView)?.highlighter ?? SQLIncrementalHighlighter()
        highlighter.reset(storage.string as NSString)
        let full = NSRange(location: 0, length: storage.length)
        let sqlTextView = textView as? SQLTextView
        sqlTextView?.colourGeneration += 1
        // A long script is coloured a chunk per run-loop turn, so opening it doesn't freeze the window.
        let first = sqlTextView == nil ? full.length : min(full.length, colourChunk)
        // Font and colours go on chunk by chunk (`colour` resets each range first): one attribute over a whole
        // text that already has thousands of colour runs costs seconds.
        storage.beginEditing()
        colour(storage, range: NSRange(location: 0, length: first), highlighter: highlighter, options: options)
        storage.endEditing()
        textView.typingAttributes[.font] = font
        textView.typingAttributes[.foregroundColor] = common
        sqlTextView?.colouredUpTo = .max
        if let sqlTextView, first < full.length { colourLater(sqlTextView, from: first, options: options) }
    }

    /// Colours `textView` from `offset` to the end in chunks, joining a pass already under way.
    static func colourLater(_ textView: SQLTextView, from offset: Int, options: OptionsValues) {
        let running = textView.colouredUpTo != .max
        textView.colouredUpTo = min(textView.colouredUpTo, offset)
        guard !running else { return }
        textView.colourGeneration += 1
        continueColouring(textView, generation: textView.colourGeneration, options: options)
    }

    /// Characters coloured per run-loop turn when a large text is loaded.
    static let colourChunk = 8_000

    private static func continueColouring(_ textView: SQLTextView, generation: Int, options: OptionsValues) {
        // After a delay, not `async`: the run loop must sleep in between so each frame is committed.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) { [weak textView] in
            guard let textView, textView.colourGeneration == generation, let storage = textView.textStorage,
                  let highlighter = textView.highlighter else { return }
            let start = min(textView.colouredUpTo, storage.length)
            guard start < storage.length else {
                textView.colouredUpTo = .max
                return
            }
            let range = highlighter.lineRange(for: NSRange(location: start, length: min(colourChunk, storage.length - start)))
            storage.beginEditing()
            colour(storage, range: range, highlighter: highlighter, options: options)
            storage.endEditing()
            textView.colouredUpTo = NSMaxRange(range)
            continueColouring(textView, generation: generation, options: options)
        }
    }

    /// Re-colours the whole lines in `range` from the highlighter's tokens.
    static func colour(_ storage: NSTextStorage, range: NSRange, highlighter: SQLIncrementalHighlighter, options: OptionsValues) {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        let colors = options.syntaxColors
        let common = NSColor(hex: colors.common) ?? .labelColor
        let font = options.editorFont?.nsFont ?? defaultFont
        storage.addAttribute(.font, value: font, range: range)
        storage.addAttribute(.foregroundColor, value: common, range: range)
        let limit = max(options.disableHighlightAboveMB, 1) * 1_000_000
        guard options.useSyntaxHighlighting, storage.length * 2 <= limit, range.length > 0 else { return }
        let palette: [SQLTokenKind: NSColor] = [
            .keyword: NSColor(hex: colors.keyword) ?? .navicatKeyword,
            .number: NSColor(hex: colors.number) ?? .systemBlue,
            .string: NSColor(hex: colors.string) ?? .navicatString,
            .comment: NSColor(hex: colors.comment) ?? .secondaryLabelColor,
        ]
        // Keywords are bold, as in Navicat; everything else uses the plain editor font.
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        for token in highlighter.tokens(in: range, of: storage.string as NSString) {
            storage.addAttribute(.foregroundColor, value: palette[token.kind]!, range: token.range)
            if token.kind == .keyword { storage.addAttribute(.font, value: bold, range: token.range) }
        }
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
        if let highlighter = (textView as? SQLTextView)?.highlighter, highlighter.length == string.length {
            line = highlighter.line(containing: characterRange.location) + 1
        } else {
            string.enumerateSubstrings(in: NSRange(location: 0, length: characterRange.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        }
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

    /// The two brackets marked last, so moving the cursor clears just those (not the whole text).
    private static var marked: [ObjectIdentifier: [NSRange]] = [:]

    static func update(_ textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let string = textView.string as NSString
        for range in marked.removeValue(forKey: ObjectIdentifier(textView)) ?? [] where NSMaxRange(range) <= string.length {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        let cursor = textView.selectedRange()
        guard cursor.length == 0 else { return }
        for position in [cursor.location - 1, cursor.location] where position >= 0 && position < string.length {
            let character = string.character(at: position)
            guard let pair = pairs[character], let match = matchIndex(in: string, from: position, open: character, close: pair.match, forward: pair.forward) else { continue }
            let color = NSColor.systemYellow.withAlphaComponent(0.35)
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: NSRange(location: position, length: 1))
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: NSRange(location: match, length: 1))
            marked[ObjectIdentifier(textView)] = [NSRange(location: position, length: 1), NSRange(location: match, length: 1)]
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
