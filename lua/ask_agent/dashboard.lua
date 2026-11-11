-- lua/ask_agent/dashboard.lua
---@brief The sidebar: one tree, agents on top, what you handed each of them below.
--
--   ▾ ⚠ reviewer            claude   needs permission  2m
--       ◐ fix the parser       queued   3m
--       ⠹ run the test suite   sent     41s
--       ✓ update the docs      done     8m
--   ▾ ◐ worker-2            pi       busy              12s
--       ⠹ port the parser      sent     12s
--
-- A row is either an agent (top level) or one of its tasks, and <CR> does the
-- obvious thing for that row: an agent's window comes to the front (through a
-- jump adapter — rex, tmux, or whatever you registered with
-- ask.register_jump), a task jumps to the code anchor it was written at.
--
-- Two task sources: the queue (questions not sent yet — `queued`) and the state
-- layer's dispatch log (sent work — `sent`, `done`, `error`).
--
-- The view is push-driven: state and queue notify, the sidebar redraws. The only
-- timer is the spinner, and it only runs while a turn is actually in progress.

local state = require("ask_agent.state")
local notify = require("ask_agent.notify")
local queue = require("ask_agent.queue")
local jump = require("ask_agent.jump")
local ui = require("ask_agent.ui")
local icons = require("ask_agent.icons")

local M = {}

local NS = vim.api.nvim_create_namespace("ask_agent.dashboard")
local HL = { blocked = "DiagnosticWarn", done = "DiagnosticOk", error = "DiagnosticError", working = "DiagnosticInfo" }
local TASK_HL = { queued = "DiagnosticInfo", done = "DiagnosticOk", error = "DiagnosticError" }
local TASK_ORDER = { running = 1, queued = 2, error = 3, done = 4 }

local buf, win, api, opts
local rows = {} -- line number -> node
local collapsed = {} -- agent key -> true
local frame = 0
local timer

---@param ms integer
---@return string
local function age(ms)
	local s = math.max(0, math.floor(ms / 1000))
	if s < 60 then
		return s .. "s"
	elseif s < 3600 then
		return math.floor(s / 60) .. "m"
	end
	return math.floor(s / 3600) .. "h"
end

---@param text string
---@param width integer
---@return string
local function fit(text, width)
	if width <= 0 or vim.fn.strdisplaywidth(text) <= width then
		return text
	end
	local out, w = {}, 0
	for _, ch in ipairs(vim.fn.split(text, "\\zs")) do
		local cw = vim.fn.strdisplaywidth(ch)
		if w + cw > width - 1 then
			break
		end
		w = w + cw
		out[#out + 1] = ch
	end
	return table.concat(out) .. "…"
end

---@return integer
local function inner_width()
	return win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win) - 1 or 40
end

---@param text string
---@param w integer
---@return string
local function pad(text, w)
	local have = vim.fn.strdisplaywidth(text)
	if have > w then
		return fit(text, w)
	end
	return text .. string.rep(" ", w - have)
end

---Left column flushed left, right column flushed right, the gap absorbs the slack.
---@param left string
---@param right string
---@param width integer
---@return string
local function columns(left, right, width)
	local rw = vim.fn.strdisplaywidth(right)
	if rw >= width then
		return fit(right, width)
	end
	local room = width - rw - 1
	local l = vim.fn.strdisplaywidth(left) > room and fit(left, room) or left
	return l .. string.rep(" ", math.max(1, width - vim.fn.strdisplaywidth(l) - rw)) .. right
end

---Queue entries per agent, so one render scans the queue once.
---@return table<string, table[]>
local function queued_by_agent()
	local out = {}
	for _, entry in ipairs(queue.list()) do
		local r = entry.route
		if r then
			local key = ("%s:%s"):format(r.backend, r.id)
			out[key] = out[key] or {}
			table.insert(out[key], entry)
		end
	end
	return out
end

---Tasks of one agent: queue entries routed to it plus its dispatch log.
---@param rec table
---@param queued table<string, table[]>
---@return table[]
local function tasks_of(rec, queued)
	local out = {}
	for _, entry in ipairs(queued[rec.key] or {}) do
		out[#out + 1] = { kind = "queued", entry = entry, ts = 0, index = entry.index }
	end
	for _, task in ipairs(rec.tasks or {}) do
		out[#out + 1] = { kind = task.status, task = task, ts = task.ts }
	end
	table.sort(out, function(a, b)
		local oa, ob = TASK_ORDER[a.kind] or 9, TASK_ORDER[b.kind] or 9
		if oa ~= ob then
			return oa < ob
		end
		if a.kind == "queued" then
			return (a.index or 0) < (b.index or 0)
		end
		return (a.ts or 0) > (b.ts or 0)
	end)
	return out
end

---@param rec table
---@param name_w integer
---@param show_backend boolean
---@param now integer
---@param n integer tasks below this agent
---@return string line, table[] marks
local function agent_line(rec, name_w, show_backend, now, n)
	local fold = n == 0 and icons.ui("tree", "leaf")
		or (collapsed[rec.key] and icons.ui("tree", "collapsed") or icons.ui("tree", "expanded"))
	local glyph = rec.state == "working" and icons.spin(frame) or (icons.ui("state", rec.state) or "?")
	local glyph_start = #fold + 1
	local name_start = glyph_start + #glyph + 1
	local name = state.name(rec)
	if n > 0 then
		name = name .. (" (%d)"):format(n)
	end
	local left = ("%s %s %s"):format(fold, glyph, pad(fit(name, name_w), name_w))
	local msg = rec.msg or (rec.gone and "exited" or rec.state)
	if rec.kind then
		msg = msg .. " · " .. rec.kind
	elseif rec.state == "done" and rec.source == "heuristic" then
		-- nobody reported the state: the turn simply stopped looking busy
		msg = msg .. " · inferred"
	end
	left = left .. "  " .. msg
	local right = age(now - (rec.since or now))
	if show_backend then
		right = rec.backend .. "  " .. right
	end
	local marks = {
		{ glyph_start, glyph_start + #glyph, HL[rec.state] or "Comment" },
	}
	local accent = rec.target and icons.accent_hl(icons.key(rec.target))
	if accent then
		marks[#marks + 1] = { name_start, name_start + #name, accent }
	end
	return columns(left, right, inner_width()), marks
end

---@param node table
---@param now integer
---@return string line, table[] marks
local function task_line(node, now)
	local glyph, text, right, hl
	if node.kind == "queued" then
		glyph, text, right, hl = icons.ui("task", "queued"), node.entry.prompt, "queued", TASK_HL.queued
	else
		local task = node.task
		glyph = node.kind == "running" and icons.spin(frame)
			or (icons.ui("task", node.kind) or icons.ui("tree", "leaf"))
		text, right, hl = task.text, node.kind, TASK_HL[node.kind] or "DiagnosticInfo"
		if task.ts then
			right = right .. "  " .. age(now - task.ts)
		end
	end
	local first = vim.split(text or "", "\n")[1] or ""
	local line = columns(("  %s %s"):format(glyph, first), right, inner_width())
	local marks = { { 2, 2 + #glyph, hl } }
	if node.kind == "done" or node.kind == "error" then
		marks[#marks + 1] = { 0, #line, "Comment" }
	end
	return line, marks
end

local ensure_timer

local function render()
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	local now = state.now()
	local list = state.all()
	local queued = queued_by_agent()
	local width = inner_width()

	-- name column: as wide as the longest name shown, but never wider than a third of the view
	local name_w = 8
	local backends_seen = {}
	local seen = 0
	local counts = {}
	for _, rec in ipairs(list) do
		counts[rec.key] = #tasks_of(rec, queued)
		local name = state.name(rec)
		if counts[rec.key] > 0 then
			name = name .. (" (%d)"):format(counts[rec.key])
		end
		name_w = math.max(name_w, vim.fn.strdisplaywidth(name))
		if not backends_seen[rec.backend] then
			backends_seen[rec.backend] = true
			seen = seen + 1
		end
	end
	name_w = math.min(name_w, math.max(8, math.floor(width / 2) - 6))

	local lines, map, marks = {}, {}, {}
	local working = false
	for _, rec in ipairs(list) do
		working = working or rec.state == "working"
		local children = tasks_of(rec, queued)
		local line, m = agent_line(rec, name_w, seen > 1, now, counts[rec.key])
		lines[#lines + 1], map[#map + 1], marks[#marks + 1] = line, { kind = "agent", rec = rec }, m
		if not collapsed[rec.key] then
			for _, node in ipairs(children) do
				node.rec = rec
				local tline, tm = task_line(node, now)
				lines[#lines + 1], map[#map + 1], marks[#marks + 1] = tline, node, tm
				working = working or node.kind == "running"
			end
		end
	end
	-- forget fold state of agents that went away
	for key in pairs(collapsed) do
		if not state.get(key) then
			collapsed[key] = nil
		end
	end
	if #lines == 0 then
		lines = { "  no agents running" }
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
	for i, m in ipairs(marks) do
		for _, mark in ipairs(m) do
			pcall(vim.api.nvim_buf_set_extmark, buf, NS, i - 1, mark[1], {
				end_col = math.min(mark[2], #lines[i]),
				hl_group = mark[3],
				priority = mark[3] == "Comment" and 1 or 10,
			})
		end
	end
	vim.bo[buf].modifiable = false
	rows = map
	if win and vim.api.nvim_win_is_valid(win) then
		local cur = vim.api.nvim_win_get_cursor(win)
		vim.api.nvim_win_set_cursor(win, { math.min(cur[1], math.max(1, #map)), cur[2] })
		local help = width >= 56 and "  ⏎ jump · s send · S flush · ? keys" or ""
		vim.wo[win].winbar = ("%s ask-agent · %d%s"):format(icons.header(), #list, help)
	end
	if working then
		ensure_timer()
	elseif timer then
		timer:stop()
	end
end

function ensure_timer()
	if timer then
		timer:start(
			100,
			100,
			vim.schedule_wrap(function()
				frame = frame + 1
				render()
			end)
		)
		return
	end
	timer = vim.uv.new_timer()
	ensure_timer()
end

---@return table|nil
local function current()
	return rows[vim.api.nvim_win_get_cursor(0)[1]]
end

---@param rec table
local function focus_agent(rec)
	local ok, err = jump.focus(rec.target)
	if not ok then
		notify.notify("[ask_agent] " .. err, vim.log.levels.INFO)
	end
end

---@param node table
local function open_node(node)
	if node.kind == "agent" then
		focus_agent(node.rec)
		return
	end
	local anchor = node.kind == "queued" and node.entry.anchor or (node.task and node.task.anchor)
	if not anchor then
		-- a task sent from this very sidebar has no anchor: the agent's window is the best we can do
		notify.notify("[ask_agent] No anchor for this task — focusing the agent instead", vim.log.levels.INFO)
		focus_agent(node.rec)
		return
	end
	local ok, err = api.goto_anchor(anchor)
	if not ok then
		notify.notify("[ask_agent] " .. err, vim.log.levels.WARN)
	end
end

---Dismiss a dead agent — but never while questions are still routed to it,
---or they would silently disappear from this view.
---@param rec table
local function rename(rec)
	local current = (state.name(rec):gsub(" ·%d+$", ""))
	vim.ui.input({
		prompt = ("Rename %s: "):format(current),
		default = current,
	}, function(name)
		if name == nil then
			return
		end
		if not state.rename(rec, name) then
			notify.notify("[ask_agent] Could not write the name to the cache file", vim.log.levels.WARN)
			return
		end
		render()
		notify.notify(("[ask_agent] Renamed to %s"):format(state.name(rec)), vim.log.levels.INFO)
	end)
end

---@param rec table
local function dismiss(rec)
	local queued = queued_by_agent()[rec.key]
	if queued and #queued > 0 then
		notify.notify(
			("[ask_agent] %d question(s) are still routed to %s"):format(#queued, state.name(rec)),
			vim.log.levels.WARN
		)
		return
	end
	state.dismiss(rec.key)
end

-- Keys, in the order they appear in the help float.
local HELP = {
	{ "?", "Show these keys" },
	{ "<CR>", "Agent: bring its window to the front · Task: jump to its code anchor" },
	{ "s", "Send a question to that agent" },
	{ "S", "Send every queued question routed to it" },
	{ "a", "Acknowledge a done/blocked agent" },
	{ "d", "Delete the queued task · dismiss a dead agent" },
	{ "n", "Rename an agent (empty restores the directory name)" },
	{ "<Tab>", "Fold or unfold the agent's tasks" },
	{ "r", "Poll every agent now" },
	{ "q", "Close the sidebar" },
}

---Help float, bottom-right, `q` / `<Esc>` / `?` closes it.
local function show_help()
	local lines = {}
	for _, item in ipairs(HELP) do
		lines[#lines + 1] = ("%-10s %s"):format(item[1], item[2])
	end
	local content = 0
	for _, line in ipairs(lines) do
		content = math.max(content, vim.fn.strdisplaywidth(line))
	end
	local width = math.min(content + 4, vim.o.columns - 4)
	local height = math.min(#lines, vim.o.lines - 3)
	local b = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
	vim.bo[b].modifiable, vim.bo[b].bufhidden = false, "wipe"
	vim.api.nvim_set_hl(0, "AskAgentHelpKey", { link = "Identifier", default = true })
	local ok, help = pcall(vim.api.nvim_open_win, b, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(0, vim.o.lines - height - 2),
		col = math.max(0, vim.o.columns - width - 2),
		style = "minimal",
		border = "rounded",
		title = " ask-agent keys ",
		title_pos = "center",
		zindex = 200,
	})
	if not ok then
		return
	end
	local ns = vim.api.nvim_create_namespace("ask_agent.dashboard.help")
	for i, item in ipairs(HELP) do
		vim.api.nvim_buf_set_extmark(b, ns, i - 1, 0, {
			end_col = #item[1],
			hl_group = "AskAgentHelpKey",
		})
	end
	local function hide()
		pcall(vim.api.nvim_win_close, help, true)
	end
	for _, key in ipairs({ "q", "<Esc>", "?" }) do
		vim.keymap.set("n", key, hide, { buffer = b, silent = true, nowait = true, desc = "Close help" })
	end
end

---@param rec table
local function send_to(rec)
	if not state.resolve(rec) then
		notify.notify("[ask_agent] " .. rec.id .. " is not running", vim.log.levels.WARN)
		return
	end
	ui.input({
		title = ("Send to %s (%s)"):format(state.name(rec), rec.backend),
		on_submit = function(text)
			local ok, err = api.send(text, { backend = rec.backend, target = rec.id })
			if not ok then
				notify.notify("[ask_agent] " .. err, vim.log.levels.WARN)
			end
		end,
	})
end

---@param rec table
local function flush_queue(rec)
	local ids = {}
	for _, node in ipairs(tasks_of(rec)) do
		if node.kind == "queued" then
			ids[#ids + 1] = node.entry.index
		end
	end
	if #ids == 0 then
		notify.notify(("[ask_agent] No queued question is routed to %s"):format(state.name(rec)), vim.log.levels.INFO)
		return
	end
	api.batch_send({ ids = table.concat(ids, ",") })
end

local function attach(bufnr)
	local opts_buf = { buffer = bufnr, nowait = true, silent = true }
	local function with(kind, fn)
		return function()
			local node = current()
			if node and (kind == nil or node.kind == kind) then
				fn(node)
			end
		end
	end
	vim.keymap.set("n", "<CR>", with(nil, open_node), opts_buf)
	vim.keymap.set(
		"n",
		"s",
		with("agent", function(node)
			send_to(node.rec)
		end),
		opts_buf
	)
	vim.keymap.set(
		"n",
		"S",
		with("agent", function(node)
			flush_queue(node.rec)
		end),
		opts_buf
	)
	vim.keymap.set(
		"n",
		"a",
		with("agent", function(node)
			state.ack(node.rec.key)
		end),
		opts_buf
	)
	vim.keymap.set(
		"n",
		"d",
		with(nil, function(node)
			if node.kind == "queued" then
				queue.remove(node.entry.id)
			elseif node.kind == "agent" then
				dismiss(node.rec)
			end
		end),
		opts_buf
	)
	vim.keymap.set(
		"n",
		"<Tab>",
		with("agent", function(node)
			collapsed[node.rec.key] = not collapsed[node.rec.key] or nil
			render()
		end),
		opts_buf
	)
	vim.keymap.set(
		"n",
		"n",
		with("agent", function(node)
			rename(node.rec)
		end),
		opts_buf
	)
	vim.keymap.set("n", "?", show_help, opts_buf)
	vim.keymap.set("n", "r", function()
		state.refresh()
		render()
	end, opts_buf)
	local function close()
		if win and vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end
	vim.keymap.set("n", "q", close, opts_buf)
	vim.keymap.set("n", "<Esc>", close, opts_buf)
end

---Open (or focus) the sidebar.
---@param callbacks { send: function, batch_send: function, goto_anchor: function }|nil
---@param o { pos?: "left"|"right", width?: integer }|nil
function M.open(callbacks, o)
	api = callbacks or api
	opts = vim.tbl_extend("force", { pos = "right", width = 40 }, o or {})
	if win and vim.api.nvim_win_is_valid(win) then
		if vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage() then
			vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(win))
		end
		vim.api.nvim_set_current_win(win)
		render()
		return
	end
	buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype, vim.bo[buf].bufhidden = "nofile", "wipe"
	vim.bo[buf].swapfile, vim.bo[buf].buflisted = false, false
	vim.bo[buf].filetype = "ask-agent-dashboard"
	vim.bo[buf].modifiable = false
	vim.api.nvim_buf_set_name(buf, "ask-agent://dashboard")
	vim.cmd((opts.pos == "right" and "botright " or "topleft ") .. "vsplit")
	win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_width(win, opts.width)
	vim.wo[win].winfixwidth = true
	vim.wo[win].number, vim.wo[win].relativenumber = false, false
	vim.wo[win].signcolumn, vim.wo[win].foldcolumn = "no", "0"
	vim.wo[win].spell, vim.wo[win].wrap = false, false
	vim.wo[win].cursorline = true
	attach(buf)
	local group = vim.api.nvim_create_augroup("AskAgentDashboard", { clear = true })
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
		group = group,
		callback = render,
	})
	vim.api.nvim_buf_attach(buf, false, {
		on_detach = function()
			pcall(vim.api.nvim_del_augroup_by_id, group)
			buf, win = nil, nil
			if timer then
				timer:stop()
				timer:close()
				timer = nil
			end
		end,
	})
	state.refresh()
	render()
end

state.on("update", render)
queue.on_change(render)

return M
