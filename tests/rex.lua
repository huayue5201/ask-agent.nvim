-- Headless: nvim --headless --clean -l tests/rex.lua
-- The event stream is parsed here; nothing is spawned, so this runs without rex.
vim.opt.runtimepath:prepend(".")

local rex = require("ask_agent.status.rex")

local line =
	'{"type":"session_event","payload":{"session_id":"s","event":{"type":"terminal.program_status_changed","payload":{"id":"","record":{"state":"blocked","kind":"permission","msg":"run tests?"},"reason":"report"}}}}'
local ev = rex.parse_line(line)
assert(ev and ev.type == "terminal.program_status_changed", "event type")
assert(ev.payload.record.state == "blocked" and ev.payload.record.kind == "permission", "record survives parsing")

assert(rex.parse_line("not json") == nil, "garbage line")
assert(rex.parse_line('{"type":"reply"}') == nil, "non-session event")
assert(rex.parse_line('{"type":"session_event","payload":{}}') == nil, "session event without an event")

rex.invalidate() -- must not throw with an empty cache

print("REX OK")
