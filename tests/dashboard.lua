-- Headless: nvim --headless --clean -l tests/dashboard.lua
-- The sidebar is a tree: agents on top, queued questions and sent turns below.
vim.opt.runtimepath:prepend(".")

local backends = require("ask_agent.backends")
local state = require("ask_agent.state")
local queue = require("ask_agent.queue")
local view = require("ask_agent.view")
local dashboard = require("ask_agent.dashboard")
local aliases = require("ask_agent.aliases")

aliases.setup({ file = "/tmp/ask-agent-dashboard-aliases.json" })
vim.fn.delete("/tmp/ask-agent-dashboard-aliases.json")

state.notify = false
state.persist = false -- never read or write the user's journal

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
state.dispatch("fake", "a", "sent question", {
	anchor = { buf = vim.api.nvim_get_current_buf(), line = 2 },
	correlation = { plugin = "test", key = 7 },
})
state.refresh()

local sent = {}
dashboard.open({
	result = function(_, cb)
		results[#results + 1] = true
		cb({ output = "all green\\n12 files changed" })
	end,
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
assert(vim.wo[vim.api.nvim_get_current_win()].winbar:match("ask%-agent · 2"), "winbar counts the agents")
assert(lines[1]:match("working"), "agent state on the row: " .. lines[1])
assert(lines[2]:match("sent question") and lines[2]:match("running"), "running task first: " .. lines[2])
assert(lines[3]:match("queued question") and lines[3]:match("queued"), "queued task: " .. lines[3])
-- tree lines: first child branches, the last one corners
-- a rail under the fold glyph keeps the agent -> tasks connection continuous
local rail = "\u{2502} "
local branch, corner = rail .. "\u{251c}\u{2500} ", rail .. "\u{2514}\u{2500} "
assert(lines[2]:sub(1, #branch) == branch, "first task branches off the agent: " .. lines[2])
assert(lines[3]:sub(1, #corner) == corner, "last task corners: " .. lines[3])
-- the path from the working agent to its running task is green
local green = false
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, { 1, 0 }, { 1, -1 }, { details = true })) do
	local hl = m[4].hl_group
	if hl and hl:match("^AskAgentRun") then
		green = true
	end
end
assert(green, "the running task's connector is highlighted")

-- the appearance knobs only change the connector, not the rows themselves
dashboard.open(nil, { running_line = "off" })
vim.wait(20)
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, { 0, 0 }, { -1, -1 }, { details = true })) do
	assert(not (m[4].hl_group or ""):match("^AskAgentRun"), "running_line=off paints no green")
end
assert(vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]:sub(1, #branch) == branch, "tree lines stay")
dashboard.open(nil, { tree_lines = false })
vim.wait(20)
assert(vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]:sub(1, 2) == "  ", "tree_lines=false indents only")
dashboard.open(nil, { tree_lines = true, running_line = "pulse" })
vim.wait(20)
assert(vim.wo[vim.api.nvim_get_current_win()].winfixwidth, "sidebar keeps its width")

-- n renames the agent on the cursor row; the name is what lists show from now on
local real_input = vim.ui.input
vim.ui.input = function(_, cb)
	cb("api-worker")
end
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys("n", "x", false)
vim.wait(30)
vim.ui.input = real_input
assert(state.name(state.get("fake:a")) == "api-worker", "the sidebar renamed the agent")
assert(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:match("api%-worker"), "the row redrew")
vim.fn.delete("/tmp/ask-agent-dashboard-aliases.json")

-- v reviews the turn behind the task, y copies it, f keeps only what needs you
local ask = require("ask_agent")
local real_diff = ask.diff
local reviewed
ask.diff = function(o)
	reviewed = o
	return true
end
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.api.nvim_feedkeys("v", "x", false)
vim.wait(20)
assert(reviewed and reviewed.correlation and reviewed.correlation.key == 7, "v opens the task's turn")
ask.diff = real_diff
vim.api.nvim_win_set_cursor(0, { 3, 0 })
vim.api.nvim_feedkeys("y", "x", false)
vim.wait(20)
assert(vim.fn.getreg('"') == "queued question", "y copies the task text: " .. vim.fn.getreg('"'))
vim.api.nvim_feedkeys("f", "x", false)
vim.wait(20)
assert(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:match("nothing needs you"), "f hides busy agents")
vim.api.nvim_feedkeys("f", "x", false)
vim.wait(20)
assert(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:match("api%-worker"), "f is a toggle")

-- a turn dispatched by another plugin shows where it came from
state.dispatch("fake", "b", "from the todo list", { correlation = { plugin = "todo2", key = "t42" } })
dashboard.open(nil)
vim.wait(20)
local tagged
for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
	if l:find("t42", 1, true) then
		tagged = l
	end
end
assert(tagged and tagged:find("[t42]", 1, true), "task row carries the todo2 id: " .. tostring(tagged))

-- a row only advertises the place it can jump to when it has one
local queued_row
for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
	if l:find("queued question", 1, true) then
		queued_row = l
	end
end
assert(queued_row and queued_row:find("x.lua:1", 1, true), "queued row shows its anchor: " .. tostring(queued_row))
assert(not tagged:find("%.lua:%d"), "a task without an anchor shows no place")

-- <CR> follows the source of the row: work another tool dispatched jumps to the
-- code it was filed at, a plain turn of yours opens the agent, and `o` jumps
-- from any row that has an anchor
local jumps, shown = {}, nil
local real_view = view.open
view.open = function(target)
	shown = target
	return true
end
dashboard.open({
	goto_anchor = function(a)
		jumps[#jumps + 1] = a
		return true
	end,
}, { width = 50 })
vim.wait(20)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.api.nvim_feedkeys("\r", "x", false)
vim.wait(20)
assert(#jumps == 1 and jumps[1].line == 2, "a dispatched task jumps to its anchor")
assert(shown == nil, "…and does not open the agent")
state.dispatch("fake", "b", "talk about the design", {
	anchor = { buf = vim.api.nvim_get_current_buf(), line = 3 },
})
dashboard.open({
	goto_anchor = function(a)
		jumps[#jumps + 1] = a
		return true
	end,
}, { width = 50 })
vim.wait(20)
local turn_row
for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
	if l:find("talk about the design", 1, true) then
		turn_row = i
	end
end
assert(turn_row, "the plain turn is listed")
vim.api.nvim_win_set_cursor(0, { turn_row, 0 })
vim.api.nvim_feedkeys("\r", "x", false)
vim.wait(20)
assert(#jumps == 1, "a turn of your own does not jump — it lives in the agent")
assert(shown and shown.id == "b", "…it opens that agent's viewer instead")
vim.api.nvim_win_set_cursor(0, { turn_row, 0 })
vim.api.nvim_feedkeys("o", "x", false)
vim.wait(20)
assert(#jumps == 2 and jumps[2].line == 3, "o jumps to the anchor of a turn")
view.open = real_view

-- <J> jumps out to the agent's own window through the jump adapters
local jump = require("ask_agent.jump")
local real_focus = jump.focus
local focused
jump.focus = function(target)
	focused = target
	return true
end
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys("J", "x", false)
vim.wait(20)
assert(focused and focused.id == "a", "J jumps to the agent on the cursor row")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
focused = nil
vim.api.nvim_feedkeys("J", "x", false)
vim.wait(20)
assert(focused and focused.id ~= nil, "J on a task row jumps to its agent")
jump.focus = real_focus

-- the adapter registry: highest priority that can handle the target wins
jump.register({
	id = "low",
	priority = 1,
	can = function(t)
		return t.x ~= nil
	end,
	focus = function() end,
})
jump.register({
	id = "high",
	priority = 99,
	can = function(t)
		return t.x ~= nil
	end,
	focus = function() end,
})
assert(jump.find({ x = 1 }).id == "high", "priority decides between adapters")
assert(jump.find({ y = 1 }) == nil, "no adapter claims an unknown target")
local ok, err = jump.focus({ y = 1 })
assert(not ok and err:match("no jump adapter"), "an unknown target explains itself: " .. tostring(err))
jump.register({
	id = "high",
	priority = 99,
	can = function(t)
		return t.x ~= nil
	end,
	focus = function() end,
})
local highs = 0
for _, a in ipairs(jump.list()) do
	if a.id == "high" then
		highs = highs + 1
	end
end
assert(highs == 1, "registering an id twice replaces it")

-- the rex adapter must use the CLI shape we verified (`focus` takes a positional
-- block); a -b on focus exits 2 and silently does nothing. Jumping off the
-- current tab/session needs three server/app actions in order: focus the block's
-- window (rex's term for a tab), focus the block, then make the session visible
-- in the app (a client action).
local systems = {}
local real_system = vim.system
vim.system = function(cmd, _, cb)
	systems[#systems + 1] = cmd
	local function out()
		if cmd[2] == "block" and cmd[3] == "inspect" then
			return { code = 0, stdout = '{"block":{"window_id":"w"}}' }
		elseif cmd[2] == "client" then
			return {
				code = 0,
				stdout = '{"clients":[{"client_id":"c","connection_state":"connected","info":{"kind":"app"},"session_ids":["s"]}]}',
			}
		end
		return { code = 0, stdout = "screen" }
	end
	if cb then
		cb(out())
		return { pid = 1 }
	end
	return { pid = 1, wait = out }
end
jump.focus({ rex = { session = "s", block = "b" } })
vim.wait(50)
vim.system = real_system
vim.wait(20)
assert(
	vim.deep_equal(systems[1], { "rex", "block", "inspect", "b", "-s", "s" }),
	"block inspect argv: " .. vim.inspect(systems[1])
)
assert(
	vim.deep_equal(systems[3], { "rex", "window", "focus", "w", "-s", "s" }),
	"window focus argv: " .. vim.inspect(systems[3])
)
assert(
	vim.deep_equal(systems[4], { "rex", "block", "focus", "b", "-s", "s" }),
	"focus argv: " .. vim.inspect(systems[4])
)
assert(
	vim.deep_equal(systems[5], { "rex", "-C", "c", "do", "session.select", "session_id=s" }),
	"session.select argv: " .. vim.inspect(systems[5])
)

-- long task lists collapse to a slice: five rows plus "… N older tasks" (9 here)
for i = 1, 7 do
	state.dispatch("fake", "b", "old job " .. i, {})
end
dashboard.open(nil)
vim.wait(20)
local more_row
for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
	if l:match("older task") then
		more_row = i
		assert(l:match("… 4 older tasks"), "slices the list to task_limit: " .. l)
	end
end
assert(more_row, "long task lists get an older-tasks row")
vim.api.nvim_win_set_cursor(0, { more_row, 0 })
vim.api.nvim_feedkeys("\r", "x", false)
vim.wait(20)
for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
	assert(not l:match("older task"), "expanding shows every task")
end

-- finished turns report how long they took, not how long ago they were sent
local rec = state.get("fake:a")
local task = rec.tasks[1]
task.status, task.finish = "done", task.ts + 65000
dashboard.open(nil)
vim.wait(20)
local done_line
for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
	if l:match("sent question") then
		done_line = l
	end
end
assert(
	done_line and done_line:match("done") and done_line:match("1m"),
	"duration instead of age: " .. tostring(done_line)
)
task.status, task.finish = "running", nil -- restore, the rest of the test assumes ordering

-- a narrow window truncates instead of overflowing
vim.api.nvim_win_set_width(0, 24)
queue.route(1, { backend = "fake", id = "a", name = "alpha" })
vim.wait(20)
for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
	assert(vim.fn.strdisplaywidth(l) <= 24, "row wider than the window: " .. l)
end
-- below TREE_MIN_WIDTH the connectors give way to plain indentation
vim.api.nvim_win_set_width(0, 16)
dashboard.open(nil)
vim.wait(20)
for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
	assert(vim.fn.strdisplaywidth(l) <= 16, "row wider than the window: " .. l)
end
assert(vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]:sub(1, 2) == "  ", "narrow sidebar drops tree lines")
vim.api.nvim_win_set_width(0, 50)

-- <CR> on a task jumps to its anchor instead of the agent window
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.api.nvim_feedkeys("\r", "x", false)
vim.wait(50)
assert(queue.count() == 1, "jumping does not consume the queued question")

-- <CR> on an agent opens a viewer float through the view providers; the queued
-- question routed to that agent is untouched
local viewed
local real_view = view.open
view.open = function(target)
	viewed = target
	return true
end
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys("\r", "x", false)
vim.wait(30)
view.open = real_view
assert(viewed and viewed.id == "a", "view opened for the agent on the cursor row")
assert(queue.count() == 1, "viewing does not consume the queued question")

-- an anchor captured in another tab switches to that tab instead of opening a
-- second copy of the buffer in the current one
local tab_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(tab_buf, "/tmp/ask-agent-anchor.lua")
vim.api.nvim_buf_set_lines(tab_buf, 0, -1, false, { "local x = 1", "local y = 2" })
vim.cmd("tabnew")
local tab = vim.api.nvim_get_current_tabpage()
vim.api.nvim_win_set_buf(0, tab_buf)
vim.cmd("tabprevious")
local first_tab = vim.api.nvim_get_current_tabpage()
assert(first_tab ~= tab)
local jumped, why = require("ask_agent.context").jump_to({
	buf = tab_buf,
	bufname = vim.api.nvim_buf_get_name(tab_buf), -- /tmp is a symlink on macOS
	line = 2,
	col = 1,
})
assert(jumped, "cross-tab jump: " .. tostring(why))
assert(vim.api.nvim_get_current_tabpage() == tab, "jump switched to the anchor's tab")
assert(vim.api.nvim_win_get_cursor(0)[1] == 2, "jump put the cursor on the line")
assert(vim.api.nvim_buf_get_name(0) == vim.api.nvim_buf_get_name(tab_buf))
vim.cmd("tabclose")
vim.cmd("bwipeout! " .. tab_buf)
assert(vim.api.nvim_get_current_tabpage() == first_tab, "back on the original tab")

-- jumping from a panel (buftype ~= "", e.g. this sidebar) must open the file in
-- an editing window instead of replacing the panel's own content
local panel_win = vim.api.nvim_get_current_win()
local panel_buf = vim.api.nvim_get_current_buf()
local file = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(file, "/tmp/ask-agent-goto.lua")
vim.api.nvim_buf_set_lines(file, 0, -1, false, { "a", "b" })
local jumped_from_panel = require("ask_agent.context").jump_to({
	buf = file,
	bufname = vim.api.nvim_buf_get_name(file),
	line = 2,
	col = 1,
})
assert(jumped_from_panel, "jump from a panel")
assert(vim.api.nvim_get_current_buf() == file, "the file opened in an editing window")
assert(vim.api.nvim_get_current_win() ~= panel_win, "the current window is not the panel")
assert(vim.api.nvim_win_get_buf(panel_win) == panel_buf, "the panel kept its own buffer")
vim.api.nvim_set_current_win(panel_win)
vim.cmd("bwipeout! " .. file)

-- the path fallback must not edit the panel window either: a dead buffer opened
-- from the sidebar lands in a normal window and leaves the panel as it was
local context = require("ask_agent.context")
local panel_file = "/tmp/ask-agent-panel-fallback.lua"
vim.fn.writefile({ "a", "b", "c" }, panel_file)
local dead = vim.fn.bufadd(vim.fn.fnameescape(panel_file))
vim.fn.bufload(dead)
local dead_anchor = {
	buf = dead,
	bufname = vim.api.nvim_buf_get_name(dead),
	path = panel_file,
	line = 2,
	col = 1,
}
vim.api.nvim_buf_delete(dead, { force = true })
vim.api.nvim_set_current_win(panel_win)
local opened, open_err = context.open(dead_anchor)
assert(opened, "the fallback opens: " .. tostring(open_err))
assert(vim.api.nvim_win_get_buf(panel_win) == panel_buf, "the panel kept its buffer through the fallback")
assert(
	vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p") == vim.fn.resolve(vim.fn.fnamemodify(panel_file, ":p")),
	"the fallback landed elsewhere: " .. vim.api.nvim_buf_get_name(0)
)
assert(vim.api.nvim_win_get_buf(0) ~= panel_buf, "the fallback did not edit the panel")
vim.api.nvim_set_current_win(panel_win)
vim.fn.delete(panel_file)

-- view providers: rex, tmux and herdr claim their own targets
assert(view.find({ rex = { session = "s", block = "b" } }).id == "rex", "rex provider")
assert(view.find({ pane = "%1" }).id == "tmux", "tmux provider")
assert(view.find({ herdr = { agent = "x" } }).id == "herdr", "herdr provider")

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

-- ? opens a help float; q closes the float first, then the sidebar
vim.api.nvim_set_current_win(first)
vim.api.nvim_feedkeys("?", "x", false)
vim.wait(30)
local floats = vim.tbl_filter(function(w)
	return vim.api.nvim_win_get_config(w).relative ~= ""
end, vim.api.nvim_tabpage_list_wins(0))
assert(#floats == 1, "help float is open")
local help_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(floats[1]), 0, -1, false)
assert(help_lines[1]:match("Show these keys"), "help lists the keys: " .. help_lines[1])
assert(help_lines[#help_lines]:match("^Order: blocked/error"), "help explains the sort order")
assert(#help_lines >= 14, "every key has a row")
vim.api.nvim_feedkeys("q", "x", false)
vim.wait(30)
assert(#vim.tbl_filter(function(w)
	return vim.api.nvim_win_get_config(w).relative ~= ""
end, vim.api.nvim_tabpage_list_wins(0)) == 0, "help closes with q")
assert(vim.api.nvim_win_is_valid(first), "sidebar still open behind it")

-- q closes the sidebar, and later state events do not touch a dead buffer
vim.api.nvim_feedkeys("q", "x", false)
vim.wait(30)
assert(#vim.api.nvim_tabpage_list_wins(0) == 1, "sidebar closed")
state.refresh()
vim.wait(20)

-- an anchor whose buffer number was recycled (or whose buffer is gone) still
-- opens the file it names, instead of failing on the stale buffer id
local context = require("ask_agent.context")
local stale = "/tmp/ask-agent-stale-anchor.lua"
vim.fn.writefile({ "one", "two", "three" }, stale)
local stale_buf = vim.fn.bufadd(stale)
vim.fn.bufload(stale_buf)
local stale_anchor = {
	buf = stale_buf,
	bufname = vim.api.nvim_buf_get_name(stale_buf),
	path = stale,
	line = 3,
	col = 1,
}
local stale_jump, stale_err = context.jump_to(stale_anchor)
assert(stale_jump, "the live buffer jumps: " .. tostring(stale_err))
vim.api.nvim_buf_delete(stale_buf, { force = true })
local ok, err = context.open(stale_anchor)
assert(ok, "a dead buffer falls back to path:line: " .. tostring(err))
assert(
	vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p") == vim.fn.resolve(vim.fn.fnamemodify(stale, ":p")),
	"the file was opened: " .. vim.api.nvim_buf_get_name(0)
)
assert(vim.api.nvim_win_get_cursor(0)[1] == 3, "the fallback goes to the anchor line")

-- a file of another project opens in a tab of its own, with that cwd
local proj = "/tmp/ask-agent-other-project"
vim.fn.mkdir(proj, "p")
local far = proj .. "/far.lua"
vim.fn.writefile({ "a", "b" }, far)
local far_buf = vim.fn.bufadd(vim.fn.fnameescape(far))
vim.fn.bufload(far_buf)
local far_anchor = {
	buf = far_buf,
	bufname = vim.api.nvim_buf_get_name(far_buf),
	path = far,
	cwd = proj,
	line = 2,
	col = 1,
}
local tabs = vim.fn.tabpagenr("$")
local first_tab = vim.api.nvim_get_current_tabpage()
local far_ok, far_err = context.jump_to(far_anchor)
assert(far_ok, "another project's file opens: " .. tostring(far_err))
assert(vim.fn.tabpagenr("$") == tabs + 1, "another project gets its own tab")
assert(
	vim.fn.resolve(vim.fn.getcwd()) == vim.fn.resolve(proj),
	"the new tab takes the anchor's cwd: " .. vim.fn.getcwd()
)
assert(vim.api.nvim_win_get_cursor(0)[1] == 2, "the new tab lands on the anchor line")

-- the same project stays in the tab we are in
local here = vim.fn.getcwd() .. "/lua/ask_agent/notify.lua"
local here_buf = vim.fn.bufadd(vim.fn.fnameescape(here))
vim.fn.bufload(here_buf)
local same_tabs = vim.fn.tabpagenr("$")
local here_ok, here_err = context.jump_to({
	buf = here_buf,
	bufname = vim.api.nvim_buf_get_name(here_buf),
	path = here,
	cwd = vim.fn.getcwd(),
	line = 1,
	col = 1,
})
assert(here_ok, "a repo file opens: " .. tostring(here_err))
assert(vim.fn.tabpagenr("$") == same_tabs, "a repo file does not open a new tab")

-- the path fallback obeys the same rule
vim.api.nvim_set_current_tabpage(first_tab)
local gone_buf = vim.fn.bufadd(vim.fn.fnameescape(far))
vim.fn.bufload(gone_buf)
vim.api.nvim_buf_delete(gone_buf, { force = true })
local open_tabs = vim.fn.tabpagenr("$")
local open_ok, open_err = context.open(far_anchor)
assert(open_ok, "the fallback opens another project's file: " .. tostring(open_err))
assert(vim.fn.tabpagenr("$") == open_tabs + 1, "the fallback opens a new tab for it")
assert(vim.fn.resolve(vim.fn.getcwd()) == vim.fn.resolve(proj), "the fallback tab takes the cwd")
vim.fn.delete(proj, "rf")

-- the same guard catches a buffer number that now belongs to another file
local other = "/tmp/ask-agent-other-anchor.lua"
vim.fn.writefile({ "x" }, other)
vim.cmd.edit(vim.fn.fnameescape(other))
local reused = vim.api.nvim_get_current_buf()
local reused_ok = context.jump_to({ buf = reused, bufname = "/nowhere/other.lua", line = 1 })
assert(not reused_ok, "a recycled buffer number is not trusted")
vim.fn.delete(stale)
vim.fn.delete(other)

print("DASHBOARD OK")
