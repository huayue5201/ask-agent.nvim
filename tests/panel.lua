-- Headless: nvim --headless --clean -l tests/panel.lua
-- A jump must never land in the window it was started from: the sidebar keeps its
-- buffer and the code opens somewhere a file may live.
vim.opt.runtimepath:prepend(".")

local backends = require("ask_agent.backends")
local state = require("ask_agent.state")
local dashboard = require("ask_agent.dashboard")
local context = require("ask_agent.context")

state.notify = false
state.persist = false

backends.register({
	id = "panel",
	label = "Panel",
	targets = function()
		return { { id = "p1", cwd = "/tmp", label = "panel-1" } }
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
})

---@return integer win the dashboard's own window
local function sidebar()
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):match("^ask%-agent://") then
			return w
		end
	end
	error("the sidebar is not in this tab")
end

---@return integer row the first task row of the sidebar
local function task_row()
	for i, l in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(sidebar()), 0, -1, false)) do
		if l:find("%[3%]") or l:find("running") then
			return i
		end
	end
	error("no task row in the sidebar")
end

local repo = vim.fn.getcwd()
local file = repo .. "/README.md"
vim.cmd.edit(vim.fn.fnameescape(file))
local file_win = vim.api.nvim_get_current_win()

-- an anchor whose buffer is gone: the jump has to reopen the file from its path
local other = repo .. "/ask-agent-panel-dead.lua"
vim.fn.writefile({ "one", "two", "three" }, other)
local dead = vim.fn.bufadd(vim.fn.fnameescape(other))
vim.fn.bufload(dead)
state.dispatch("panel", "p1", "a task with a dead anchor", {
	anchor = {
		buf = dead,
		bufname = vim.api.nvim_buf_get_name(dead),
		path = other,
		cwd = "/tmp",
		line = 2,
		col = 1,
	},
	correlation = { plugin = "todo2", key = 3 },
})
state.refresh()
vim.api.nvim_buf_delete(dead, { force = true })

dashboard.open({
	send = function()
		return true
	end,
})
local sw = sidebar()
local sbuf = vim.api.nvim_win_get_buf(sw)
local tabs = vim.fn.tabpagenr("$")

vim.api.nvim_set_current_win(sw)
vim.api.nvim_win_set_cursor(sw, { task_row(), 0 })
vim.api.nvim_feedkeys("o", "x", false)
vim.wait(50)

assert(vim.api.nvim_buf_is_valid(sbuf), "the sidebar buffer survived")
assert(vim.api.nvim_win_get_buf(sw) == sbuf, "the sidebar kept its own buffer")
assert(vim.fn.tabpagenr("$") == tabs, "a plain window was available, so no new tab")
assert(vim.api.nvim_get_current_win() == file_win, "the jump went to the editing window")
assert(
	vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p") == vim.fn.resolve(vim.fn.fnamemodify(other, ":p")),
	"the dead anchor was reopened: " .. vim.api.nvim_buf_get_name(0)
)
assert(vim.api.nvim_win_get_cursor(0)[1] == 2, "…at its line")
assert(vim.fn.tabpagenr("$") == tabs, "still the same tab")

-- `o` on the same row again (buffer now loaded) takes the other path in jump_to
vim.api.nvim_set_current_win(sw)
vim.api.nvim_win_set_cursor(sw, { task_row(), 0 })
vim.api.nvim_feedkeys("o", "x", false)
vim.wait(50)
assert(vim.api.nvim_win_get_buf(sw) == sbuf, "the sidebar still keeps its buffer")
assert(vim.api.nvim_get_current_win() == file_win, "…and the jump still lands in the editor")
assert(vim.api.nvim_win_get_cursor(0)[1] == 2, "…at the anchor line")
assert(vim.api.nvim_get_current_win() == file_win, "the loaded buffer jumped in the same window")

-- with no editing window at all the jump opens a tab instead of eating the panel
vim.cmd("tabnew")
local only = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(only, sbuf)
local lonely = vim.fn.tabpagenr("$")
local lonely_file = repo .. "/ask-agent-panel-lonely.lua"
vim.fn.writefile({ "one", "two" }, lonely_file)
local hidden_buf = vim.fn.bufadd(vim.fn.fnameescape(lonely_file))
vim.fn.bufload(hidden_buf)
local ok = context.jump_to({
	buf = hidden_buf,
	bufname = vim.api.nvim_buf_get_name(hidden_buf),
	path = lonely_file,
	line = 1,
})
assert(ok, "jumping out of a tab that is all sidebar works")
assert(vim.fn.tabpagenr("$") == lonely + 1, "…by opening a tab")
assert(vim.api.nvim_win_get_buf(only) == sbuf, "…and leaving the panel alone")
assert(vim.api.nvim_win_get_buf(0) == hidden_buf, "…with the file in the new one")

vim.fn.delete(other)
vim.fn.delete(lonely_file)
print("PANEL OK")
