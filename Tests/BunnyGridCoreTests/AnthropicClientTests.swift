import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct AnthropicStreamTests {
    private func run(_ raw: String) throws -> (events: [AssistantStreamEvent], turn: AssistantTurn) {
        var parser = SSEParser()
        var accumulator = MessageAccumulator()
        var events: [AssistantStreamEvent] = []
        for line in raw.components(separatedBy: "\n") + [""] {
            if let event = parser.feed(line) { events += try accumulator.apply(event) }
        }
        return (events, accumulator.turn)
    }

    @Test func accumulatesTextThinkingAndSignature() throws {
        let raw = """
            event: message_start
            data: {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5"}}

            event: content_block_start
            data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig=="}}

            event: content_block_start
            data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"SELECT "}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"1;"}}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

            event: message_stop
            data: {"type":"message_stop"}
            """
        let (events, turn) = try run(raw)
        #expect(events.count == 2)
        #expect(turn.text == "SELECT 1;")
        #expect(turn.model == "claude-opus-5-5")
        #expect(turn.stopReason == "end_turn")
        #expect(turn.echoContent == [
            .object(["type": .string("thinking"), "thinking": .string(""), "signature": .string("sig==")]),
            .object(["type": .string("text"), "text": .string("SELECT 1;")]),
        ])
    }

    @Test func dropsPreFallbackThinkingFromEcho() {
        let blocks: [[String: JSONValue]] = [
            ["type": .string("thinking"), "thinking": .string(""), "signature": .string("a")],
            ["type": .string("text"), "text": .string("partial ")],
            ["type": .string("fallback"), "from": .object(["model": .string("claude-opus-5-5")]), "to": .object(["model": .string("claude-opus-4-8")])],
            ["type": .string("thinking"), "thinking": .string(""), "signature": .string("b")],
            ["type": .string("text"), "text": .string("rest")],
        ]
        let echo = MessageAccumulator.echoContent(blocks)
        #expect(echo.count == 3)
        #expect(echo[0]["type"]?.stringValue == "text")
        #expect(echo[1]["signature"]?.stringValue == "b")
    }

    @Test func reportsFallbackAndRefusal() throws {
        let raw = """
            event: content_block_start
            data: {"type":"content_block_start","index":0,"content_block":{"type":"fallback","from":{"model":"a"},"to":{"model":"b"}}}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}
            """
        let (events, turn) = try run(raw)
        guard case .fallback(let from, let to) = events.first else {
            Issue.record("expected a fallback event")
            return
        }
        #expect(from == "a" && to == "b")
        #expect(turn.wasRefused)
    }

    @Test func streamErrorsThrow() {
        var accumulator = MessageAccumulator()
        #expect(throws: AnthropicError.self) {
            try accumulator.apply(.init(name: "error", data: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))
        }
    }

    @Test func requestBodyUsesFallbackOnlyWhereSupported() throws {
        let opus = AnthropicClient.requestBody(model: .opus, system: "s", messages: [])
        #expect(opus["fallbacks"]?.stringValue == "default")
        #expect(opus["model"]?.stringValue == "claude-opus-5-5")
        #expect(opus["output_config"]?["effort"]?.stringValue == "medium")
        #expect(opus["thinking"] == nil)
        let haiku = AnthropicClient.requestBody(model: .haiku, system: "s", messages: [])
        #expect(haiku["fallbacks"] == nil)
        let encoded = String(data: try JSONEncoder().encode(opus), encoding: .utf8) ?? ""
        #expect(encoded.contains("\"max_tokens\":64000"))
    }
}
