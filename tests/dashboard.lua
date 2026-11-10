-- Headless: nvim --headless --clean -l tests/dashboard.lua
-- The sidebar is a tree: agents on top, queued questions and sent turns below.
vim.opt.runtimepath:prepend(".")

local backends = require("ask_agent.backends")
local state = require("ask_agent.state")
local queue = require("ask_agent.queue")
local store = require("ask_agent.jump")
local dashboard = require("ask_agent.dashboard")

state.notify = false

local targets = { { id = "a", cwd = "/tmp", label = "alpha" } }
local mod = {
	id = "fake",
	label = "Fake",
	targets = function()
		return targets
	end,
	probe = function()
		return { running = true, state = "working" }
	end,
	available = function()
		return true
	end,
	send = function()
		return true
	end,
}
backends.register(mod)

-- one question still queued and routed to alpha, one already sent
queue.add({ buf = vim.api.nvim_get_current_buf(), line = 1, col = 1, path = "x.lua" }, "queued question")
queue.route(1, { backend = "fake", id = "a", name = "alpha" })
state.dispatch("fake", "a", "sent question", { anchor = { buf = vim.api.nvim_get_current_buf(), line = 2 } })
state.refresh()

local sent = {}
dashboard.open({
	send = function(text)
		sent[#sent + 1] = text
		return true
	end,
	batch_send = function() end,
	goto_anchor = function()
		return true
	end,
}, { width = 50 })

local buf = vim.api.nvim_get_current_buf()
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(vim.bo[buf].filetype == "ask-agent-dashboard", "sidebar buffer")
assert(#lines == 3, "one agent + two tasks, got " .. #lines .. ": " .. vim.inspect(lines))
assert(lines[1]:match("alpha"), "agent name on the top-level row: " .. lines[1])
assert(lines[1]:match("working"), "agent state on the row: " .. lines[1])
assert(lines[2]:match("sent question") and lines[2]:match("running"), "running task first: " .. lines[2])
assert(lines[3]:match("queued question") and lines[3]:match("queued"), "queued task: " .. lines[3])
assert(vim.wo[vim.api.nvim_get_current_win()].winfixwidth, "sidebar keeps its width")

-- <CR> on a task jumps to its anchor instead of the agent window
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.api.nvim_feedkeys("\\r", "x", false)
vim.wait(50)
assert(queue.count() == 1, "jumping does not consume the queued question")

-- adapters: rex and tmux both claim their targets, custom ones can win
assert(store.find({ rex = { session = "s", block = "b" } }).id == "rex", "rex adapter")
assert(store.find({ pane = "%1" }).id == "tmux", "tmux adapter")
store.register({
	id = "custom",
	priority = 100,
	can = function()
		return true
	end,
	focus = function() end,
})
assert(store.find({ pane = "%1" }).id == "custom", "priority wins")
assert(select(1, store.focus({ pane = "%1" })), "focus routes through the adapter")
store.register({
	id = "custom",
	priority = 100,
	can = function()
		return false
	end,
	focus = function() end,
})
assert(store.find({ pane = "%1" }).id == "tmux", "re-registering replaces by id")

print("DASHBOARD OK")
