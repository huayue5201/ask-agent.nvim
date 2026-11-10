-- lua/ask_agent/dashboard.lua
---@brief All agents at a glance, sorted by "who needs me most".
--
-- One scratch buffer, no polling: `ask_agent.state` pushes updates and the rows
-- are redrawn only when something changed. Keys act on the agent on the cursor
-- line; everything else (send, queue flush, ack) is delegated back to init.lua
-- through the small `api` table handed to open(), so this module owns layout and
-- nothing else.

local state = require("ask_agent.state")
local queue = require("ask_agent.queue")
local ui = require("ask_agent.ui")
local icons = require("ask_agent.icons")

local M = {}

local NS = vim.api.nvim_create_namespace("ask_agent.dashboard")
local GLYPH = { blocked = "⚠", done = "✓", error = "✗", working = "◐", idle = "●", unknown = "◌" }
local DESC = { blocked = "needs you", done = "finished", error = "failed", working = "working", idle = "idle" }
local HL = { blocked = "DiagnosticWarn", done = "DiagnosticOk", error = "DiagnosticError" }

local buf, win, api
local rows = {} -- line number -> record

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

---Queued questions routed to this instance.
---@param rec table
---@return integer
local function queued(rec)
	local n = 0
	for _, entry in ipairs(queue.list()) do
		local r = entry.route
		if r and r.backend == rec.backend and tostring(r.id) == rec.id then
			n = n + 1
		end
	end
	return n
end

---@param rec table
---@param now number
---@return string
local function line_for(rec, now)
	local name = state.name(rec)
	local msg = rec.msg or (rec.gone and "exited" or DESC[rec.state] or rec.state)
	if rec.state == "blocked" and rec.kind then
		msg = msg .. " (" .. rec.kind .. ")"
	end
	local n = queued(rec)
	return ("%s %-18s %-8s %s%s"):format(
		GLYPH[rec.state] or "?",
		name:sub(1, 18),
		rec.backend,
		msg,
		("  %s%s"):format(age(now - (rec.since or now)), n > 0 and ("  +" .. n .. " q") or "")
	)
end

local function render()
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	local list = state.all()
	local now = vim.uv.now()
	local lines, map = {}, {}
	for i, rec in ipairs(list) do
		lines[i] = line_for(rec, now)
		map[i] = rec
	end
	if #lines == 0 then
		lines = { "No agents running." }
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "<CR> jump  s send  S flush queue  a ack  d dismiss  C capture  r refresh  q close"
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
	for i, rec in ipairs(map) do
		local hl = HL[rec.state]
		if hl then
			pcall(vim.api.nvim_buf_set_extmark, buf, NS, i - 1, 0, { end_col = 1, hl_group = hl })
		end
		local accent = icons.accent_hl(icons.key(rec.target))
		if accent then
			pcall(vim.api.nvim_buf_set_extmark, buf, NS, i - 1, 2, { end_col = 20, hl_group = accent })
		end
	end
	vim.bo[buf].modifiable = false
	rows = map
	if win and vim.api.nvim_win_is_valid(win) then
		local cur = vim.api.nvim_win_get_cursor(win)
		local max = math.max(1, #map)
		vim.api.nvim_win_set_cursor(win, { math.min(cur[1], max), cur[2] })
		if #map > 0 then
			vim.wo[win].winbar = (" ask-agent — %d agent(s)"):format(#map)
		end
	end
end

---@return table|nil
local function current()
	return rows[vim.api.nvim_win_get_cursor(0)[1]]
end

---@param rec table
local function jump(rec)
	local t = rec.target or {}
	local loc = t.rex
	if type(loc) == "table" and loc.block then
		local cmd = { "rex", "block", "focus", "-b" }
		cmd[#cmd + 1] = loc.block
		if loc.session then
			cmd[#cmd + 1], cmd[#cmd + 2] = "-s", loc.session
		end
		pcall(vim.system, cmd)
	elseif t.pane then
		pcall(vim.system, { "tmux", "select-pane", "-t", t.pane })
	else
		vim.notify(("[ask_agent] %s has no window to jump to"):format(state.name(rec)), vim.log.levels.INFO)
	end
end

---@param title string
---@param text string
local function show_text(title, text)
	local b = vim.api.nvim_create_buf(false, true)
	vim.bo[b].buftype, vim.bo[b].bufhidden = "nofile", "wipe"
	vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.split(text, "\n", { plain = true }))
	local w = vim.api.nvim_open_win(b, true, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		width = math.max(40, math.min(vim.o.columns - 8, 120)),
		height = math.max(8, math.min(vim.o.lines - 8, 24)),
		row = 2,
		col = 2,
		title = " " .. title .. " ",
	})
	vim.keymap.set("n", "q", function()
		pcall(vim.api.nvim_win_close, w, true)
	end, { buffer = b, nowait = true })
	vim.keymap.set("n", "<Esc>", function()
		pcall(vim.api.nvim_win_close, w, true)
	end, { buffer = b, nowait = true })
end

---@param rec table
local function capture(rec)
	local loc = type(rec.target) == "table" and rec.target.rex or nil
	if type(loc) ~= "table" or not loc.block then
		vim.notify("[ask_agent] Capture needs a rex block (run the agent inside rex)", vim.log.levels.INFO)
		return
	end
	local cmd = { "rex", "block", "capture", "-b", loc.block, "--trim" }
	if loc.session then
		vim.list_extend(cmd, { "-s", loc.session })
	end
	pcall(vim.system, cmd, { text = true }, function(res)
		vim.schedule(function()
			if res.code ~= 0 then
				vim.notify("[ask_agent] rex capture failed: " .. (res.stderr or ""), vim.log.levels.WARN)
				return
			end
			show_text(state.name(rec) .. " · recent output", res.stdout or "")
		end)
	end)
end

local function send_to(rec)
	if not state.resolve(rec) then
		vim.notify("[ask_agent] " .. rec.id .. " is not running", vim.log.levels.WARN)
		return
	end
	ui.input({
		title = ("Send to %s (%s)"):format(state.name(rec), rec.backend),
		on_submit = function(text)
			local ok, err = api.send(text, { backend = rec.backend, target = rec.id })
			if not ok then
				vim.notify("[ask_agent] " .. err, vim.log.levels.WARN)
			end
		end,
	})
end

local function flush_queue(rec)
	local ids = {}
	for _, entry in ipairs(queue.list()) do
		local r = entry.route
		if r and r.backend == rec.backend and tostring(r.id) == rec.id then
			ids[#ids + 1] = entry.index
		end
	end
	if #ids == 0 then
		vim.notify(("[ask_agent] No queued question is routed to %s"):format(state.name(rec)), vim.log.levels.INFO)
		return
	end
	api.batch_send({ ids = table.concat(ids, ",") })
end

local function attach(bufnr)
	local function act(fn)
		return function()
			local rec = current()
			if rec then
				fn(rec)
			end
		end
	end
	local opts = { buffer = bufnr, nowait = true, silent = true }
	vim.keymap.set("n", "<CR>", act(jump), opts)
	vim.keymap.set("n", "s", act(send_to), opts)
	vim.keymap.set("n", "S", act(flush_queue), opts)
	vim.keymap.set("n", "C", act(capture), opts)
	vim.keymap.set(
		"n",
		"a",
		act(function(rec)
			state.ack(rec.key)
		end),
		opts
	)
	vim.keymap.set(
		"n",
		"d",
		act(function(rec)
			state.dismiss(rec.key)
		end),
		opts
	)
	vim.keymap.set("n", "r", function()
		state.refresh()
	end, opts)
	vim.keymap.set("n", "q", function()
		if win and vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end, opts)
	vim.keymap.set("n", "<Esc>", function()
		if win and vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end, opts)
end

---Open (or focus) the dashboard.
---@param callbacks { send: function, batch_send: function }|nil
function M.open(callbacks)
	api = callbacks or api
	if win and vim.api.nvim_win_is_valid(win) then
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
	vim.cmd("botright split")
	win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.wo[win].number, vim.wo[win].relativenumber = false, false
	vim.wo[win].signcolumn, vim.wo[win].foldcolumn = "no", "0"
	vim.wo[win].spell, vim.wo[win].wrap = false, false
	attach(buf)
	vim.api.nvim_buf_attach(buf, false, {
		on_detach = function()
			buf, win = nil, nil
		end,
	})
	render()
	vim.api.nvim_win_set_height(win, math.max(4, math.min(#state.all() + 3, 14)))
end

state.on("update", function()
	if buf and vim.api.nvim_buf_is_valid(buf) then
		render()
	end
end)

return M
