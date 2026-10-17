"""Local stand-in for the Claude Messages API and the OpenAI Responses API (streaming), for UI scenarios.

Usage: python3 mock-ai.py PORT. Answers GET /v1/models, POST /v1/messages and POST /v1/responses with a short
reply that echoes the last user text ("Mock reply to: …") plus a fenced SQL block, as server-sent events.
Every request body is appended to requests.jsonl in the working directory, so a scenario can inspect it.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def last_user_text(body):
    messages = body.get("messages") or body.get("input") or []
    for message in reversed(messages):
        if message.get("role") != "user":
            continue
        content = message.get("content")
        if isinstance(content, str):
            return content
        for block in content or []:
            if isinstance(block, dict) and block.get("text"):
                return block["text"]
    return ""


def reply_for(body):
    text = last_user_text(body).strip().splitlines()
    question = text[-1] if text else ""
    return ["Mock reply to: " + question[:80] + "\n\n", "```sql\nSELECT name, email\n", "FROM customers\nLIMIT 5;\n```\n"]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        sys.stderr.write("mock-ai: " + (args[0] % args[1:]) + "\n")

    def send_json(self, payload, status=200):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.startswith("/v1/models"):
            self.send_json({"data": [{"id": "claude-opus-5-5", "type": "model"}, {"id": "gpt-6-astra", "object": "model"}], "has_more": False})
        else:
            self.send_json({"error": {"message": "not found"}}, 404)

    def events(self, events):
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        for name, payload in events:
            self.wfile.write(("event: %s\ndata: %s\n\n" % (name, json.dumps(payload))).encode())
            self.wfile.flush()
        self.close_connection = True

    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        with open("requests.jsonl", "a") as log:
            log.write(json.dumps({"path": self.path, "body": body}) + "\n")
        pieces = reply_for(body)
        if self.path.startswith("/v1/messages"):
            model = body.get("model", "claude-opus-5-5")
            events = [("message_start", {"type": "message_start", "message": {"id": "msg_mock", "model": model, "role": "assistant", "content": []}}),
                      ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})]
            events += [("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": p}}) for p in pieces]
            events += [("content_block_stop", {"type": "content_block_stop", "index": 0}),
                       ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"}}),
                       ("message_stop", {"type": "message_stop"})]
            self.events(events)
        elif self.path.startswith("/v1/responses"):
            model = body.get("model", "gpt-6-astra")
            events = [("response.created", {"type": "response.created", "response": {"model": model}})]
            events += [("response.output_text.delta", {"type": "response.output_text.delta", "delta": p}) for p in pieces]
            events += [("response.completed", {"type": "response.completed", "response": {"model": model}})]
            self.events(events)
        else:
            self.send_json({"error": {"message": "not found"}}, 404)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
