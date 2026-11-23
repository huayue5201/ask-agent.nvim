-- tests/deck.lua — the HTTP backend for a StudyDeck instance
-- Run from the repo root: nvim --headless --clean -l tests/deck.lua
-- Covers: handshake parsing (port/pid/api/caps/token), process liveness, target
-- listing, request shape (Authorization, -f), SSE outcomes (answer / HTTP error /
-- in-stream error / truncated stream / cancelled), the working -> done edge, a
-- superseded send, cancel, and a curl that cannot be spawned.
--
-- Nothing here touches a network: `deck._spawn` is replaced with a recorder that
-- hands the test the curl callback. That is also why the real vim.system is never
-- called — the "fresh backend is idle" probe would otherwise curl 127.0.0.1.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local deck = require("ask_agent.backends.deck")

-- Redirect the data dir into a temp root: the real app must never be touched.
local root = vim.fn.tempname() .. "-deck"
vim.fn.mkdir(root, "p")
local saved = { HOME = vim.env.HOME, XDG_DATA_HOME = vim.env.XDG_DATA_HOME }
vim.env.HOME = root
vim.env.XDG_DATA_HOME = root
local dir = deck.dir()

---Recorded curl invocations: { args, cb }
local calls = {}
deck._spawn = function(args, _, cb)
	table.insert(calls, { args = args, cb = cb })
	return {}
end

local function last_call()
	return calls[#calls]
end

---Run vim.schedule callbacks (the backend always hops back to the main loop).
local function flush()
	vim.wait(200, function()
		return false
	end)
end

---A curl result as vim.system would hand it over.
local function res(code, stdout, stderr)
	return { code = code, stdout = stdout or "", stderr = stderr or "" }
end

---An SSE body the way the app writes it: id + data per event, blank line between.
local function sse(events)
	local out = {}
	for i, ev in ipairs(events) do
		out[#out + 1] = ("id: %d\ndata: %s\n\n"):format(i, vim.json.encode(ev))
	end
	return table.concat(out)
end

local function started(turn, session)
	return { type = "turn_started", turn_id = turn, session_id = session }
end

-- 1. no handshake = the app is not running, and the backend is unusable (not broken)
assert(deck.needs_source == true, "deck asks the context layer for anchor source")
assert(deck.handshake() == nil, "no file = nil")
assert(deck.port() == nil, "no port file = nil")
assert(#deck.targets() == 0, "no target without a port")
local ok, why = deck.available()
assert(ok == false and type(why) == "string", "unavailable with a reason, got " .. tostring(why))
assert(deck.supports("turns") == false, "no capabilities without a handshake")

-- 2. a handshake = one target, with capabilities and a token
vim.fn.mkdir(dir, "p")
local pid = vim.uv.os_getpid()
vim.fn.writefile({
	('{"port":61337,"pid":%d,"api":2,"caps":["turns","events","cancel"],"token":"t0ken"}'):format(pid),
}, dir .. "/port")

local hs = deck.handshake()
assert(hs and hs.port == 61337 and hs.pid == pid, "handshake carries port and pid")
assert(hs.api == 2, "api version parsed")
assert(hs.caps.turns and hs.caps.events and not hs.caps.glossary, "caps become a set")
assert(hs.token == "t0ken", "token parsed")
assert(deck.supports("turns") == true and deck.supports("glossary") == false, "supports()")

local targets = deck.targets()
assert(#targets == 1, "one deck instance")
local t = targets[1]
assert(t.id == "deck" and t.port == 61337 and t.cwd == vim.fn.getcwd(), "target shape")

-- 3. a stale handshake from a dead process is not a running app
vim.fn.writefile({ '{"port":61337,"pid":999999,"api":2,"caps":[]}' }, dir .. "/port")
assert(deck.port() == nil, "dead pid = not running")
assert(#deck.targets() == 0, "no target when the process is gone")
local probing_dead = deck.probe(t)
assert(probing_dead.running == false, "a dead app is not running")
vim.fn.writefile({
	('{"port":61337,"pid":%d,"api":2,"caps":["turns"],"token":"t0ken"}'):format(pid),
}, dir .. "/port")

-- 4. state passthrough: working / done are what the app tells us, idle is the floor
assert(deck.probe(t).state == "idle", "fresh backend is idle")
deck._inflight[deck._key(t)] = { state = "working", ts = os.time() }
assert(deck.probe(t).state == "working", "working while streaming")
deck._inflight[deck._key(t)] = { state = "done", ts = os.time() }
assert(deck.probe(t).state == "done", "done is reported explicitly, not inferred")

-- 5. an error is reported once, then does not stick
deck._inflight[deck._key(t)] = { state = "error", msg = "curl: (7) connection refused" }
local err = deck.probe(t)
assert(err.state == "error" and err.msg:match("refused"), "error surfaced with its message")
assert(deck.probe(t).state == "idle", "error cleared after reporting")
deck._inflight[deck._key(t)] = nil

-- 6. delivery: the request carries the token, -f (so 4xx/5xx are failures) and the JSON body
calls = {}
assert(deck.send(t, "hello", { task_id = "task-1" }) == true, "send starts the request")
local call = last_call()
local args = table.concat(call.args, " ")
assert(args:find("POST", 1, true) and args:find("/api/ask", 1, true), "POST /api/ask")
assert(args:find("Authorization: Bearer t0ken", 1, true), "bearer token from the handshake")
assert(args:find("--fail%-with%-body", 1), "--fail-with-body makes HTTP errors fatal while keeping the body")
assert(args:find("curl", 1, true), "request runs through curl")
assert(deck.probe(t).state == "working", "working while the answer streams")

-- 7. a successful stream: deltas are folded into the answer, done ends it
call.cb(res(0, sse({
	started("turn-1", "sess-1"),
	{ type = "assistant_start", message_id = "m1" },
	{ type = "delta", text = "你" },
	{ type = "delta", text = "好" },
	{ type = "done", usage = { prompt_tokens = 1, completion_tokens = 2 } },
	{ type = "end" },
})))
flush()
assert(deck.probe(t).state == "done", "done after the stream ended")
assert(deck._inflight[deck._key(t)].answer == "你好", "deltas folded into the answer")
assert(deck._inflight[deck._key(t)].turn == "turn-1", "turn id remembered for cancel")

-- 8. an HTTP error is an error, not a quiet idle (the old -sS bug)
deck.send(t, "q", { task_id = "task-2" })
last_call().cb(res(500, '{"error":"模型挂了"}', ""))
flush()
local http_err = deck.probe(t)
assert(http_err.state == "error" and http_err.msg == "模型挂了", "HTTP error surfaces the JSON body")
assert(deck.probe(t).state == "idle", "then falls back to idle")

-- 9. an error event inside a 200 stream is an error too
deck.send(t, "q", { task_id = "task-3" })
last_call().cb(res(0, sse({ started("turn-3", "sess-1"), { type = "error", message = "max tokens" }, { type = "end" } })))
flush()
local stream_err = deck.probe(t)
assert(stream_err.state == "error" and stream_err.msg:match("max tokens"), "in-stream error")

-- 10. a stream that ends without `end` is truncated, not finished
deck.send(t, "q", { task_id = "task-4" })
last_call().cb(res(0, sse({ started("turn-4", "sess-1"), { type = "delta", text = "half" } })))
flush()
local truncated = deck.probe(t)
assert(truncated.state == "error" and truncated.msg:match("连接中断"), "truncated stream")

-- 11. a cancelled stream is not a failure
deck.send(t, "q", { task_id = "task-5" })
last_call().cb(res(0, sse({ started("turn-5", "sess-1"), { type = "cancelled", reason = "user" }, { type = "end" } })))
flush()
local cancelled = deck.probe(t)
assert(cancelled.state == "idle" and cancelled.msg == "已取消", "cancel reads as idle + 已取消")

-- 12. one turn per target: the app would reject the second (409), so refuse early
deck.send(t, "first", { task_id = "task-6" })
local first = last_call()
local busy_ok, busy_err = deck.send(t, "second", { task_id = "task-7" })
assert(busy_ok == false and busy_err:match("上一轮还在运行"), "a second send is refused while one runs")
assert(last_call() == first, "no second request was made")
first.cb(res(0, sse({ started("turn-6", "sess-1"), { type = "delta", text = "old" }, { type = "end" } })))
flush()
assert(deck.probe(t).state == "done", "the live send finishes")

-- 13. cancel uses the remembered turn
local cancel_ok, cancel_err
deck.cancel(t, function(done, reason)
	cancel_ok, cancel_err = done, reason
end)
assert(cancel_ok == nil and cancel_err == nil, "cancel is async")
local post = last_call()
assert(table.concat(post.args, " "):find("/api/turns/turn-6/cancel", 1, true), "cancels the running turn")
post.cb(res(0, '{"ok":true,"state":"cancelling"}'))
flush()
assert(cancel_ok == true and cancel_err == nil, "cancel callback reports success")

-- 14. cancel without a remembered turn asks the app which turn is running
deck._inflight[deck._key(t)] = nil
calls = {}
local scoped = { id = "deck", cwd = t.cwd, session_id = "sess-9" }
assert(deck.cancel(scoped, function() end) == true, "cancel starts a lookup")
local lookup = last_call()
assert(table.concat(lookup.args, " "):find("/api/turns?active=1", 1, true), "looks up active turns")
lookup.cb(res(0, '{"turns":[{"id":"turn-9","session_id":"sess-9","state":"running"}]}'))
flush()
local cancel_call = last_call()
assert(table.concat(cancel_call.args, " "):find("/api/turns/turn-9/cancel", 1, true), "cancels the app-side turn")

-- 15. a backend that cannot cancel says so instead of pretending
local backends = require("ask_agent.backends")
backends.register({
	id = "nocancel",
	label = "nocancel",
	targets = function()
		return { { id = "x", label = "x" } }
	end,
	send = function()
		return true
	end,
})
local api = require("ask_agent")
local no_cancel, no_cancel_err = api.cancel({ backend = "nocancel", id = "x" })
assert(no_cancel == false and tostring(no_cancel_err):match("不支持取消"), "unsupported cancel is a clear error")

-- 16. curl missing: the send fails with a message, it does not throw out of send()
deck._spawn = function()
	error("ENOENT: no such file or directory (curl)")
end
local thrown_ok = pcall(function()
	deck.send(t, "q", { task_id = "task-8" })
end)
assert(thrown_ok, "send never throws when curl cannot start")
flush()
local spawn_err = deck.probe(t)
assert(spawn_err.state == "error" and spawn_err.msg:match("ENOENT"), "spawn failure is reported")

-- 17. nothing to deliver to is a hard refusal
vim.fn.delete(dir .. "/port")
local never, never_err = deck.send({ id = "deck", cwd = "/tmp" }, "hello")
assert(never == false and never_err:match("没在运行"), "refuses when the app is not running")

vim.env.HOME = saved.HOME
vim.env.XDG_DATA_HOME = saved.XDG_DATA_HOME
vim.fn.delete(root, "rf")

print("OK")
