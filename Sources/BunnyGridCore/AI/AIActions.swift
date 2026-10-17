import Foundation

/// How hard the model thinks: Claude's `output_config.effort`, OpenAI's `reasoning.effort`.
/// (Current models no longer accept `temperature`.)
public enum AIEffort: String, CaseIterable, Codable, Sendable, Identifiable {
    case low, medium, high

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

/// Per-platform request settings from Settings › AI Assistant.
public struct AIRequestOptions: Codable, Sendable, Equatable {
    /// nil uses the platform default (64K output tokens for Claude, the model's limit for OpenAI).
    public var maxTokens: Int?
    public var effort: AIEffort
    /// Extra standing instructions appended to the system prompt ("Instruction" in Navicat).
    public var instruction: String

    public init(maxTokens: Int? = nil, effort: AIEffort = .medium, instruction: String = "") {
        self.maxTokens = maxTokens
        self.effort = effort
        self.instruction = instruction
    }

    public func system(_ base: String) -> String {
        let extra = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return extra.isEmpty ? base : base + "\n\nAdditional instructions from the user:\n" + extra
    }
}

public enum AIResponseFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case code
    case naturalLanguage

    public var id: String { rawValue }
    public var title: String { self == .code ? "Code" : "Natural Language" }
}

/// What a custom action sends along with the question.
public struct AIContextOptions: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let selectedText = AIContextOptions(rawValue: 1 << 0)
    public static let allText = AIContextOptions(rawValue: 1 << 1)
    public static let currentSchema = AIContextOptions(rawValue: 1 << 2)
    public static let serverVersion = AIContextOptions(rawValue: 1 << 3)
}

/// A saved "Ask AI" action from the query editor; pinned actions appear in the Ask AI menu.
public struct AIAction: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var prompt: String
    public var format: AIResponseFormat
    public var context: AIContextOptions
    public var isPinned: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), prompt: String, format: AIResponseFormat = .code,
                context: AIContextOptions = [.selectedText, .currentSchema, .serverVersion], isPinned: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.prompt = prompt
        self.format = format
        self.context = context
        self.isPinned = isPinned
        self.createdAt = createdAt
    }

    public var title: String {
        let line = prompt.split(separator: "\n").first.map(String.init) ?? prompt
        return line.count > 60 ? String(line.prefix(57)) + "…" : line
    }
}

/// The editor's built-in Ask AI actions and the error helpers.
public enum AIBuiltinAction: String, CaseIterable, Sendable, Identifiable {
    case explain, optimize, beautify, convert, fixError, explainError

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .explain: "Explain SQL"
        case .optimize: "Optimize SQL"
        case .beautify: "Beautify SQL"
        case .convert: "Convert SQL to Another Database Type"
        case .fixError: "Fix with AI"
        case .explainError: "Explain Error"
        }
    }

    public var format: AIResponseFormat {
        switch self {
        case .explain, .explainError: .naturalLanguage
        case .optimize, .beautify, .convert, .fixError: .code
        }
    }
}

/// Everything an Ask AI request can draw on.
public struct AIRequestContext: Sendable, Equatable {
    public var engine: String
    public var serverVersion: String
    public var selectedText: String
    public var allText: String
    /// `table(column type, …)` lines for the current schema, when available.
    public var schemaDescription: String

    public init(engine: String, serverVersion: String = "", selectedText: String = "", allText: String = "", schemaDescription: String = "") {
        self.engine = engine
        self.serverVersion = serverVersion
        self.selectedText = selectedText
        self.allText = allText
        self.schemaDescription = schemaDescription
    }

    /// The selection when there is one, otherwise the whole editor (what the default actions send).
    public var targetSQL: String {
        selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? allText : selectedText
    }
}

public enum AIPrompts {
    public static let systemPrompt = """
        You are the AI assistant inside BunnyGrid, a native macOS database client. You help the user \
        write, explain, optimize and fix SQL for the database they are connected to. Use the SQL dialect \
        of their engine. Put runnable SQL in fenced ```sql code blocks so it can be opened in the query \
        editor. Be concise; explain briefly what a query does and note assumptions about the schema. \
        A <database_context> block, when present, describes the user's current database, table or schema.
        """

    static let codeOnly = """
        Reply with only the complete resulting SQL in a single ```sql code block. Put any short notes \
        inside the SQL as -- comments; write nothing outside the code block.
        """

    public static func builtin(_ action: AIBuiltinAction, context: AIRequestContext,
                               targetEngine: String = "", targetVersion: String = "", errorMessage: String = "") -> String {
        let engine = engineLabel(context)
        let sql = context.targetSQL
        var parts: [String] = [databaseContext(context, includeSchema: true, includeVersion: true)]
        switch action {
        case .explain:
            parts.append("Explain what this \(engine) SQL does, clause by clause, and point out anything surprising, slow or risky.")
        case .optimize:
            parts.append("Rewrite this SQL to run more efficiently on \(engine) while returning exactly the same results. Mark each change with a short -- comment, and suggest any index it relies on as a comment.")
        case .beautify:
            parts.append("Reformat this SQL for readability: uppercase keywords, one clause per line, indented column lists, joins and subqueries. Do not change what it does.")
        case .convert:
            let target = [targetEngine, targetVersion].filter { !$0.isEmpty }.joined(separator: " ")
            parts.append("Convert this SQL from \(engine) to \(target.isEmpty ? "another database" : target). Keep the same behavior using the target's syntax, functions and types. Mark anything that has no equivalent with a -- comment.")
        case .fixError:
            parts.append("This SQL failed on \(engine) with the error below. Return the corrected SQL.\n<error>\n\(errorMessage)\n</error>")
        case .explainError:
            parts.append("Explain this error from \(engine): what it means, why this SQL caused it, and how to fix it.\n<error>\n\(errorMessage)\n</error>")
        }
        if action.format == .code { parts.append(codeOnly) }
        parts.append("<sql>\n\(sql)\n</sql>")
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    public static func custom(_ action: AIAction, context: AIRequestContext) -> String {
        var parts: [String] = [databaseContext(context, includeSchema: action.context.contains(.currentSchema),
                                               includeVersion: action.context.contains(.serverVersion))]
        if action.context.contains(.allText), !context.allText.isEmpty {
            parts.append("<editor_text>\n\(context.allText)\n</editor_text>")
        }
        if action.context.contains(.selectedText), !context.selectedText.isEmpty {
            parts.append("<selected_text>\n\(context.selectedText)\n</selected_text>")
        }
        parts.append(action.prompt)
        if action.format == .code { parts.append(codeOnly) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// "PostgreSQL 17.2"; versions that already start with the engine name ("SQLite 3.54") are used as they are.
    static func engineLabel(_ context: AIRequestContext) -> String {
        engineLabel(engine: context.engine, version: context.serverVersion)
    }

    public static func engineLabel(engine: String, version: String) -> String {
        if version.isEmpty { return engine }
        return version.lowercased().hasPrefix(engine.lowercased()) ? version : "\(engine) \(version)"
    }

    static func databaseContext(_ context: AIRequestContext, includeSchema: Bool, includeVersion: Bool) -> String {
        var lines: [String] = []
        if includeVersion { lines.append("Engine: \(engineLabel(context))") } else { lines.append("Engine: \(context.engine)") }
        if includeSchema, !context.schemaDescription.isEmpty { lines.append("Schema:\n" + context.schemaDescription) }
        return "<database_context>\n" + lines.joined(separator: "\n") + "\n</database_context>"
    }

    /// The SQL in a code-format reply: the first code block, or the reply itself without stray fences.
    public static func extractCode(from reply: String) -> String {
        for block in MarkdownParser.parse(reply) {
            if case .code(_, let body, _) = block { return body.trimmingCharacters(in: .newlines) }
        }
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
