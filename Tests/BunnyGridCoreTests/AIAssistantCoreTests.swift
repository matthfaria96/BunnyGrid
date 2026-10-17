import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct MarkdownParserTests {
    @Test func parsesCommonBlocks() {
        let text = """
            ## Plan
            First **step** here
            continues.

            - one
              more
            - two
              - nested
            1. first
            2) second

            > quoted
            > line

            | id | name |
            |---:|------|
            | 1 | Ana |
            | 2 |

            ---
            ```sql
            SELECT 1;
            ```
            """
        #expect(MarkdownParser.parse(text) == [
            .heading(level: 2, text: "Plan"),
            .paragraph("First **step** here\ncontinues."),
            .listItem(ordinal: nil, depth: 0, text: "one more"),
            .listItem(ordinal: nil, depth: 0, text: "two"),
            .listItem(ordinal: nil, depth: 1, text: "nested"),
            .listItem(ordinal: 1, depth: 0, text: "first"),
            .listItem(ordinal: 2, depth: 0, text: "second"),
            .quote("quoted\nline"),
            .table(header: ["id", "name"], rows: [["1", "Ana"], ["2", ""]]),
            .rule,
            .code(language: "sql", body: "SELECT 1;", isClosed: true),
        ])
    }

    @Test func unterminatedFenceStaysCodeWhileStreaming() {
        #expect(MarkdownParser.parse("Here:\n```sql\nSELECT *\nFROM t") == [
            .paragraph("Here:"),
            .code(language: "sql", body: "SELECT *\nFROM t", isClosed: false),
        ])
    }

    @Test func sqlBlocksSkipOtherLanguages() {
        let text = "```python\nprint(1)\n```\n```\nSELECT 1;\n```\n```postgresql\nSELECT 2;\n```"
        #expect(MarkdownParser.sqlBlocks(in: text) == ["SELECT 1;", "SELECT 2;"])
    }

    @Test func hashWithoutSpaceIsNotAHeading() {
        #expect(MarkdownParser.parse("#temp table") == [.paragraph("#temp table")])
    }
}

@Suite struct LineDiffTests {
    @Test func marksAddedAndRemovedLines() {
        let lines = LineDiff.diff(old: "SELECT *\nFROM t\nWHERE a = 1", new: "SELECT id\nFROM t\nWHERE a = 1\nLIMIT 10")
        #expect(lines.map(\.kind) == [.removed, .added, .same, .same, .added])
        #expect(lines.first?.text == "SELECT *")
        #expect(LineDiff.hasChanges(lines))
    }

    @Test func ignoresTrailingWhitespace() {
        #expect(!LineDiff.hasChanges(LineDiff.diff(old: "SELECT 1;  ", new: "SELECT 1;")))
    }
}

@Suite struct AIPromptTests {
    private let context = AIRequestContext(engine: "PostgreSQL", serverVersion: "17.2", selectedText: "", allText: "SELECT * FROM t",
                                           schemaDescription: "t(id int4, name text)")

    @Test func builtinUsesWholeEditorWithoutSelection() {
        let prompt = AIPrompts.builtin(.optimize, context: context)
        #expect(prompt.contains("<sql>\nSELECT * FROM t\n</sql>"))
        #expect(prompt.contains("Engine: PostgreSQL 17.2"))
        #expect(prompt.contains("t(id int4, name text)"))
        #expect(prompt.contains("single ```sql code block"))
        #expect(!AIPrompts.builtin(.explain, context: context).contains("single ```sql code block"))
    }

    @Test func builtinPrefersSelection() {
        var selected = context
        selected.selectedText = "SELECT 1"
        #expect(AIPrompts.builtin(.beautify, context: selected).contains("<sql>\nSELECT 1\n</sql>"))
    }

    @Test func convertAndFixCarryTheirInputs() {
        #expect(AIPrompts.builtin(.convert, context: context, targetEngine: "MySQL", targetVersion: "8.4").contains("to MySQL 8.4"))
        #expect(AIPrompts.builtin(.fixError, context: context, errorMessage: "relation \"t\" does not exist").contains("relation \"t\" does not exist"))
    }

    @Test func customActionSendsOnlyChosenContext() {
        let action = AIAction(prompt: "Add a LIMIT", format: .naturalLanguage, context: [.allText])
        let prompt = AIPrompts.custom(action, context: context)
        #expect(prompt.contains("<editor_text>\nSELECT * FROM t\n</editor_text>"))
        #expect(!prompt.contains("t(id int4"))
        #expect(!prompt.contains("17.2"))
        #expect(prompt.hasSuffix("Add a LIMIT"))
    }

    @Test func extractsCodeFromReply() {
        #expect(AIPrompts.extractCode(from: "Sure:\n```sql\nSELECT 1;\n```\nDone") == "SELECT 1;")
        #expect(AIPrompts.extractCode(from: "  SELECT 2;\n") == "SELECT 2;")
    }

    @Test func optionsShapeRequests() {
        let options = AIRequestOptions(maxTokens: 2_000, effort: .high, instruction: "Answer in Portuguese.")
        let claude = AnthropicClient.requestBody(model: .opus, system: "Base", messages: [], options: options)
        #expect(claude["max_tokens"] == .int(2_000))
        #expect(claude["output_config"]?["effort"]?.stringValue == "high")
        #expect(claude["system"]?.stringValue?.hasSuffix("Answer in Portuguese.") == true)
        #expect(claude["temperature"] == nil)

        let openAI = OpenAIClient.requestBody(model: "gpt-6-astra", instructions: "Base", input: [], options: options)
        #expect(openAI["max_output_tokens"] == .int(2_000))
        #expect(openAI["reasoning"]?["effort"]?.stringValue == "high")
        let plain = OpenAIClient.requestBody(model: "gpt-6-astra", instructions: "Base", input: [])
        #expect(plain["reasoning"] == nil)
        #expect(plain["max_output_tokens"] == nil)
    }
}

@Suite struct EngineLabelTests {
    @Test func avoidsRepeatingTheEngineName() {
        #expect(AIPrompts.engineLabel(engine: "SQLite", version: "SQLite 3.54.0") == "SQLite 3.54.0")
        #expect(AIPrompts.engineLabel(engine: "PostgreSQL", version: "17.2") == "PostgreSQL 17.2")
        #expect(AIPrompts.engineLabel(engine: "MySQL", version: "") == "MySQL")
    }
}

@Suite struct AssistantConfigTests {
    @Test func defaultsComeFromTheProvider() {
        let claude = AIAssistantConfig(provider: .claude)
        #expect(claude.name == "Claude")
        #expect(claude.model == "claude-opus-5-5")
        #expect(claude.baseURL.absoluteString == "https://api.anthropic.com")
        let gpt = AIAssistantConfig(name: "Work GPT", provider: .chatGPT, apiHost: "  ", maxTokens: 900, effort: .low)
        #expect(gpt.baseURL.absoluteString == "https://api.openai.com")
        #expect(gpt.options == AIRequestOptions(maxTokens: 900, effort: .low))
        #expect(AIProvider.chatGPT.menuTitle == "OpenAI ChatGPT")
    }

    @Test func roundTripsAsJSON() throws {
        let config = AIAssistantConfig(provider: .chatGPT, apiHost: "https://proxy.example.com", instruction: "Be brief")
        let decoded = try JSONDecoder().decode(AIAssistantConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
    }
}
