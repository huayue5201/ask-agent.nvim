-- Headless: nvim --headless --clean -l tests/chat.lua
-- The log is the truth: mentions route, cursors keep the projection small, a busy
-- target queues instead of interleaving.
vim.opt.runtimepath:prepend(".")

local backends = require("ask_agent.backends")
local state = require("ask_agent.state")
local chat = require("ask_agent.chat")
local aliases = require("ask_agent.aliases")

state.notify = false
state.persist = false
aliases.setup({ file = "/tmp/ask-agent-chat-aliases.json" })
vim.fn.delete("/tmp/ask-agent-chat-aliases.json")

chat.persist = true
chat.journal_path = "/tmp/ask-agent-chat-test.json"
vim.fn.delete(chat.journal_path)

---@type { target: table, text: string }[]
local sent = {}

backends.register({
	id = "group",
	label = "Group",
	targets = function()
		return {
			{ id = "c1", cwd = "/repo", label = "claude" },
			{ id = "x1", cwd = "/repo", label = "codex" },
		}
	end,
	probe = function()
		return { running = true, state = "working" }
	end,
	available = function()
		return true
	end,
	send = function(target, text)
		sent[#sent + 1] = { target = target, text = text }
		return true
	end,
})

local names = chat.names()
assert(names["claude"] and names["claude"][1].key == "group:c1", "the label names a target")
assert(names["codex"] and names["codex"][1].key == "group:x1")
assert(chat.resolve("@claude").key == "group:c1", "a leading @ is accepted")
assert(chat.resolve("nobody") == nil, "unknown names do not resolve")

-- a message with no mention is a plain record
local tid = chat.thread("main")
local e1 = chat.post("just thinking out loud")
assert(e1.kind == "msg" and e1.author == "user", "a plain message is logged")
assert(#sent == 0, "nothing was dispatched without a mention")

-- a mention routes one task whose prompt carries the cleaned text
local e2 = chat.post("@claude 把映射改成 J")
assert(#sent == 1, "one task")
assert(sent[1].target.id == "c1", "sent to the named target")
assert(sent[1].text:find("把映射改成 J", 1, true), "the question travels")
assert(not sent[1].text:find("@claude", 1, true), "the mention itself is stripped")
assert(sent[1].text:find('<chat thread="main">', 1, true), "the projection is attached")
assert(e2.text == "@claude 把映射改成 J", "the log keeps what the human wrote, mention included")

-- unknown and ambiguous mentions are reported, not silently dropped
chat.post("@ghost hello")
local last = chat.entries(tid)[#chat.entries(tid)]
assert(last.kind == "system" and last.text:find("no agent answers", 1, true), "unknown target is reported")

-- a busy target queues: same target twice is one running task plus a note
local e3 = chat.post("@claude 顺便看看测试")
assert(#sent == 1, "still one task in flight")
local notes = chat.entries(tid)
local queued = notes[#notes]
assert(queued.kind == "system" and queued.text:find("queued", 1, true), "the second mention waits")
assert(chat.pending()[1]:find("group:c1", 1, true), "the queue is visible")

-- finishing captures the answer, logs it, and starts the queued task
chat.capture = function()
	return "\n\n  the mapping reads J now  \n\n"
end
local result = chat.finish("group:c1", "done")
assert(result.kind == "result" and result.author == "agent", "the answer is logged")
assert(result.text == "the mapping reads J now", "captured text is tidied")
assert(#sent == 2, "the queued task started")
assert(chat.pending()[1] == nil, "the queue drained")
chat.finish("group:c1", "done")

-- pinned facts always travel; an agent never sees its own results again
chat.pin(tid, "映射最终用 J")
sent = {}
chat.post("@codex 你看下有没有坑")
assert(#sent == 1)
local payload = sent[1].text
assert(payload:find("facts:", 1, true), "pins are a section")
assert(payload:find("- 映射最终用 J", 1, true), "the pinned fact travels")
assert(payload:find("你 看下", 1, true) or payload:find("看下有没有坑", 1, true), "the question travels")

-- the projection is bounded by the window, oldest first
chat.window = 2
chat.post("@claude one")
chat.post("@claude two")
chat.post("@claude three")
chat.finish("group:c1", "done")
chat.finish("group:c1", "done")
chat.finish("group:c1", "done")
local context = chat.context_text(tid, "group:x1")
local lines = vim.split(context, "\n", { plain = true })
local recent = 0
for _, l in ipairs(lines) do
	if l:match("^%[#%d+%]") then
		recent = recent + 1
	end
end
assert(recent <= 2, "the window bounds the projection, got " .. recent)

-- tidy keeps the tail, not the head, so a long answer does not get truncated away
local long = {}
for i = 1, 100 do
	long[i] = "line " .. i
end
local tidy = chat.tidy(table.concat(long, "\n"), 5)
assert(tidy:find("line 100", 1, true), "the tail survives")
assert(tidy:find("line 96", 1, true) and not tidy:find("line 95", 1, true), "exactly the tail")

-- persistence: the log is a file with threads, pins and cursors
chat.flush()
local raw = table.concat(vim.fn.readfile(chat.journal_path), "\n")
local ok, data = pcall(vim.json.decode, raw)
assert(ok and data.threads[tid], "the journal has the thread")
assert(data.threads[tid].pins[1] == "映射最终用 J", "pins persist")
assert(data.threads[tid].cursors["group:x1"], "cursors persist")
local kinds = {}
for _, e in ipairs(data.threads[tid].entries) do
	kinds[e.kind] = true
end
assert(kinds.msg and kinds.result and kinds.system, "every kind survives")

-- an id and a name both address the same thread (the window passes ids)
local tid = chat.thread("by-name")
chat.post("first", { thread = tid })
chat.post("second", { thread = "by-name" })
assert(#chat.get(tid).entries == 2, "an id posts into the thread it names, got " .. #chat.get(tid).entries)
assert(#chat.list() == 2, "no duplicate thread was created under the id, got " .. #chat.list())

-- several agents sharing a name get stable suffixes instead of "ambiguous"
backends.register({
	id = "twin",
	label = "Twin",
	available = function()
		return true
	end,
	targets = function()
		return {
			{ id = "a1", cwd = "/repo", label = "dup" },
			{ id = "a2", cwd = "/repo", label = "dup" },
		}
	end,
	probe = function()
		return { running = false, state = "idle" }
	end,
	send = function()
		return true
	end,
})
local names = chat.names()
assert(names["dup"] and #names["dup"] == 2, "a shared name stays ambiguous")
assert(names["dup-2"] and #names["dup-2"] == 1, "the second agent is addressable as dup-2")
local seen, roster = {}, chat.roster()
for _, a in ipairs(roster) do
	assert(not seen[a.name], "roster names are unique: " .. a.name)
	seen[a.name] = true
end
assert(seen["dup-1"] and seen["dup-2"], "both twins are addressable in the roster")
local _, cands = chat.resolve("dup")
assert(
	#cands == 2 and cands[1] == "dup-1" and cands[2] == "dup-2",
	"the hint names both aliases, got " .. vim.inspect(cands)
)

-- an agent that exited is reported, not queued behind a bubble that never fills
backends.register({
	id = "ghostly",
	label = "Ghostly",
	available = function()
		return true
	end,
	targets = function()
		return { { id = "g1", cwd = "/repo", label = "gone-agent" } }
	end,
	probe = function()
		return { running = false, detail = "process exited" }
	end,
	send = function()
		error("must not send to a gone agent")
	end,
})
chat.post("@gone-agent hello", { thread = "main" })
local gone_last = chat.entries(chat.thread("main"))
gone_last = gone_last[#gone_last]
assert(gone_last.status == "error" and gone_last.text:find("the agent is gone", 1, true), "gone agent is reported")
assert(chat.running()["ghostly:g1"] == nil, "nothing is left running")

-- cancel gives up on tasks that never settle
chat.cancel("main")
assert(vim.tbl_count(chat.running()) == 0, "cancel clears the running table")

print("CHAT OK")
