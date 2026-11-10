-- Headless: nvim --headless --clean -l tests/state.lua
-- Exercises the state layer: polling, completion inference, sticky done, priority,
-- statusline counts, correlation and rex overrides.
vim.opt.runtimepath:prepend(".")

-- rex is stubbed before state.lua loads it, so a target with `.rex` gets a blocking report
local watched = {}
package.loaded["ask_agent.status.rex"] = {
	available = function()
		return true
	end,
	query = function(_, cb)
		cb({ state = "blocked", kind = "permission", msg = "approve the patch" })
	end,
	watch = function(session)
		watched[session] = true
		return true
	end,
	unwatch = function(session)
		watched[session] = nil
	end,
	invalidate = function() end,
}

local backends = require("ask_agent.backends")
local state = require("ask_agent.state")

state.notify = false
-- never touch the user's journal from tests
state.persist = false

local targets = {
	{ id = "a", cwd = "/tmp", label = "A" },
	{ id = "b", cwd = "/tmp", label = "B" },
}
local probe_a = { running = true, state = "idle" }
local probe_b = { running = true, state = "idle" }

local mod = {
	id = "fake",
	label = "Fake",
	targets = function()
		return targets
	end,
	probe = function(t)
		return t.id == "a" and probe_a or probe_b
	end,
	available = function()
		return true
	end,
	send = function()
		return true
	end,
}

backends.register(mod)
state.refresh()
assert(state.get("fake:a").state == "idle", "first sighting is idle")
assert(#state.all() == 2, "both instances tracked")

-- working -> idle after our send = done (unread)
vim.wait(10)
probe_a = { running = true, state = "working" }
state.refresh()
assert(state.get("fake:a").state == "working", "busy marker becomes working")
state.dispatch("fake", "a", "review this", { correlation = { plugin = "todo2", key = "t1" } })
vim.wait(10)
probe_a = { running = true, state = "idle" }
state.refresh()
local a = state.get("fake:a")
assert(a.state == "done", "turn that ended after our send is done")
assert(a.unread, "done is unread")
assert(state.statusline() == "✓1", "statusline counts the finished turn: " .. state.statusline())
assert(#a.tasks == 1 and a.tasks[1].status == "done", "the sent turn is logged and marked done")
assert(a.tasks[1].text == "review this", "task text is the first line sent")

-- sticky: a source that only knows idle must not erase an unacknowledged done
state.refresh()
assert(state.get("fake:a").state == "done", "done survives later idle sightings")

-- correlation filter reaches the record that was sent with it
assert(#state.all({ correlation = { plugin = "todo2", key = "t1" } }) == 1, "correlation matches")
assert(#state.all({ correlation = { plugin = "todo2", key = "nope" } }) == 0, "unknown correlation")

-- ack clears the unread mark, and the next poll settles back to idle
state.ack("fake:a")
assert(state.statusline() == "", "acked done is not counted")
state.refresh()
assert(state.get("fake:a").state == "idle", "acked done falls back to idle")

-- rex beats a busy marker and blocked sorts first
targets[2].rex = { session = "s", block = "b" }
state.refresh()
vim.wait(20)
local b = state.get("fake:b")
assert(b.state == "blocked" and b.kind == "permission", "rex status wins")
assert(state.all()[1].key == "fake:b", "blocked first")
assert(state.statusline() == "⚠1", "blocked counted: " .. state.statusline())

-- events fire once per state change
local seen = {}
local off = state.on("state", function(rec, prev)
	seen[#seen + 1] = rec.key .. ":" .. tostring(prev) .. ">" .. rec.state
end)
probe_b = { running = true, state = "working" }
state.refresh()
vim.wait(20)
off()
assert(#seen > 0, "state event fired")

-- the state source is recorded: probe for tmux-style markers, rex for OSC 7501
assert(state.get("fake:a").source == "probe", "probe source: " .. tostring(state.get("fake:a").source))
assert(state.get("fake:b").source == "rex", "rex source: " .. tostring(state.get("fake:b").source))
assert(watched["s"], "rex events are streamed for the session the agents live in")

-- reply goes to the same instance, through the injected sender, and is logged as a reply
local sent = {}
state.sender = function(mod_, target, text, opts)
	sent[#sent + 1] = { backend = mod_.id, id = target.id, text = text, reply = opts and opts.reply }
	state.dispatch(mod_.id, target.id, text, opts)
	return true
end
local ok, err = state.reply("fake:b", "yes, go ahead")
assert(ok, "reply ok: " .. tostring(err))
assert(sent[1].id == "b" and sent[1].reply, "reply reached the blocked instance")
assert(state.get("fake:b").tasks[1].reply, "the reply is marked on the task")

-- result captures the last turn's output once and caches it
local jump = require("ask_agent.jump")
local captures = 0
jump.capture = function(_, cb)
	captures = captures + 1
	cb("all tests passed\nbuilt in 2s")
end
local got, rerr = nil, nil
state.result("fake:b", function(task, e)
	got, rerr = task, e
end)
vim.wait(20)
assert(
	rerr == nil and got and got.output:find("all tests passed"),
	"result returns the captured output: " .. tostring(rerr) .. " / " .. tostring(got and got.text)
)
state.result("fake:b", function()
	got = "second call"
end)
vim.wait(20)
assert(captures == 1, "output is cached, captured once")

-- heuristic completion is labelled as such
probe_a = { running = true, state = "working" }
state.refresh()
state.dispatch("fake", "a", "do it again")
vim.wait(10)
probe_a = { running = true, state = "idle" }
state.refresh()
assert(state.get("fake:a").state == "done", "inferred done")
assert(state.get("fake:a").source == "heuristic", "inferred done says so: " .. tostring(state.get("fake:a").source))

-- journal: tasks and unread marks come back after a restart
state.persist = true
state.journal_path = "/tmp/ask-agent-state-test/journal.json"
vim.fn.delete("/tmp/ask-agent-state-test", "rf")
state.flush()
local journal = table.concat(vim.fn.readfile(state.journal_path), "\n")
assert(journal:find("do it again", 1, true), "journal holds the task")
state.dismiss("fake:a")
assert(state.get("fake:a") == nil, "dismissed")
state.reload_journal()
state.refresh()
vim.wait(20)
local back = state.get("fake:a")
assert(back and back.tasks and back.tasks[1].text == "do it again", "journal restores the task")
state.persist = false

-- a vanished instance turns gone and drops out of the counters
targets = { targets[1] }
state.refresh()
assert(state.get("fake:b").gone, "unseen instance is gone")
assert(not state.statusline():find("⚠"), "gone blocked is not counted")

print("STATE OK")
