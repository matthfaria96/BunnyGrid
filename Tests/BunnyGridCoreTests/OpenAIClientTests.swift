import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct OpenAIClientTests {
    private func run(_ raw: String) throws -> (events: [AssistantStreamEvent], turn: AssistantTurn) {
        var parser = SSEParser()
        var accumulator = ResponseAccumulator()
        var events: [AssistantStreamEvent] = []
        for line in raw.components(separatedBy: "\n") + [""] {
            if let event = parser.feed(line) { events += try accumulator.apply(event) }
        }
        return (events, accumulator.turn)
    }

    @Test func requestBodyStreamsWithoutStoring() {
        let body = OpenAIClient.requestBody(model: "gpt-6-astra", instructions: "Be brief.", input: [])
        #expect(body["model"]?.stringValue == "gpt-6-astra")
        #expect(body["instructions"]?.stringValue == "Be brief.")
        #expect(body["stream"] == .bool(true))
        #expect(body["store"] == .bool(false))
        #expect(body["input"] == .array([]))
    }

    @Test func historyKeepsOnlyText() {
        let messages: [JSONValue] = [
            .object(["role": .string("user"), "content": .array([.object(["type": .string("text"), "text": .string("List tables")])])]),
            .object(["role": .string("assistant"), "content": .array([
                .object(["type": .string("thinking"), "thinking": .string("…"), "signature": .string("sig")]),
                .object(["type": .string("text"), "text": .string("SELECT 1;")]),
            ])]),
            .object(["role": .string("assistant"), "content": .array([.object(["type": .string("thinking"), "thinking": .string("x")])])]),
        ]
        #expect(OpenAIClient.input(fromMessages: messages) == [
            .object(["role": .string("user"), "content": .string("List tables")]),
            .object(["role": .string("assistant"), "content": .string("SELECT 1;")]),
        ])
    }

    @Test func accumulatesTextDeltas() throws {
        let raw = """
            event: response.created
            data: {"type":"response.created","response":{"id":"resp_1","model":"gpt-6-astra-2026-09-03","status":"in_progress"}}

            event: response.output_text.delta
            data: {"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"SELECT "}

            event: response.output_text.delta
            data: {"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"1;"}

            event: response.completed
            data: {"type":"response.completed","response":{"id":"resp_1","model":"gpt-6-astra-2026-09-03","status":"completed"}}
            """
        let (events, turn) = try run(raw)
        #expect(events.count == 2)
        #expect(turn.text == "SELECT 1;")
        #expect(turn.model == "gpt-6-astra-2026-09-03")
        #expect(turn.stopReason == "end_turn")
        #expect(turn.echoContent == [.object(["type": .string("text"), "text": .string("SELECT 1;")])])
    }

    @Test func refusalAndIncomplete() throws {
        let refused = try run("""
            data: {"type":"response.refusal.delta","delta":"I can't help with that."}

            data: {"type":"response.completed","response":{"model":"gpt-6-luna"}}
            """).turn
        #expect(refused.wasRefused)
        #expect(refused.text == "I can't help with that.")

        let cut = try run("""
            data: {"type":"response.output_text.delta","delta":"SELECT"}

            data: {"type":"response.incomplete","response":{"model":"gpt-6-luna","incomplete_details":{"reason":"max_output_tokens"}}}
            """).turn
        #expect(cut.stopReason == "max_tokens")
    }

    @Test func failuresThrow() {
        #expect(throws: OpenAIError.self) {
            try run(#"data: {"type":"response.failed","response":{"error":{"code":"server_error","message":"boom"}}}"#)
        }
        #expect(throws: OpenAIError.self) {
            try run(#"data: {"type":"error","code":"slow_down","message":"Slow down"}"#)
        }
    }

    @Test func modelListKeepsChatModels() {
        let ids = ["gpt-6-luna", "gpt-image-2", "gpt-realtime-2", "text-embedding-3-large", "gpt-5.5", "gpt-6-astra",
                   "o4-mini", "gpt-transcribe", "whisper-1", "gpt-6.1-sol", "gpt-5.6-terra", "omni-moderation-latest"]
        let options = OpenAIModels.options(from: ids)
        #expect(options.map(\.id) == ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna", "o4-mini", "gpt-5.6-terra", "gpt-5.5"])
        #expect(OpenAIModels.options(from: []).map(\.id) == OpenAIModels.suggested.map(\.id))
    }

    @Test func providerDefaults() {
        #expect(AIProvider.claude.defaultModel == "claude-opus-5-5")
        #expect(AIProvider.chatGPT.defaultModel == "gpt-6-astra")
        #expect(AIProvider(rawValue: "chatgpt") == .chatGPT)
        #expect(AIProvider.claude.keychainService == "app.bunnygrid.anthropic")
    }
}
