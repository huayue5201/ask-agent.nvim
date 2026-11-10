-- Headless: nvim --headless --clean -l tests/dashboard.lua
-- The sidebar is a tree: agents on top, queued questions and sent turns below.
vim.opt.runtimepath:prepend(".")

local backends = require("ask_agent.backends")
local state = require("ask_agent.state")
local queue = require("ask_agent.queue")
local store = require("ask_agent.jump")
local dashboard = require("ask_agent.dashboard")

state.notify = false

local targets = {
	{ id = "a", cwd = "/tmp", label = "alpha" },
	{ id = "b", cwd = "/tmp", label = "quiet-instance" },
}
local mod = {
	id = "fake",
	label = "Fake",
	targets = function()
		return targets
	end,
	probe = function(t)
		return t.id == "a" and { running = true, state = "working" } or { running = true, state = "idle" }
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
assert(#lines == 4, "two agents + two tasks, got " .. #lines .. ": " .. vim.inspect(lines))
assert(lines[1]:match("alpha"), "agent name on the top-level row: " .. lines[1])
assert(lines[4]:match("^· "), "no tasks, no fold marker: " .. lines[4])
assert(lines[4]:match("quiet%-instance"), "the name column fits the longest name: " .. lines[4])
assert(lines[1]:match("working"), "agent state on the row: " .. lines[1])
assert(lines[2]:match("sent question") and lines[2]:match("running"), "running task first: " .. lines[2])
assert(lines[3]:match("queued question") and lines[3]:match("queued"), "queued task: " .. lines[3])
assert(vim.wo[vim.api.nvim_get_current_win()].winfixwidth, "sidebar keeps its width")

-- a narrow window truncates instead of overflowing
vim.api.nvim_win_set_width(0, 24)
queue.route(1, { backend = "fake", id = "a", name = "alpha" })
vim.wait(20)
for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
	assert(vim.fn.strdisplaywidth(l) <= 24, "row wider than the window: " .. l)
end
vim.api.nvim_win_set_width(0, 50)

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

-- opening again focuses the same sidebar instead of stacking another one
local first = vim.api.nvim_get_current_win()
dashboard.open(nil)
assert(vim.api.nvim_get_current_win() == first, "second open focuses")
vim.cmd("tabnew")
dashboard.open(nil)
assert(vim.api.nvim_get_current_win() == first and vim.fn.tabpagenr() == 1, "cross-tab focus")

-- an agent with questions still routed to it cannot be dismissed
vim.api.nvim_set_current_win(first)
vim.api.nvim_win_set_cursor(first, { 1, 0 })
vim.api.nvim_feedkeys("d", "x", false)
vim.wait(30)
assert(state.get("fake:a"), "dismiss refused while work is queued")

-- delete the queued task, then the agent can be dismissed and the view empties
vim.api.nvim_win_set_cursor(first, { 3, 0 })
vim.api.nvim_feedkeys("d", "x", false)
vim.wait(30)
assert(queue.count() == 0, "task deleted")
vim.api.nvim_win_set_cursor(first, { 1, 0 })
vim.api.nvim_feedkeys("d", "x", false)
vim.wait(30)
assert(state.get("fake:a") == nil, "agent dismissed")

-- q closes the sidebar, and later state events do not touch a dead buffer
vim.api.nvim_feedkeys("q", "x", false)
vim.wait(30)
assert(#vim.api.nvim_tabpage_list_wins(0) == 1, "sidebar closed")
state.refresh()
vim.wait(20)

print("DASHBOARD OK")
