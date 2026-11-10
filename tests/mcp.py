#!/usr/bin/env python3
"""Tests for bin/ask-agent-mcp: nvim --headless --clean is not needed, so run
this with python3 (tests/run.sh does it when python3 exists)."""

import importlib.util
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_loader(
    "ask_agent_mcp", importlib.machinery.SourceFileLoader("ask_agent_mcp", os.path.join(ROOT, "bin", "ask-agent-mcp"))
)
mcp = importlib.util.module_from_spec(spec)
sys.modules["ask_agent_mcp"] = mcp
spec.loader.exec_module(mcp)

seen = []


def fake_call(action, **args):
    seen.append((action, args))
    return {"ok": True, "action": action, "echo": args}


init = mcp.respond({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
assert init["result"]["protocolVersion"] == mcp.PROTOCOL, "protocol version"
assert init["result"]["capabilities"] == {"tools": {}}, "capabilities"

tools = mcp.respond({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})["result"]["tools"]
names = [t["name"] for t in tools]
assert names == ["agents", "ask", "task", "result", "status"], names
for t in tools:
    assert t["description"] and t["inputSchema"]["type"] == "object", t["name"]

assert mcp.respond({"jsonrpc": "2.0", "method": "notifications/initialized"}) is None, "notification is silent"

res = mcp.respond(
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "ask", "arguments": {"text": "hi"}}},
    call=fake_call,
)
payload = json.loads(res["result"]["content"][0]["text"])
assert payload["ok"] and seen[-1] == ("ask", {"text": "hi", "backend": None, "target": None, "correlation": None}), seen
assert "isError" not in res["result"]

res = mcp.respond(
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "status", "arguments": {}}},
    call=fake_call,
)
assert json.loads(res["result"]["content"][0]["text"])["ok"]

res = mcp.respond(
    {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "nope", "arguments": {}}},
    call=fake_call,
)
assert res["result"]["isError"] and "unknown tool" in res["result"]["content"][0]["text"]

err = mcp.respond({"jsonrpc": "2.0", "id": 7, "method": "whatever"})
assert err["error"]["code"] == -32601, err

# no nvim at all: tools answer with an error instead of crashing
missing = mcp.bridge_call("status", sock="/nonexistent/sock")
assert not missing["ok"] and "failed" in missing["error"], missing

print("MCP OK")
