-- Headless: nvim --headless --clean -l tests/state.lua
-- Exercises the state layer: polling, completion inference, sticky done, priority,
-- statusline counts, correlation and rex overrides.
vim.opt.runtimepath:prepend(".")

-- rex is stubbed before state.lua loads it, so a target with `.rex` gets a blocking report
package.loaded["ask_agent.status.rex"] = {
	available = function()
		return true
	end,
	query = function(_, cb)
		cb({ state = "blocked", kind = "permission", msg = "approve the patch" })
	end,
}

local backends = require("ask_agent.backends")
local state = require("ask_agent.state")

state.notify = false

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

-- a vanished instance turns gone and drops out of the counters
targets = { targets[1] }
state.refresh()
assert(state.get("fake:b").gone, "unseen instance is gone")
assert(not state.statusline():find("⚠"), "gone blocked is not counted")

print("STATE OK")
