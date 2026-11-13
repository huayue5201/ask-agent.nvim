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
-- names come from here: never touch the user's aliases file from a test
require("ask_agent.aliases").setup({ file = "/tmp/ask-agent-aliases-state.json" })

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
-- acked done drops out; both agents are idle by now, so the chunk says exactly that
assert(not state.statusline():find("✓", 1, true), "acked done is not counted")
assert(state.statusline():match("^●%d+$"), "only idle left: " .. state.statusline())
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

-- a finished task older than task_ttl is pruned on save; the newest one is kept
state.persist = true
local rec = state.get("fake:a")
local old = state.now() - state.task_ttl - 60000
state.dispatch("fake", "a", "ancient", {})
state.dispatch("fake", "a", "recent", {})
for _, task in ipairs(rec.tasks) do
	if task.text == "ancient" then
		task.status, task.ts, task.finish = "done", old, old
	end
end
state.flush()
local saved = vim.json.decode(table.concat(vim.fn.readfile(state.journal_path), "\n"))
local texts = {}
for _, task in ipairs(saved.agents["fake:a"].tasks) do
	texts[task.text] = true
end
assert(texts.recent, "the newest task survives")
assert(not texts.ancient, "a stale finished task is pruned")

-- the id the agent got and the turn behind the send survive a restart: `o` and `v`
-- must keep working on tasks recorded before nvim was restarted
state.dispatch("fake", "a", "with ids", { task_id = "t-1", turn_id = "turn-9" })
state.flush()
state.dismiss("fake:a")
state.reload_journal()
state.refresh()
vim.wait(20)
local ids = assert(state.get("fake:a")).tasks[1]
assert(ids.task_id == "t-1" and ids.turn_id == "turn-9", "task id and turn id survive the journal")
assert(state.task_by_id("t-1") == ids, "task_by_id finds the task")
assert(state.attach_result("t-1", 1234).has_answer, "the answer flag attaches")
assert(state.task_by_id("t-1").answer_ts == 1234, "the answer keeps its timestamp")
-- the run ending is what closes a task: the state heuristic alone never fires when
-- the agent goes straight from one turn into the next (no idle period to observe)
assert(state.complete_task("t-1", "done") == true, "complete_task closes the task")
local closed = state.task_by_id("t-1")
assert(closed.status == "done" and type(closed.finish) == "number", "a closed task says so and when")
assert(state.complete_task("t-1", "done") == true, "closing twice is harmless")
assert(state.complete_task("nope") == false, "an unknown id closes nothing")
assert(state.task_by_id("nope") == nil, "an unknown id attaches to nothing")
assert(state.task_by_id(nil) == nil, "no id is not a lookup")
state.persist = false

-- notifications: blocked always reports, done/error throttle, exits report while working
targets = { targets[1] }
state.refresh()
local notes = {}
local save_notify = vim.notify
vim.notify = function(msg, level)
	notes[#notes + 1] = { msg = msg, level = level }
end
state.notify = true
probe_a = { running = true, state = "working" }
state.refresh()
probe_a = { running = true, state = "blocked", kind = "permission", msg = "run the tests?" }
state.refresh()
assert(#notes == 1 and notes[1].msg:find("needs your permission", 1, true), "blocked permission notifies")
assert(notes[1].level == vim.log.levels.WARN, "blocked is a warning")
notes = {}
probe_a = { running = true, state = "working" }
state.refresh()
probe_a = { running = true, state = "blocked", kind = "question", msg = "which one?" }
state.refresh()
assert(
	#notes == 1 and notes[1].msg:find("waiting for your answer", 1, true),
	"a new blocked transition is never throttled"
)
notes = {}
probe_a = { running = true, state = "done", msg = "all good" }
state.refresh()
assert(#notes == 1 and notes[1].level == vim.log.levels.INFO, "done notifies")
notes = {}
state.refresh()
assert(#notes == 0, "the same done is not repeated")
probe_a = { running = true, state = "error", msg = "boom" }
state.refresh()
assert(#notes == 1 and notes[1].level == vim.log.levels.ERROR, "error notifies")
notes = {}
probe_a = { running = true, state = "working" }
state.refresh()
state.refresh()
notes = {}
targets = {}
state.refresh()
assert(#notes == 1 and notes[1].msg:find("exited while working", 1, true), "an exit while working notifies")
assert(state.get("fake:b").gone, "unseen instance is gone")

-- Two agents whose name falls back to the same directory must still be told
-- apart in the panel: identical rows would look like one agent shown twice.
local dup = {
	{ id = "c", cwd = "/tmp", label = "pid 9001" },
	{ id = "d", cwd = "/tmp", label = "pid 9002" },
}
backends.register({
	id = "fake2",
	label = "Fake2",
	targets = function()
		return dup
	end,
	probe = function()
		return { running = true, state = "idle" }
	end,
	available = function()
		return true
	end,
	send = function()
		return true
	end,
})
state.refresh()
local n1 = state.name(state.get("fake2:c"))
local n2 = state.name(state.get("fake2:d"))
assert(n1 ~= n2, "two agents in one directory get different names: " .. n1 .. " / " .. n2)
assert(n1:match(" ·%d+$") and n2:match(" ·%d+$"), "the shared name is numbered: " .. n1 .. " / " .. n2)
assert(state.name(state.get("fake:a")) == "A", "a unique name is left alone")
assert(not state.statusline():find("⚠"), "gone blocked is not counted")
vim.notify = save_notify

print("STATE OK")
