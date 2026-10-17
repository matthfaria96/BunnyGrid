import AppKit
import BunnyGridCore
import SwiftUI

/// Renders an assistant reply: headings, paragraphs, lists, quotes, tables, rules and code blocks.
struct MarkdownView: View {
    let text: String
    var fontSize: CGFloat = 12.5
    /// Whether SQL blocks offer Copy to New Query and the editor insert options.
    var codeActions = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownParser.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text, size: fontSize))
                .font(.system(size: fontSize + CGFloat(max(0, 4 - level)) * 1.5 + 1, weight: level <= 2 ? .bold : .semibold))
                .padding(.top, level <= 2 ? 4 : 2)
                .textSelection(.enabled)
        case .paragraph(let text):
            Text(Self.inline(text, size: fontSize))
                .font(.system(size: fontSize))
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let ordinal, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ordinal.map { "\($0)." } ?? (depth == 0 ? "•" : "◦"))
                    .font(.system(size: fontSize, weight: ordinal == nil ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: ordinal == nil ? 8 : 16, alignment: .trailing)
                Text(Self.inline(text, size: fontSize))
                    .font(.system(size: fontSize))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor.opacity(0.6)).frame(width: 3)
                Text(Self.inline(text, size: fontSize))
                    .font(.system(size: fontSize))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let language, let body, _):
            CodeBlockView(language: language, code: body, showsActions: codeActions)
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows, fontSize: fontSize)
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    /// Bold, italics, links and `code` (in red monospace, as Navicat's assistant shows it).
    static func inline(_ markdown: String, size: CGFloat = 12.5) -> AttributedString {
        var result = (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].foregroundColor = Color(nsColor: .systemRed)
            result[run.range].font = .system(size: size - 0.5, design: .monospaced)
        }
        return result
    }
}

private struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    let fontSize: CGFloat

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownView.inline(cell, size: fontSize)).font(.system(size: fontSize - 0.5, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                    }
                }
                .background(Color.primary.opacity(0.06))
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(MarkdownView.inline(cell, size: fontSize)).font(.system(size: fontSize - 0.5))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .textSelection(.enabled)
                        }
                    }
                    .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                }
            }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// A fenced code block: language label, highlighted code and (for SQL) Navicat's hover actions.
struct CodeBlockView: View {
    @Environment(AppModel.self) private var app
    let language: String
    let code: String
    var showsActions = true
    @State private var isHovering = false
    @State private var copied = false

    private var isSQL: Bool { MarkdownParser.isSQL(language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(language.isEmpty ? (isSQL ? "sql" : "code") : language)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if showsActions {
                    actions.opacity(isHovering ? 1 : 0.55)
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, 4)
            .frame(height: 24)
            .background(Color.primary.opacity(0.04))
            Divider().opacity(0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(isSQL ? SQLSyntax.highlight(code) : AttributedString(code))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(9)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.8)))
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 0) {
            if isSQL {
                IconButton(systemImage: "plus.rectangle.on.rectangle", help: "Copy to New Query", tint: .accentColor) {
                    app.openQuery(text: code)
                }
                Menu {
                    let target = app.activeQueryTab
                    Section(target.map { "Into \($0.title)" } ?? "No query editor open") {
                        ForEach(EditorInsertMode.allCases) { mode in
                            Button {
                                target?.insert(code, mode: mode)
                                if let target { app.select(target) }
                            } label: {
                                Label(mode.title, systemImage: mode.systemImage)
                            }
                            .disabled(target == nil || !(target?.canInsert(mode) ?? false))
                        }
                    }
                    Divider()
                    Button("Copy to New Query") { app.openQuery(text: code) }
                    Button("Copy") { copy() }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 12)).foregroundStyle(Color.accentColor)
                        .frame(width: 22, height: 20)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More Options")
            }
            IconButton(systemImage: copied ? "checkmark" : "doc.on.doc", help: "Copy", tint: copied ? .green : .accentColor) { copy() }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

enum SQLSyntax {
    static func highlight(_ sql: String) -> AttributedString {
        var result = AttributedString(sql)
        let ns = sql as NSString
        let rules: [(String, NSRegularExpression.Options, Color)] = [
            ("\\b(" + SQLKeywords.all.joined(separator: "|") + ")\\b", .caseInsensitive, Color(nsColor: .systemPink)),
            ("\\b\\d+(\\.\\d+)?\\b", [], Color(nsColor: .systemBlue)),
            ("'(?:[^']|'')*'?", [], Color(nsColor: .systemRed)),
            ("--[^\\n]*", [], .secondary),
        ]
        for (pattern, options, color) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { continue }
            for match in regex.matches(in: sql, range: NSRange(location: 0, length: ns.length)) {
                guard let range = Range(match.range, in: sql),
                      let lower = AttributedString.Index(range.lowerBound, within: result),
                      let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
                result[lower..<upper].foregroundColor = color
            }
        }
        return result
    }
}
