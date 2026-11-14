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
-- obvious thing for that row: an agent — or a turn of your own — opens in a viewer
-- float (through a view provider — rex, tmux, herdr, or whatever you registered
-- with ask.register_view); work another tool dispatched (todo2, a plugin over the
-- bridge) jumps to the code anchor it was filed at, because that is where it
-- lives. A task row only shows `file.lua:42` when it has an anchor, and `o`
-- jumps to it from any row that has one.
--
-- Two task sources: the queue (questions not sent yet — `queued`) and the state
-- layer's dispatch log (sent work — `sent`, `done`, `error`).
--
-- The view is push-driven: state and queue notify, the sidebar redraws. The only
-- timer is the spinner, and it only runs while a turn is actually in progress.

local state = require("ask_agent.state")
local notify = require("ask_agent.notify")
local queue = require("ask_agent.queue")
local view = require("ask_agent.view")
local jump = require("ask_agent.jump")
local ui = require("ask_agent.ui")
local icons = require("ask_agent.icons")
local context = require("ask_agent.context")

local M = {}

local NS = vim.api.nvim_create_namespace("ask_agent.dashboard")
local HL = {
	blocked = "DiagnosticWarn",
	done = "DiagnosticOk",
	error = "DiagnosticError",
	working = "DiagnosticInfo",
	idle = "Comment",
	unknown = "Comment",
	gone = "Comment",
}
local TASK_HL = { queued = "DiagnosticInfo", done = "DiagnosticOk", error = "DiagnosticError" }
local TASK_ORDER = { running = 1, queued = 2, error = 3, done = 4 }

-- Tree lines and the running-task connector. Both are cosmetic: `tree_lines`
-- (default true) draws │ ├ └ between an agent and its tasks, and `running_line`
-- ("dash" | "pulse" | "static" | "off", default "dash") lights the path from the
-- agent down to the task that is running right now. Narrow sidebars fall back to
-- plain indentation so the text keeps its room.
local TREE_MIN_WIDTH = 20
-- Wide sidebars get a coloured rail, group headings and a column for where a
-- question came from; middle ones keep the headings, narrow ones go plain.
local WIDE_WIDTH = 56
local MID_WIDTH = 40
local RAIL = "▌"

-- short words for the state column: the row is a table, not a sentence
local KIND_SHORT = { permission = "perm", question = "ask", auth = "auth" }
local STATE_SHORT = {
	working = "busy",
	idle = "idle",
	done = "done",
	error = "error",
	unknown = "?",
	gone = "gone",
}
local TASK_SHORT = { queued = "queued", running = "sent", done = "done", error = "error" }

local cfg = { tree_lines = true, running_line = "dash", task_limit = 5, groups = true, rail = true, keys = {} }

-- declared here because render() (above the key table) draws the winbar hint
local KEYS, keys_of, key_label
local RUN_HL = { "AskAgentRunDim", "AskAgentRunMid", "AskAgentRunBright" }
local RUN_FG = { "#2b6b3e", "#3fb950", "#7ee787" }
local run_hl_tc -- termguicolors value the groups were built for
local tree_hl_ready = false

local ensure_tree_hl
local ensure_run_hl
local run_shade -- task rows draw the running path; defined with the other hl helpers

local buf, win, api, opts
local rows = {} -- line number -> node
local collapsed = {} -- agent key -> true
local only_needs = false -- `f`: show only blocked / error / unread-done agents
local expanded_tasks = {} -- agent key -> show every task, past cfg.task_limit
local truncated = false -- set by fit(); a fresh open grows the sidebar once
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

---How long one turn took, for rows that are already finished.
---@param ms integer
---@return string
local function duration(ms)
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
	truncated = true
	return require("ask_agent.text").fit(text, width) or ""
end

---Does this agent want a human? (`f` keeps only these rows.)
---@param rec table
---@return boolean
local function needs_you(rec)
	return rec.state == "blocked" or rec.state == "error" or (rec.state == "done" and rec.unread)
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

---Left block flushed left, optional middle column, right column flushed right.
---The middle column is dropped when the sidebar is too narrow to keep both, so
---the name never gets squeezed down to nothing.
---@param left string
---@param mid string|nil
---@param right string
---@param width integer
---@return string
local function place(left, mid, right, width)
	local rw = vim.fn.strdisplaywidth(right)
	local mw = mid and vim.fn.strdisplaywidth(mid) or 0
	local room = width - rw - 1
	if mw > 0 then
		if room - mw - 2 < 10 then
			mid, mw = nil, 0
		else
			room = room - mw - 2
		end
	end
	local l = fit(left, math.max(0, room))
	local gap = width - vim.fn.strdisplaywidth(l) - rw - mw - (mw > 0 and 2 or 0)
	local out = l .. string.rep(" ", math.max(1, gap))
	if mid and mw > 0 then
		out = out .. mid .. "  "
	end
	-- the gap is padding, not content: keep it out of the buffer
	return (out .. right):gsub("%s+$", "")
end

---A row built piece by piece, so every highlight knows its byte range.
---@return table
local function row()
	local self = { parts = {}, marks = {}, size = 0 }
	function self.add(text, hl, from, to)
		local start = self.size
		self.parts[#self.parts + 1] = text
		self.size = self.size + #text
		if hl then
			self.marks[#self.marks + 1] = { start + (from or 0), start + (to or #text), hl }
		end
		return start
	end
	function self.text()
		return table.concat(self.parts)
	end
	return self
end

---The word in the state column for an agent row.
---@param rec table
---@return string
local function agent_state_text(rec)
	if rec.state == "blocked" then
		return KIND_SHORT[rec.kind] or "blocked"
	end
	if rec.msg and rec.msg ~= "" then
		return rec.msg
	end
	return STATE_SHORT[rec.state] or rec.state
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
	queued = queued or {}
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
---@param L table layout (see render)
---@param now integer
---@param n integer tasks below this agent
---@return string line, table[] marks, integer fold_start, integer fold_stop
local function agent_line(rec, L, now, n)
	local fold = n == 0 and icons.ui("tree", "leaf")
		or (collapsed[rec.key] and icons.ui("tree", "collapsed") or icons.ui("tree", "expanded"))
	local hl = HL[rec.state] or "Comment"
	local glyph = rec.state == "working" and icons.spin(frame) or (icons.ui("state", rec.state) or "?")
	local name = state.name(rec)
	if n > 0 then
		name = name .. (" (%d)"):format(n)
	end
	local r = row()
	if L.rail then
		r.add(RAIL .. " ", hl)
	end
	local fold_start = r.add(fold)
	r.add(" ")
	r.add(glyph, hl)
	r.add(" ")
	local accent = rec.target and icons.accent_hl(icons.key(rec.target)) or "Bold"
	r.add(pad(fit(name, L.name_w), L.name_w), accent)
	if L.show_state then
		r.add(" " .. pad(fit(agent_state_text(rec), L.state_w), L.state_w), "Comment")
	end
	local right = age(now - (rec.since or now))
	if L.backend then
		right = rec.backend .. "  " .. right
	end
	local line = place(r.text(), nil, right, L.width)
	local marks = r.marks
	if rec.state == "done" and not rec.unread then
		-- read and finished: it stays visible, but it stops asking for attention
		marks[#marks + 1] = { 0, #line, "Comment" }
	end
	return line, marks, fold_start, fold_start + #fold
end

---@param key string
---@param fallback string
---@return string
local function tree_glyph(key, fallback)
	return icons.ui("tree", key) or fallback
end

---Prefix of a task row: a rail under the agent's fold glyph, then the branch and
---horizontal. The rail is what makes the agent -> tasks connection continuous
---instead of two separate segments; the running path is painted over it as well.
---@param i integer 1-based sibling index
---@param n integer number of siblings
---@param use_lines boolean
---@param i integer row index among the visible tasks
---@param n integer how many tasks are visible
---@param L table layout
---@return string prefix, integer branch_bytes, integer horiz_bytes
local function task_prefix(i, n, L)
	local gut = L.rail and (RAIL .. " ") or ""
	if not L.lines then
		return gut .. "  ", 0, 0
	end
	local rail = tree_glyph("vertical", "│") .. " "
	local branch = (i == n) and tree_glyph("corner", "└") or tree_glyph("branch", "├")
	local horiz = tree_glyph("horizontal", "─")
	return gut .. rail .. branch .. horiz .. " ", #gut + #rail + #branch, #horiz
end

---"file.lua:42" for a row that can be jumped to, or nil.
---@param a table|nil
---@return string|nil
local function anchor_label(a)
	if not a or not a.path or a.path == "" then
		return nil
	end
	local name = vim.fn.fnamemodify(a.path, ":t")
	if name == "" then
		return nil
	end
	return ("%s:%d"):format(name, a.line or 1)
end

---@param node table
---@param L table layout
---@param now integer
---@param i integer row index among the visible tasks
---@param n integer how many tasks are visible
---@param run { at: integer, total: integer }|nil the running task's path
---@return string line, table[] marks
local function task_line(node, L, now, i, n, run)
	local glyph, text, word, hl
	if node.kind == "queued" then
		glyph, text, word, hl = icons.ui("task", "queued"), node.entry.prompt, TASK_SHORT.queued, TASK_HL.queued
	else
		local task = node.task
		glyph = node.kind == "running" and icons.spin(frame)
			or (icons.ui("task", node.kind) or icons.ui("tree", "leaf"))
		text, word, hl = task.text, TASK_SHORT[node.kind] or node.kind, TASK_HL[node.kind] or "DiagnosticInfo"
	end
	local first = vim.split(text or "", "\n")[1] or ""
	-- where the question came from (todo2, a plugin, ...), so the row is traceable
	-- when several tools dispatch through the same agent
	local tag = ""
	local c = node.task and node.task.correlation
	local key = c and (c.label or c.key)
	if key then
		tag = (c.plugin and c.plugin ~= "todo2") and ("[%s:%s] "):format(c.plugin, key) or ("[%s] "):format(key)
	end
	local prefix, branch_bytes, horiz_bytes = task_prefix(i, n, L)
	local r = row()
	r.add(prefix)
	r.add(glyph, hl)
	r.add(" ")
	if tag ~= "" then
		r.add(tag, "Comment")
	end
	local tag_w = vim.fn.strdisplaywidth(tag)
	r.add(pad(fit(first, L.name_w - tag_w), L.name_w - tag_w))
	if L.show_state then
		r.add(" " .. pad(fit(word, L.state_w), L.state_w), "Comment")
	end
	local right = ""
	if node.task and node.task.ts then
		if (node.kind == "done" or node.kind == "error") and node.task.finish then
			-- a finished turn should say how long it took, not how long ago it was
			right = duration(node.task.finish - node.task.ts)
		else
			right = age(now - node.task.ts)
		end
	elseif node.kind == "queued" then
		right = ""
	end
	-- the code the row is about, so `<CR>`/`o` are predictable before pressing them
	local mid
	if L.anchor_w > 0 then
		local where = anchor_label(node.kind == "queued" and node.entry.anchor or (node.task and node.task.anchor))
		mid = pad(fit(where or "", L.anchor_w), L.anchor_w)
	end
	local line = place(r.text(), mid, right, L.width)
	local marks = r.marks
	if L.lines then
		if run and i <= run.at then
			-- the pulse walks from the agent's fold cell down to the task
			marks[#marks + 1] = { 0, branch_bytes, run_shade(i, run.total) }
			if i == run.at and horiz_bytes > 0 then
				marks[#marks + 1] = { branch_bytes, branch_bytes + horiz_bytes, run_shade(i + 1, run.total) }
			end
		else
			marks[#marks + 1] = { 0, branch_bytes + horiz_bytes, "AskAgentTree" }
		end
	end
	if node.kind == "done" or node.kind == "error" then
		marks[#marks + 1] = { 0, #line, "Comment" }
	end
	return line, marks
end

function ensure_tree_hl()
	if tree_hl_ready then
		return
	end
	tree_hl_ready = true
	vim.api.nvim_set_hl(0, "AskAgentTree", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "AskAgentGroup", { link = "Comment", bold = true, default = true })
end

---Build the green shades for the running connector. Returns whether truecolor is
---available: without it the path is drawn in one flat green (no animation, since
---the shades would collapse into each other).
---@return boolean
function ensure_run_hl()
	local tc = vim.o.termguicolors
	if run_hl_tc == tc then
		return tc
	end
	run_hl_tc = tc
	if tc then
		for i, name in ipairs(RUN_HL) do
			vim.api.nvim_set_hl(0, name, { fg = RUN_FG[i], bold = true, default = true })
		end
	else
		vim.api.nvim_set_hl(0, "AskAgentRun", { link = "DiagnosticOk", default = true })
	end
	return tc
end

---Highlight for one cell of the agent -> running-task path.
---@param i integer 0-based cell index (0 = the agent's fold glyph)
---@param n integer total cells on the path
---@return string hl
function run_shade(i, n)
	if not ensure_run_hl() then
		return "AskAgentRun"
	end
	if cfg.running_line == "static" then
		local s = math.floor(i * 3 / math.max(1, n)) + 1
		return RUN_HL[math.min(3, math.max(1, s))]
	elseif cfg.running_line == "dash" then
		-- marching dashes: one bright cell every three, shifted down each frame
		return (i - frame) % 3 == 0 and RUN_HL[3] or RUN_HL[1]
	end
	-- pulse: a bright cell travels down the path, mid shade right behind it
	local head = frame % n
	local d = (head - i) % n
	if d == 0 then
		return RUN_HL[3]
	elseif d == 1 then
		return RUN_HL[2]
	end
	return RUN_HL[1]
end

local ensure_timer

local function render()
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	truncated = false
	local now = state.now()
	local list = state.all()
	local queued = queued_by_agent()
	local width = inner_width()
	local shown = {}
	for _, rec in ipairs(list) do
		if not only_needs or needs_you(rec) then
			shown[#shown + 1] = rec
		end
	end

	-- what this width can afford
	local L = {
		width = width,
		rail = cfg.rail and width >= WIDE_WIDTH,
		groups = cfg.groups and width >= MID_WIDTH and not only_needs,
		show_state = true,
		backend = false,
		lines = cfg.tree_lines and width >= TREE_MIN_WIDTH,
		name_w = 8,
		state_w = 0,
		anchor_w = 0,
	}

	-- columns: as wide as the content needs, but never wider than half the view
	local counts, backends_seen, anchors = {}, {}, {}
	local seen = 0
	for _, rec in ipairs(shown) do
		local children = tasks_of(rec, queued)
		counts[rec.key] = #children
		local name = state.name(rec)
		if #children > 0 then
			name = name .. (" (%d)"):format(#children)
		end
		L.name_w = math.max(L.name_w, vim.fn.strdisplaywidth(name))
		L.state_w = math.max(L.state_w, vim.fn.strdisplaywidth(agent_state_text(rec)))
		if not backends_seen[rec.backend] then
			backends_seen[rec.backend] = true
			seen = seen + 1
		end
		for _, node in ipairs(children) do
			local where = anchor_label(node.kind == "queued" and node.entry.anchor or (node.task and node.task.anchor))
			if where then
				anchors[#anchors + 1] = where
			end
			-- one width for both columns, or "queued" would be cut to "que…"
			local word = TASK_SHORT[node.kind] or node.kind
			L.state_w = math.max(L.state_w, vim.fn.strdisplaywidth(word))
		end
	end
	L.backend = seen > 1 and width >= 44
	-- where the question came from gets its own column once there is room for it
	if width >= WIDE_WIDTH and #anchors > 0 then
		local w = 8
		for _, a in ipairs(anchors) do
			w = math.max(w, vim.fn.strdisplaywidth(a))
		end
		L.anchor_w = math.min(w, width >= WIDE_WIDTH and 18 or 12)
	end
	local room = width - (L.rail and 2 or 0)
	local overhead = (L.lines and 4 or 2) + 2 + (L.show_state and (1 + L.state_w) or 0) + 1
	local right_w = 5 + (L.backend and 10 or 0)
	local budget = room - overhead - right_w - (L.anchor_w > 0 and (L.anchor_w + 2) or 0)
	L.state_w = math.max(4, L.state_w)
	-- the column is a fixed slot: a long question should not push the state
	-- column around, so spend the whole budget instead of hugging the names
	L.name_w = math.max(6, math.min(budget, 32))
	if L.lines then
		ensure_tree_hl()
	end

	local lines, map, marks = {}, {}, {}
	local working = false
	local function add_agent(rec)
		working = working or rec.state == "working"
		local children = tasks_of(rec, queued)
		local show_children = not collapsed[rec.key]
		local line, m, fold_start, fold_stop = agent_line(rec, L, now, counts[rec.key])
		-- The running task sorts first, so the path is usually just the agent's
		-- fold cell plus that one row's branch; it still reads as a link because
		-- the pulse travels between them.
		local running
		if L.lines and cfg.running_line ~= "off" and show_children then
			for i, node in ipairs(children) do
				if node.kind == "running" then
					running = i
					break
				end
			end
		end
		local run_total = running and (running + 2) or 0
		if running then
			m[#m + 1] = { fold_start, fold_stop, run_shade(0, run_total) }
		end
		lines[#lines + 1], map[#map + 1], marks[#marks + 1] = line, { kind = "agent", rec = rec }, m
		if not show_children then
			return
		end
		local visible, hidden = children, 0
		if not expanded_tasks[rec.key] and cfg.task_limit and #children > cfg.task_limit then
			hidden = #children - cfg.task_limit
			visible = {}
			for i = 1, cfg.task_limit do
				visible[i] = children[i]
			end
		end
		local n = #visible
		local run = running and { at = running, total = run_total } or nil
		for i, node in ipairs(visible) do
			node.rec = rec
			local tline, tm = task_line(node, L, now, i, n, run)
			lines[#lines + 1], map[#map + 1], marks[#marks + 1] = tline, node, tm
			working = working or node.kind == "running"
		end
		if hidden > 0 then
			local more = ("  … %d older task%s  ⏎ show"):format(hidden, hidden == 1 and "" or "s")
			lines[#lines + 1] = fit(more, width)
			map[#map + 1] = { kind = "more", rec = rec, hidden = hidden }
			marks[#marks + 1] = { { 2, #more, "Comment" } }
		end
	end

	-- "needs you" first: it is the only group that wants something from the reader
	local buckets = { { title = nil, recs = shown } }
	if L.groups then
		buckets = {
			{ title = "needs you", recs = {} },
			{ title = "working", recs = {} },
			{ title = "idle & done", recs = {} },
		}
		for _, rec in ipairs(shown) do
			table.insert(buckets[needs_you(rec) and 1 or (rec.state == "working" and 2 or 3)].recs, rec)
		end
	end
	for _, bucket in ipairs(buckets) do
		if #bucket.recs > 0 then
			if #lines > 0 then
				lines[#lines + 1], map[#map + 1], marks[#marks + 1] = "", false, {}
			end
			if bucket.title then
				local title = ("%s  %d"):format(bucket.title:upper(), #bucket.recs)
				lines[#lines + 1], map[#map + 1], marks[#marks + 1] =
					fit(title, width), false, { { 0, #title, "AskAgentGroup" } }
			end
			for _, rec in ipairs(bucket.recs) do
				add_agent(rec)
			end
		end
	end
	-- forget fold state of agents that went away
	for key in pairs(collapsed) do
		if not state.get(key) then
			collapsed[key] = nil
		end
	end
	for key in pairs(expanded_tasks) do
		if not state.get(key) then
			expanded_tasks[key] = nil
		end
	end
	if #lines == 0 then
		lines = {
			only_needs and "  nothing needs you — f shows everyone" or "  no agents running — :AskAgent to ask",
		}
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
		-- the same counts the statusline shows: one implementation, one truth
		local flags = state.statusline()
		local title = ("%s ask-agent · %d"):format(icons.header(), #shown)
		if flags ~= "" then
			title = title .. "  " .. flags
		end
		if only_needs then
			title = title .. "  needs you"
		end
		-- the hint names the keys as they are bound now, not the defaults
		local hint = {}
		for _, name in ipairs({ "open", "jump", "help" }) do
			local key = keys_of(name)
			if key and key ~= "" then
				hint[#hint + 1] = ("%s %s"):format(
					key_label(key),
					name == "jump" and "host" or (name == "open" and "open" or "keys")
				)
			end
		end
		local help = (width >= 56 and #hint > 0) and ("  " .. table.concat(hint, " · ")) or ""
		vim.wo[win].winbar = title .. help
		-- A fresh sidebar that had to truncate grows once; the content decides the
		-- width instead of the width cutting the content.
		if opts and opts.autowidth and truncated and not opts.autosized and width >= 32 and width < 48 then
			opts.autosized = true
			pcall(vim.api.nvim_win_set_width, win, math.min(48, width + 6))
			render()
			return
		end
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
local function view_agent(rec)
	local ok, err
	if api and api.view then
		ok, err = api.view(rec.target)
	else
		ok, err = view.open(rec.target)
	end
	if not ok then
		notify.notify("[ask_agent] " .. err, vim.log.levels.INFO)
	end
end

---Bring the terminal window the agent lives in to the front: `<CR>` shows it
---inside Neovim, this goes out to where it actually runs (a jump adapter — rex,
---tmux, or whatever ask.register_jump added).
---@param rec table
local function jump_to_host(rec)
	local ok, err = jump.focus(rec.target)
	if not ok then
		notify.notify("[ask_agent] " .. tostring(err), vim.log.levels.INFO)
	end
end

---@param node table
local function jump_host_node(node)
	if not node.rec then
		notify.notify("[ask_agent] This row has no agent to jump to", vim.log.levels.INFO)
		return
	end
	jump_to_host(node.rec)
end

---@param node table
---@return table|nil anchor, boolean dispatched
local function node_anchor(node)
	if node.kind == "queued" then
		return node.entry.anchor, true
	end
	if node.task then
		-- A task another tool dispatched (todo2, a plugin over the bridge) carries
		-- the anchor it was filed against; a turn of your own only carries the
		-- cursor position when you asked, which is not where the task lives.
		return node.task.anchor, node.task.correlation ~= nil
	end
	return nil, false
end

---@param node table
local function jump_node(node)
	local anchor = node_anchor(node)
	if not anchor then
		notify.notify("[ask_agent] This row has no code anchor", vim.log.levels.INFO)
		return
	end
	-- open() is also called without the entry-point callbacks (a bare
	-- require("ask_agent.dashboard").open()), so fall back to the real jump
	local goto_anchor = (api and api.goto_anchor) or require("ask_agent").goto_anchor
	local ok, err = goto_anchor(anchor)
	if not ok then
		notify.notify("[ask_agent] " .. tostring(err), vim.log.levels.WARN)
	end
end

---@param node table
local function open_node(node)
	if node.kind == "more" then
		expanded_tasks[node.rec.key] = true
		render()
		return
	end
	if node.kind == "agent" then
		view_agent(node.rec)
		return
	end
	local anchor, dispatched = node_anchor(node)
	if not dispatched then
		-- your own turn: it lives in the agent's transcript, not at the cursor
		-- position it happened to be asked from
		view_agent(node.rec)
		return
	end
	if not anchor then
		-- a task sent from this very sidebar has no anchor: the agent's window is the best we can do
		notify.notify("[ask_agent] No anchor for this task — opening the agent instead", vim.log.levels.INFO)
		view_agent(node.rec)
		return
	end
	jump_node(node)
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

-- Keys, in the order they appear in the help float. `name` is what
-- `setup({ keys = { ... } })` overrides; a name bound to `false`
-- is not mapped at all. Semantics first: `R` renames (R), `v` views the diff,
-- `y` yanks, `r` refreshes, `s` sends, `d` deletes/dismisses, `J` jumps.
KEYS = {
	{ "help", "?", "Show these keys" },
	{
		"open",
		"<CR>",
		"Agent: show it in a viewer float · Task: jump to its anchor (dispatched tasks) or show the agent",
	},
	{ "jump", "J", "Jump to the agent's own window (rex/tmux), where it really runs" },
	{ "send", "s", "Send a question to that agent" },
	{ "send_queue", "S", "Send every queued question routed to it" },
	{ "ack", "a", "Acknowledge a done/blocked agent" },
	{ "dismiss", "d", "Delete the queued task · dismiss a dead agent" },
	{ "rename", "R", "Rename an agent (empty restores the directory name)" },
	{ "diff", "v", "Diff: the turn behind that task · the whole worktree for an agent" },
	{ "answer", "o", "Answer: the question and what the agent said back (results = true)" },
	{ "copy", "y", "Copy the task text" },
	{ "filter", "f", "Only agents that need you (blocked / error / unread done)" },
	{ "fold", { "<Tab>", "za" }, "Fold or unfold the agent's tasks (and the older-task row)" },
	{ "refresh", "r", "Poll every agent now" },
	{ "close", { "q", "<Esc>" }, "Close the sidebar" },
}

---One key for `name`, or nil when the user unbound it.
---@param name string
---@return string|string[]|nil
function keys_of(name)
	for _, item in ipairs(KEYS) do
		if item[1] == name then
			local key = cfg.keys[name]
			if key == nil then
				return item[2]
			end
			return key ~= false and key or nil
		end
	end
	return nil
end

---A key as the help float shows it: `<Tab>` stays, a list is joined with "/".
---@param key string|string[]
---@return string
function key_label(key)
	if type(key) == "table" then
		local out = {}
		for _, k in ipairs(key) do
			out[#out + 1] = k
		end
		return table.concat(out, "/")
	end
	return key
end

-- Sorting is intentional: whatever waits on a human comes first, then finished
-- work, then busy agents, then idle ones.
local ORDER_HINT = "Order: blocked/error · done · working · idle"

---Help float, bottom-right, `q` / `<Esc>` / `?` closes it.
local function show_help()
	local lines, bound = {}, {}
	for _, item in ipairs(KEYS) do
		local key = keys_of(item[1])
		if key then
			local label = key_label(key)
			lines[#lines + 1] = ("%-10s %s"):format(label, item[3])
			bound[#bound + 1] = { label, item[3] }
		end
	end
	local content = 0
	for _, line in ipairs(lines) do
		content = math.max(content, vim.fn.strdisplaywidth(line))
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = ORDER_HINT
	content = math.max(content, vim.fn.strdisplaywidth(ORDER_HINT))
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
	for i, item in ipairs(bound) do
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
	if not api then
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

	local function close()
		if win and vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end

	-- One handler per key name in KEYS; `kind` limits a handler to a row type.
	local function show_answer(node)
		if node.kind == "queued" then
			notify.notify("[ask_agent] That question is still queued: no answer yet", vim.log.levels.INFO)
			return
		end
		local task = node.task or (node.rec and node.rec.tasks and node.rec.tasks[1])
		if not task or not task.task_id then
			notify.notify("[ask_agent] No answer recorded for this task", vim.log.levels.INFO)
			return
		end
		local ok, err = require("ask_agent").show_answer(task)
		if not ok then
			notify.notify("[ask_agent] " .. (err or "could not show the answer"), vim.log.levels.INFO)
		end
	end

	local function show_diff(node)
		local ask = require("ask_agent")
		local rec = node.rec
		local cwd = rec and rec.target and rec.target.cwd or nil
		if node.kind == "agent" then
			ask.diff({ cwd = cwd })
			return
		end
		-- the turn this send opened is the precise diff; the correlation is the
		-- older fallback for tasks recorded before turn ids were kept
		local turn_id = node.kind ~= "queued" and node.task and node.task.turn_id
		if turn_id then
			ask.diff({ cwd = cwd, id = turn_id })
			return
		end
		local correlation = node.kind ~= "queued" and node.task and node.task.correlation
		if not correlation then
			notify.notify("[ask_agent] No turn recorded for this question yet", vim.log.levels.INFO)
			return
		end
		ask.diff({ cwd = cwd, correlation = correlation })
	end

	local function copy(node)
		local text
		if node.kind == "agent" then
			text = state.name(node.rec)
		elseif node.kind == "queued" then
			text = node.entry.prompt
		else
			text = node.task and node.task.text
		end
		if not text or text == "" then
			return
		end
		pcall(vim.fn.setreg, "+", text)
		pcall(vim.fn.setreg, '"', text)
		notify.notify("[ask_agent] Copied", vim.log.levels.INFO)
	end

	local function fold(node)
		if node.kind == "more" then
			expanded_tasks[node.rec.key] = true
			render()
			return
		end
		if node.kind ~= "agent" then
			return
		end
		if collapsed[node.rec.key] then
			collapsed[node.rec.key] = nil
		else
			collapsed[node.rec.key] = true
			-- folding is also "start over": unfold shows the recent slice again
			expanded_tasks[node.rec.key] = nil
		end
		render()
	end

	-- name -> { kind?, needs_node?, fn }: `kind` limits the mapping to that row
	-- type, `needs_node = false` keeps a global key working on a row that has no
	-- node (the "nothing needs you" line, or the blank line under a folded agent).
	local ACTIONS = {
		help = { needs_node = false, fn = show_help },
		open = { fn = open_node },
		answer = { fn = show_answer },
		jump = { fn = jump_host_node },
		send = {
			kind = "agent",
			fn = function(node)
				send_to(node.rec)
			end,
		},
		send_queue = {
			kind = "agent",
			fn = function(node)
				flush_queue(node.rec)
			end,
		},
		ack = {
			kind = "agent",
			fn = function(node)
				state.ack(node.rec.key)
			end,
		},
		dismiss = {
			fn = function(node)
				if node.kind == "queued" then
					queue.remove(node.entry.id)
				elseif node.kind == "agent" then
					dismiss(node.rec)
				end
			end,
		},
		rename = {
			kind = "agent",
			fn = function(node)
				rename(node.rec)
			end,
		},
		diff = { fn = show_diff },
		copy = { fn = copy },
		filter = {
			needs_node = false,
			fn = function()
				only_needs = not only_needs
				render()
			end,
		},
		fold = { fn = fold },
		refresh = {
			needs_node = false,
			fn = function()
				state.refresh()
				render()
			end,
		},
		close = { needs_node = false, fn = close },
	}

	for _, item in ipairs(KEYS) do
		local action = ACTIONS[item[1]]
		local key = keys_of(item[1])
		if action and key then
			local handler = (action.needs_node == false) and action.fn or with(action.kind, action.fn)
			local keys = type(key) == "table" and key or { key }
			for _, k in ipairs(keys) do
				vim.keymap.set("n", k, handler, opts_buf)
			end
		end
	end
end

---Dashboard appearance knobs (setup-level; per-call :AskAgentDashboard opts win).
---@param o { tree_lines?: boolean, running_line?: "dash"|"pulse"|"static"|"off", task_limit?: integer,
---          groups?: boolean, rail?: boolean, hl?: table<string, string>,
---          keys?: table<string, string|string[]|false> }|nil
function M.configure(o)
	if type(o) ~= "table" then
		return
	end
	if o.tree_lines ~= nil then
		cfg.tree_lines = o.tree_lines ~= false
	end
	if o.running_line ~= nil then
		local v = o.running_line
		cfg.running_line = (v == "pulse" or v == "static" or v == "off") and v or "dash"
	end
	if o.task_limit ~= nil then
		local n = math.floor(tonumber(o.task_limit) or 0)
		cfg.task_limit = (n and n > 0) and n or false
	end
	if o.groups ~= nil then
		cfg.groups = o.groups ~= false
	end
	if o.rail ~= nil then
		cfg.rail = o.rail ~= false
	end
	if type(o.hl) == "table" then
		-- one place to restyle the whole panel: state words, not colour literals
		for state, group in pairs(o.hl) do
			if HL[state] and type(group) == "string" then
				HL[state] = group
			end
		end
	end
	if type(o.keys) == "table" then
		-- merge, so a per-call :AskAgentDashboard keys = {...} does not wipe setup()
		cfg.keys = vim.tbl_extend("force", cfg.keys, o.keys)
	end
end

---Open (or focus) the sidebar.
---@param callbacks { send: function, batch_send: function, goto_anchor: function }|nil
---@param o { pos?: "left"|"right", width?: integer }|nil
function M.open(callbacks, o)
	api = callbacks or api
	-- mail-style answers (a hook that can only write a file) land before the first
	-- render, so the rows are already flagged on open
	local results = require("ask_agent.results")
	if results.enabled then
		pcall(results.import)
	end
	opts = vim.tbl_extend("force", { pos = "right", width = 40 }, o or {})
	opts.autowidth = not (o and o.width ~= nil)
	M.configure(opts)
	if win and vim.api.nvim_win_is_valid(win) then
		if vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage() then
			vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(win))
		end
		vim.api.nvim_set_current_win(win)
		opts.autowidth = false -- only the fresh sidebar sizes itself
		render()
		return
	end
	buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype, vim.bo[buf].bufhidden = "nofile", "wipe"
	vim.bo[buf].swapfile, vim.bo[buf].buflisted = false, false
	vim.bo[buf].filetype = "ask-agent-dashboard"
	vim.bo[buf].modifiable = false
	vim.api.nvim_buf_set_name(buf, "ask-agent://dashboard")
	-- The sidebar overrides number/signcolumn/winbar window-locally, and a jump
	-- into a fresh tab would inherit them; remember how a file window looks first.
	context.remember_look()
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
