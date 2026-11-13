-- lua/ask_agent/init.lua
---@brief Entry point for "write a question in nvim and send it, with the current anchor, to an external AI agent".
--
-- Structure:
--   context.lua   captures the anchor (cwd/tab/file:line/selection) — agent-agnostic
--   message.lua   renders the final text — every backend shares the same format
--   ui.lua        floating input — agent-agnostic
--   backends/*    only handles "sending the text out": pi uses a unix socket, generic uses tmux/commands
--   layouts/*     where agent instances sit on screen: rex reads `rex session inspect`, generic
--                 ships a tmux factory; anything else can be registered from a config
--   map.lua       draws that geometry as a floating map for target selection (:AskAgentPicker map|list)
--
-- Adding a new agent: write lua/ask_agent/backends/<name>.lua implementing { id, label, targets(), send() },
-- or declare it in setup with the tmux() factory from backends/generic.lua (restriction: delivers to an existing process).
-- Neither approach requires touching this file.
--
-- Public API: setup/ask/send/use/current/list/targets/pin/pinned/alias/alias_of/picker/generic/register/
--             layout/register_layout/batch_ask/batch_send/batch_route/batch_list/batch_delete
--             /batch_undo/batch_clear/batch_count/agents/on/statusline/wait/dashboard/goto_anchor/register_view/view/
--             register_jump/jump.
-- UI: :AskAgentDashboard (sidebar tree: agents + their tasks), ask_agent.statusline().

local backends = require("ask_agent.backends")
local notify = require("ask_agent.notify")
local generic = require("ask_agent.backends.generic")
local context = require("ask_agent.context")
local message = require("ask_agent.message")
local ui = require("ask_agent.ui")
local aliases = require("ask_agent.aliases")
local queue = require("ask_agent.queue")
local state = require("ask_agent.state")
local view = require("ask_agent.view")
local jump = require("ask_agent.jump")

local NS_LIST = vim.api.nvim_create_namespace("ask_agent.list")

local M = {}

--- Current default backend id
local current = "pi"
--- Matching strictness: exact (default, same cwd only) / related (allow parent and child dirs) / single (use it if it is the only one)
local matching = "exact"
--- Manually pinned target (:AskAgentTarget), takes precedence over cwd matching
local pinned = nil
--- Picker when there are multiple candidates: "map" (split map of the active layout adapter, default) / "list" (vim.ui.select list)
local picker = "map"
--- Also list recently exited instances in the picker, marked "not running" (they can never be
--- chosen; this exists so the user can see that the agent they expect is gone)
local show_stale = true

--- Which implementation the list picker uses: "auto" (ui-menu when installed, else vim.ui.select),
--- "ui_menu", or "vim_ui". The map always uses its own renderer.
local list_impl = "auto"

--- Frames for the busy spinner. Only the picker implementation decides whether it animates: menu.lua
--- honours `opts.tick` and re-renders every tick, passing the frame to `format_item(item, frame)`. Everywhere
--- else (telescope/fzf-lua/snacks/dropbar) the frame is nil and the first frame is shown static.
local default_spinner = require("ask_agent.icons").frames()
--- Active frames: `setup({ spinner = {...} })` can point this at the picker menu's own spinner
--- (e.g. `require("lib.menu").frames`) so the list and the map animate with the same glyphs.
local spinner = default_spinner

--- Animation interval in ms for the busy spinner (`setup({ tick = ... })`). Both pickers honour
--- `opts.tick`: the list picker re-renders every tick, the map repaints on a uv timer. Point it at
--- the picker menu's own interval (`require("lib.menu").config.tick`) to keep the cadence identical.
local tick = 90

--- Layout adapter id (nil = first available). See ask_agent.layouts
local layout_id = nil

--- Dashboard appearance (setup-level; per-call dashboard opts still win)
local dashboard_opts = {}

--- Viewer float defaults (setup-level; per-call view opts still win)
local view_opts = {}

--- Icon: the instance's own icon wins, then the icons table by instance id / backend id, finally the generic robot glyph.
--- Pickers use a consistent "icon name" layout so the agent is obvious at a glance
---@param mod table|nil
---@param t table|nil concrete instance (target), may carry its own icon
---@return string prefix with a trailing space
local function icon_prefix(mod, t)
	local icons = require("ask_agent.icons")
	local icon = (t and t.icon)
		or (type(mod and mod.icon) == "string" and mod.icon ~= "" and mod.icon)
		or icons.find(t and t.id)
		or icons.find(mod and mod.id)
		or icons.fallback
	return icon .. " "
end

--- Main icon color: instance color first (stable within a single run, so the same agent is the
---same color in list, map and queue marker), then the brand color
---@param mod table|nil
---@param t table|nil
---@return string|nil
local function icon_color(mod, t)
	local icons = require("ask_agent.icons")
	return icons.accent(icons.key(t)) or icons.color(t and t.id) or icons.color(mod and mod.id)
end

--- Name shown in lists: alias > instance label > id
---@param t table|nil
---@return string
local function name_of(t)
	return aliases.get(t, t and t.backend) or aliases.default_name(t)
end

--- Liveness of a candidate, probed once per picker (an instance can die between listing and
--- choosing). Stale candidates are never running.
---@param mod table
---@param c table candidate from backends.candidates
---@return { running: boolean, stale?: boolean, detail?: string }
local function candidate_status(mod, c)
	if not c._status then
		c._status = backends.probe(mod, c.target, c.stale)
		c._status.stale = c.stale or nil
	end
	return c._status
end

--- Picker prefix, straight from the state layer's vocabulary: filled dot = idle, half dot = a
---turn in progress (the question queues behind it), ⚠ = the agent is waiting for you (a send
---would sit in its prompt unread), ✓ = finished, hollow = gone / no state to report.
---@param st { running: boolean, state?: string, msg?: string, detail?: string }
---@return string mark, string|nil detail
local function status_mark(st)
	local icons = require("ask_agent.icons")
	if not st.running then
		return icons.ui("state", "gone"), st.detail or "not running"
	end
	if st.state == "blocked" then
		return icons.ui("state", "blocked"), st.msg or st.detail or "needs you"
	end
	if st.state == "done" then
		return icons.ui("state", "done"), st.msg or st.detail or "finished"
	end
	if st.state == "error" then
		return icons.ui("state", "error"), st.msg or st.detail or "error"
	end
	if st.state == "working" then
		return icons.ui("state", "working"), st.msg or st.detail or "busy"
	end
	if st.state == "unknown" then
		return icons.ui("state", "unknown"), st.detail
	end
	return icons.ui("state", "idle"), st.detail
end

--- Tell the user that a busy target will not answer right away (pi queues the message
--- as a follow-up and processes it after the current turn).
---@param mod table
---@param target table
---@param st { running: boolean, busy?: boolean }
local function note_busy(mod, target, st)
	if not st.busy then
		return
	end
	notify.notify(
		("[%s] %s is busy — the question is queued behind the current task"):format(
			mod.label or mod.id,
			name_of(target)
		),
		vim.log.levels.INFO
	)
end

local function pick_opts()
	return {
		related = matching == "related" or matching == "single",
		single = matching == "single",
	}
end

--- Resolve "backend + target". Fail with an error when either side is unavailable, so callers fail before opening a window
---@param id string|nil
---@param target_id string|nil
---@return table|nil mod, table|nil target, string|nil err
local function resolve(id, target_id)
	local mod = backends.get(id or current)
	if not mod then
		return nil, nil, ("No backend registered with id %s"):format(id or current)
	end
	-- Explicitly selected a managed instance (e.g. pi inside codecompanion): allowed, but explain the consequence first
	local function note_avoid(t)
		if t and t.avoid then
			notify.notify(("[%s] %s"):format(mod.label or mod.id, t.avoid), vim.log.levels.WARN)
		end
	end
	if target_id then
		for _, t in ipairs(mod.targets()) do
			if tostring(t.id) == target_id then
				note_avoid(t)
				return mod, t
			end
		end
		return nil,
			nil,
			("Target %s is not among the current instances of %s (it may have exited)"):format(
				target_id,
				mod.label or mod.id
			)
	end
	-- Manual pin wins: if the pinned target is gone, treat it as no pin
	if pinned and pinned.backend == mod.id then
		for _, t in ipairs(mod.targets()) do
			if tostring(t.id) == tostring(pinned.target) then
				note_avoid(t)
				return mod, t
			end
		end
		pinned = nil
	end
	local target, err = backends.pick(mod, vim.fn.getcwd(), pick_opts())
	if not target then
		return nil, nil, err
	end
	return mod, target
end

--- Pick a target interactively: pin > sole candidate (send directly) > picker.
--- This is what distinguishes a terminal pi from a codecompanion pi under the same cwd.
---@param mod table
---@param cb fun(target: table|nil)
--- Map candidates onto layout cells and show the map; returning false means "map unusable", so the caller falls back to the list
---@return boolean opened
--- Current floating windows (any float opened by the vim.ui.select implementation)
---@return table<integer, true>
local function float_wins()
	local out = {}
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		local cfg = vim.api.nvim_win_get_config(w)
		if cfg.relative ~= "" or cfg.external then
			out[w] = true
		end
	end
	return out
end

--- Close the floating window opened by vim.ui.select.
--- Implementations that expose a close() API are asked to close themselves first;
--- anything else is closed as a plain window (never a hard dependency on one plugin)
---@param win integer
local function close_menu(win)
	if not vim.api.nvim_win_is_valid(win) then
		return
	end
	local ok, menu = pcall(function()
		return require("dropbar.utils.menu").get({ win = win })
	end)
	if ok and menu and type(menu.close) == "function" then
		if pcall(menu.close, menu) then
			return
		end
	end
	pcall(vim.api.nvim_win_close, win, true)
end

--- Center the floating window on screen (most list implementations hug the cursor)
---@param win integer
local function center_win(win)
	if not vim.api.nvim_win_is_valid(win) then
		return
	end
	local cfg = vim.api.nvim_win_get_config(win)
	local h = vim.api.nvim_win_get_height(win)
	local w = vim.api.nvim_win_get_width(win)
	local rows = vim.o.lines - vim.o.cmdheight
	cfg.relative = "editor"
	cfg.win = nil
	cfg.external = nil
	cfg.anchor = "NW"
	cfg.row = math.max(0, math.floor((rows - h) / 2))
	cfg.col = math.max(0, math.floor((vim.o.columns - w) / 2))
	pcall(vim.api.nvim_win_set_config, win, cfg)
end

local STATE_HL = {
	idle = "AskAgentListIdle",
	working = "AskAgentListWorking",
	blocked = "AskAgentListBlocked",
	done = "AskAgentListDone",
	error = "AskAgentListError",
	gone = "AskAgentListGone",
	unknown = "AskAgentListIdle",
}

local function ensure_state_hl()
	for state, group in pairs(STATE_HL) do
		local link = ({
			working = "DiagnosticInfo",
			blocked = "DiagnosticWarn",
			done = "DiagnosticOk",
			error = "DiagnosticError",
			gone = "Comment",
			idle = "Comment",
			unknown = "Comment",
		})[state]
		pcall(vim.api.nvim_set_hl, 0, group, { link = link, default = true })
	end
end

local function state_group(st)
	if not st or not st.running then
		return STATE_HL.gone
	end
	return STATE_HL[st.state] or STATE_HL.idle
end

--- Paint each list item's icon with that instance's fixed color, and its leading
--- state glyph with the state color (the list has no per-item highlight API).
--- Menu name fields only allow a single highlight per line, so we set extmarks on the buffer ourselves.
---@param win integer
---@param mod table
---@param cands table[]
local function paint_list(win, mod, cands)
	if not vim.api.nvim_win_is_valid(win) then
		return
	end
	local buf = vim.api.nvim_win_get_buf(win)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	if #lines < #cands then
		return -- not a plain item list (has a header/summary), so do not guess positions
	end
	ensure_state_hl()
	local icons = require("ask_agent.icons")
	vim.api.nvim_buf_clear_namespace(buf, NS_LIST, 0, -1)
	for i, c in ipairs(cands) do
		local t = c.target
		local hl = icons.accent_hl(icons.key(t))
		local glyph = icon_prefix(mod, t):gsub("%s+$", "")
		local line = lines[i] or ""
		local s, e = line:find(glyph, 1, true)
		if hl and s then
			pcall(vim.api.nvim_buf_set_extmark, buf, NS_LIST, i - 1, s - 1, {
				end_col = e,
				hl_group = hl,
				strict = false,
			})
		end
		-- format_item starts with "#N  " then the state glyph; color just that glyph.
		local _, prefix_end = line:find("^#%d+%s+")
		if prefix_end then
			local ch = vim.fn.strcharpart(line:sub(prefix_end + 1), 0, 1)
			if ch ~= "" then
				pcall(vim.api.nvim_buf_set_extmark, buf, NS_LIST, i - 1, prefix_end, {
					end_col = prefix_end + #ch,
					hl_group = state_group(candidate_status(mod, c)),
					strict = false,
				})
			end
		end
	end
end

--- The old picker: a plain list that also includes candidates across tabs/windows (the map only covers the current window)
---@param back fun()|nil go back to the map (nil when the map is unavailable)
--- Pick the list implementation. ui-menu understands the centered layout and the <Tab>
--- round-trip, so it is preferred when available; everything else still works through
--- vim.ui.select.
local function list_ui(items, opts, on_choice)
	if list_impl ~= "vim_ui" then
		local ok, ui = pcall(require, "ui_menu")
		if ok and type(ui) == "table" and type(ui.select) == "function" then
			return ui.select(items, opts, on_choice)
		end
		if list_impl == "ui_menu" then
			notify.notify("[ask_agent] ui-menu is not installed; falling back to vim.ui.select", vim.log.levels.WARN)
		end
	end
	return vim.ui.select(items, opts, on_choice)
end

local function list_select(mod, cands, note_avoid, cb, back)
	local before = float_wins()
	-- Only record the choice here and hand it to cb *after* the post-processing below: on_choice fires before
	-- vim.ui.select returns, so calling cb inside would open the next float (the ask input) while we are still
	-- diffing "new floating windows" — that float would be mistaken for the menu, re-centered, painted and even
	-- get the <Tab> mapping. A blocking implementation chooses before we return (commit below); an async one
	-- (telescope/fzf-lua/snacks) chooses later, when `decorated` is already set. Cancelled (nil) means "do nothing".
	local chosen, decorated = nil, false
	local function commit(c)
		if not c then
			cb(nil) -- cancelled: callers with a question to answer need to hear "no"
			return
		end
		local st = candidate_status(mod, c)
		if not st.running then
			local mark, detail = status_mark(st)
			notify.notify(
				("[%s] %s is %s%s — not sent"):format(
					mod.label or mod.id,
					name_of(c.target),
					mark,
					detail and (" (" .. detail .. ")") or ""
				),
				vim.log.levels.WARN
			)
			return
		end
		note_busy(mod, c.target, st)
		note_avoid(c.target)
		cb(c.target)
	end
	-- An animation tick is only requested when some candidate is busy: static lists keep the old
	-- blocking read (no wakeups, identical behaviour). Implementations that ignore `tick` just show
	-- the first spinner frame instead of a rotating one.
	local animate = false
	for _, c in ipairs(cands) do
		local st = candidate_status(mod, c)
		if st.running and st.busy then
			animate = true
			break
		end
	end
	list_ui(cands, {
		prompt = ("Send to which %s%s? (:AskAgentTarget remembers the choice; <Tab> in the map also gets you here)"):format(
			icon_prefix(mod),
			mod.label or mod.id
		),
		tick = animate and tick or nil,
		-- ui-menu supports these; other implementations ignore unknown opts.
		-- The list is a screen-centered chooser, not a cursor-attached menu.
		position = "center",
		on_tab = back and function()
			vim.schedule(back)
		end or nil,
		format_item = function(c, frame)
			local t = c.target
			local st = candidate_status(mod, c)
			local mark, detail = status_mark(st)
			if st.running and st.busy then
				mark = spinner[(frame or 0) % #spinner + 1]
			end
			local parts = {
				("#%d"):format(t.index or 0),
				("%s %s%s"):format(mark, icon_prefix(mod, t), name_of(t)),
				vim.fn.fnamemodify(t.cwd or "?", ":~"),
			}
			if detail then
				table.insert(parts, ("(%s)"):format(detail))
			end
			if c.tier > 1 then
				table.insert(parts, "(not in current project)")
			end
			if t.avoid then
				table.insert(parts, "— replies only reach its host UI, not nvim")
			end
			return table.concat(parts, "  ")
		end,
	}, function(c)
		if decorated then
			commit(c)
		else
			chosen = c
		end
	end)

	-- The floating window that appeared: center it and paint each item's icon with the instance's fixed color;
	-- add a <Tab> back to the map when available
	-- (vim.ui.select has no key/position extension API, but it opens a regular floating window)
	local bufs = {}
	for w in pairs(float_wins()) do
		if not before[w] and vim.api.nvim_win_is_valid(w) then
			center_win(w)
			paint_list(w, mod, cands)
			if back then
				local buf = vim.api.nvim_win_get_buf(w)
				if not bufs[buf] then
					bufs[buf] = true
					-- Respect the host implementation: never take over a <Tab> that is already mapped
					-- (telescope/fzf-lua/snacks use it for multi-select and similar).
					local taken = false
					for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
						if m.lhs == "<Tab>" then
							taken = true
							break
						end
					end
					if not taken then
						vim.keymap.set("n", "<Tab>", function()
							close_menu(w)
							vim.schedule(back)
						end, { buffer = buf, nowait = true, silent = true })
					end
				end
			end
		end
	end

	-- Now the menu window is fully decorated (and, for blocking implementations, already closed): only then
	-- continue with the chosen target, so opening the ask input cannot be mistaken for the menu.
	decorated = true
	commit(chosen)
end

local function map_select(mod, cands, note_avoid, cb, switch)
	local layout = require("ask_agent.layouts").active(layout_id)
	if not layout then
		return false
	end
	local available = type(layout.available) ~= "function" and true or layout.available()
	if not available then
		return false
	end
	local window, data = layout.window()
	if not window then
		return false
	end

	-- The map is a picture of the window nvim lives in: a letter's position only
	-- means something inside that split layout. Agents in other Rex windows have
	-- no position on this canvas, so they are left out of `items` (the list is
	-- the picker for those, reachable through <Tab>).
	local map = require("ask_agent.map")
	local panes = layout.panes(window)
	if #panes == 0 then
		return false
	end

	local in_window = {}
	for _, pane in ipairs(panes) do
		in_window[pane.id] = true
	end

	local items, animate = {}, false
	for i, c in ipairs(cands) do
		-- The map cannot grey a cell out, so exited instances are list-only.
		-- Candidates outside this window's panes are list-only too: they have
		-- nowhere to be drawn, and cross-window letters would only confuse.
		local pane_id = (not c.stale) and layout.match(c.target) or nil
		if not c.stale and pane_id and in_window[pane_id] then
			local t = c.target
			local st = candidate_status(mod, c)
			local busy = st.running and (st.busy == true or st.state == "working")
			if busy then
				animate = true
			end
			local mark = status_mark(st)
			local state = (not st.running) and "gone" or (st.state or "idle")
			table.insert(items, {
				index = i,
				pane_id = pane_id,
				target = t,
				label = t.label,
				-- The map draws letters, but the selected cell can afford the name
				name = name_of(t),
				icon = icon_prefix(mod, t):gsub("%s+$", ""),
				icon_hl = icon_color(mod, t),
				-- The agent glyph stays put; a badge after the letter carries the state,
				-- and a running turn animates that badge (map.lua repaints per frame).
				status_glyph = mark,
				status_state = state,
				status_frames = busy and spinner or nil,
				tier = c.tier,
				status = st,
				busy = busy,
			})
		end
	end
	-- Nothing in this window: there is no cell to draw, so open the list, which
	-- is the only picker that reaches agents in other windows.
	if #items == 0 then
		return false
	end

	map.select({
		tick = animate and tick or nil,
		panes = panes,
		labels = type(layout.labels) == "function" and layout.labels(data) or {},
		items = items,
		cursor_pane = layout.cursor and layout.cursor() or nil,
		on_choose = function(item)
			if not item then
				return cb(nil) -- cancelled: callers with a question to answer need to hear "no"
			end
			if item.status and not item.status.running then
				local _, detail = status_mark(item.status)
				notify.notify(
					("[%s] %s is not running%s — not sent"):format(
						mod.label or mod.id,
						name_of(item.target),
						detail and (" (" .. detail .. ")") or ""
					),
					vim.log.levels.WARN
				)
				return
			end
			note_avoid(item.target)
			cb(item.target)
		end,
		-- <Tab> in the map: switch to the list (only the list shows cross-tab candidates)
		on_switch = function()
			switch()
		end,
	})
	return true
end

---@param o { single_direct?: boolean }|nil single_direct: a sole same-cwd candidate
---  goes out without opening the picker, even when a picker would normally open
local function choose_target(mod, cb, target_id, o)
	local function note_avoid(t)
		if t and t.avoid then
			notify.notify(("[%s] %s"):format(mod.label or mod.id, t.avoid), vim.log.levels.WARN)
		end
	end
	-- An explicitly requested instance skips both pin and picker: same semantics as
	-- ask.send({ target = ... }), so scripts and prompts can name the agent.
	if target_id ~= nil then
		for _, t in ipairs(mod.targets()) do
			if tostring(t.id) == tostring(target_id) then
				note_avoid(t)
				return cb(t)
			end
		end
		notify.notify(
			("[%s] Target %s is not among the current instances (it may have exited)"):format(
				mod.label or mod.id,
				tostring(target_id)
			),
			vim.log.levels.WARN
		)
		return cb(nil)
	end
	if pinned and pinned.backend == mod.id then
		for _, t in ipairs(mod.targets()) do
			if tostring(t.id) == tostring(pinned.target) then
				note_avoid(t)
				return cb(t)
			end
		end
		pinned = nil -- target exited, so the pin is naturally invalid
	end

	local cands =
		backends.candidates(mod, vim.fn.getcwd(), vim.tbl_extend("force", pick_opts(), { include_stale = show_stale }))
	local live = {}
	for _, c in ipairs(cands) do
		if not c.stale then
			live[#live + 1] = c
		end
	end
	if #live == 0 then
		local _, reason = backends.status(mod)
		notify.notify(("[%s] %s"):format(mod.label or mod.id, reason or "no available instances"), vim.log.levels.WARN)
		return cb(nil)
	end
	-- When the map can open, a sole exact-cwd candidate still goes through it: the
	-- map is the primary picker (and <Tab> reveals agents outside the layout).
	-- Without a layout there is nothing to draw, so keep the direct send.
	local map_ready = false
	if picker == "map" then
		local layout = require("ask_agent.layouts").active(layout_id)
		map_ready = layout ~= nil and (type(layout.available) ~= "function" or layout.available() == true)
	end
	if (not map_ready or (o and o.single_direct)) and #live == 1 and live[1].tier == 1 and not live[1].target.avoid then
		local st = candidate_status(mod, live[1])
		if st.running then
			note_busy(mod, live[1].target, st)
			return cb(live[1].target)
		end
	end

	-- Numbering + position on screen: the index stays consistent across list, map, and the send notification
	for i, c in ipairs(cands) do
		c.target.index = i
	end

	-- Map ⇄ list: both have <Tab>, so switching back and forth does not require cancel + re-trigger
	local show_list, open_map
	local function to_map()
		if open_map() then
			return
		end
		show_list() -- if the map cannot open this time (no layout adapter / candidates have no position), stay in the list
	end
	show_list = function()
		list_select(mod, cands, note_avoid, cb, to_map)
	end
	open_map = function()
		local ok, opened = pcall(map_select, mod, cands, note_avoid, cb, show_list)
		return ok and opened
	end

	if picker == "map" and open_map() then
		return
	end
	-- No layout adapter / candidates have no registered position / error → quietly fall back to the list
	show_list()
end

---One send that always records the dispatch: every path (ask, batch, API) goes through it.
---@param mod table backend
---@param target table instance
---@param text string
---@param opts { correlation?: table, anchor?: table }|nil
---@return boolean ok, string|nil err
local function deliver_text(mod, target, text, opts)
	-- What the journal keeps is the coordinate, not the source the question inlined
	-- (that is for the agent, and a task only needs somewhere to jump to).
	local full = opts and opts.anchor
	-- The digest is usually attached by message.render(); a caller that built the text
	-- elsewhere (the batch queue keeps its own copy of the anchor) still gets one here.
	-- Cached per root, so this is free after the first question in a project.
	if type(full) == "table" and full.digest == nil and full.root then
		full.digest = require("ask_agent.project").digest(full.root)
	end
	local anchor = require("ask_agent.context").lean(full)
	-- Backends that understand a structured anchor get the question alone plus the fields;
	-- everyone else gets the already-rendered text (question + block) untouched.
	local send_text = text
	if mod.anchor_payload and type(full) == "table" then
		send_text = require("ask_agent.message").question(text)
	end
	-- Turn boundary before the send: the agent may start writing the moment the text
	-- lands, so the tree has to be taken first. A failed send drops the record again.
	local snap = require("ask_agent.snapshot")
	local turn_ok, turn = pcall(snap.on_dispatch, mod.id, target.id, text, anchor, opts and opts.correlation)
	-- The agent gets an id it can quote back, so the answer lands on this exact task
	-- (the protocol has no message ids of its own). Generated before the send, since
	-- the answer may arrive before the bookkeeping below runs.
	local task_id = require("ask_agent.history").new_id()
	local ok, send_err = mod.send(target, send_text, { task_id = task_id, anchor = full })
	if not ok then
		if turn_ok and turn then
			pcall(snap.cancel, turn)
		end
		return false, send_err
	end
	-- History is the question ledger: only delivered text is recorded, and a broken
	-- journal never breaks a send.
	pcall(require("ask_agent.history").add, {
		id = task_id,
		text = text,
		backend = mod.id,
		agent = target.id,
		label = name_of(target),
		anchor = anchor,
		correlation = opts and opts.correlation,
	})
	state.dispatch(mod.id, target.id, text, {
		correlation = opts and opts.correlation,
		anchor = anchor,
		task_id = task_id,
		turn_id = turn_ok and turn and turn.id or nil,
	})
	return true, nil
end

-- Queued questions: routing and subset sending live in their own module
local batch = require("ask_agent.batch")
batch.attach({
	choose_target = choose_target,
	name_of = name_of,
	deliver_text = deliver_text,
	current = function()
		return current
	end,
})
M.batch_send, M.batch_route, M.batch_list = batch.send, batch.route, batch.list
M.batch_delete, M.batch_undo, M.batch_clear, M.batch_count = batch.delete_query, batch.undo, batch.clear, batch.count

--- Send text directly to the current backend (for reuse by other commands/plugins; skips the floating window)
---@param text string
---@param opts { backend?: string, target?: string, correlation?: table, anchor?: table,
---  pick?: boolean, on_sent?: fun(ok: boolean, err: string|nil) }|nil
---@return boolean ok, string? err
function M.send(text, opts)
	opts = opts or {}
	-- pick = the caller wants the human in the loop: an explicit target and a pin
	-- still win, a sole candidate still goes straight out (no pointless prompt),
	-- anything ambiguous opens the picker. The send happens in its callback, so
	-- this returns as soon as the question is on screen.
	if opts.pick and opts.target == nil then
		local mod = backends.get(opts.backend or current)
		if not mod then
			return false, ("No backend registered with id %s"):format(opts.backend or current)
		end
		choose_target(mod, function(target)
			if not target then
				if opts.on_sent then
					opts.on_sent(false, "no target chosen")
				end
				return
			end
			local ok, err = deliver_text(mod, target, text, opts)
			if not ok then
				notify.notify(("[%s] %s"):format(mod.label or mod.id, tostring(err)), vim.log.levels.WARN)
			end
			if opts.on_sent then
				opts.on_sent(ok, err)
			end
		end, nil, { single_direct = true })
		return true
	end
	local mod, target, err = resolve(opts.backend, opts.target)
	if not mod then
		return false, err
	end
	local ok, send_err = deliver_text(mod, target, text, { correlation = opts.correlation, anchor = opts.anchor })
	if opts.on_sent then
		opts.on_sent(ok, send_err)
	end
	return ok, send_err
end

---The newest task handed to an agent: { text, ts, status, correlation, anchor }.
---@param key string
---@return table|nil
function M.task(key)
	return state.task(key)
end

---Every observed agent instance, most attention-worthy first (blocked > done > error > working > idle).
---Fields: key, backend, id, state, kind, progress, msg, since, unread, gone, target,
---dispatch = { text, ts, correlation, anchor }, tasks = newest first, each { text, ts, status, correlation, anchor }.
---@param opts { state?: string, backend?: string, correlation?: table }|nil
---@return table[]
function M.agents(opts)
	return state.all(opts)
end

---Subscribe to state changes. Events: "state" (fn(rec, prev)), "update" (fn(rec), any change),
---"done", "blocked", "error" (same arguments as "state"). Returns an unsubscribe function.
---@param event string
---@param fn function
---@return fun()
function M.on(event, fn)
	return state.on(event, fn)
end

---One statusline chunk (`⠹2 ⚠1 ?1 ✓3`), empty when the rest of the world is quiet:
---
---    ⠹N  working (animated spinner; plain ◐ with `animated = false`)
---    ⚠N  blocked: needs your confirmation or credentials
---    ?N  blocked: waiting for an answer to a question
---    ✓N  finished and not looked at yet (acknowledging clears it)
---    ✗N  failed
---    ●N  idle, shown only when nothing above is happening
---
---The returned string has no highlight groups: it is plain text for
---`vim.o.statusline`, a lualine `%s` section or any other consumer.
---@param opts? { animated?: boolean, idle?: boolean|string }
---@return string
function M.statusline(opts)
	return state.statusline(opts)
end

---Jump to a code anchor (a table from ask_agent.context.capture, or an entry/anchor
---you kept around). Returns false + reason if the buffer is gone.
---@param anchor table
---@return boolean ok, string|nil err
function M.goto_anchor(anchor)
	return context.open(anchor)
end

---Open an agent in a viewer float: a second display attached to the terminal the
---agent already runs in (tmux / herdr / rex, or a provider you registered). The
---agent is not restarted and closing the float just detaches. Read-only viewers
---(rex) never forward input; `view.readonly = true` asks the host for a read-only
---client where it supports one (tmux `-r`).
---@param target table an instance descriptor (rec.target)
---@param opts { readonly?: boolean, width?: number, height?: number }|nil
---@return boolean ok, string|nil err
function M.view(target, opts)
	return view.open(target, vim.tbl_extend("force", view_opts, opts or {}))
end

---Register a view provider: the thing that shows an agent's terminal in a float.
---`{ id, can(target), cmd(target, opts), priority?, readonly_only? }` — rex, tmux
---and herdr are built in; see ask_agent/view.lua for the contract.
---@param mod table
function M.register_view(mod)
	view.register(mod)
end

---The registered view providers, in priority order.
---@return table[]
function M.views()
	return view.list()
end

---Bring the window an agent lives in to the front: the terminal app or
---multiplexer that owns it (rex, tmux, or a jump adapter you registered). `<CR>`
---in the sidebar shows the agent inside Neovim; this goes out to it instead.
---@param target table an instance descriptor (rec.target)
---@return boolean ok, string|nil err
function M.jump(target)
	return jump.focus(target)
end

---Register a jump adapter: the thing that brings an agent's window to the front.
---`{ id, can(target), focus(target), priority? }` — rex and tmux are built in;
---see ask_agent/jump.lua for the contract.
---@param mod table
function M.register_jump(mod)
	jump.register(mod)
end

---The registered jump adapters, in priority order.
---@return table[]
function M.jumps()
	return jump.list()
end

---Open the sidebar: agents as the top level of a tree, their tasks below.
---<CR> opens an agent in a viewer float (a task jumps to its code anchor),
---`o` jumps to a row's code anchor, `J` jumps out to the agent's own window,
---`s` sends, `S` flushes the queue routed to that agent, `a` acks, `d` deletes a
---queued task or dismisses a dead agent, `q` closes.
---@param opts { pos?: "left"|"right", width?: integer }|nil
function M.dashboard(opts)
	opts = vim.tbl_extend("force", dashboard_opts, opts or {})
	require("ask_agent.dashboard").open({
		send = M.send,
		batch_send = M.batch_send,
		goto_anchor = M.goto_anchor,
		view = M.view,
	}, opts)
end

---Call `cb(rec)` once the instance reaches `want` (`cb(nil)` on timeout).
---@param key string agent key (rec.key)
---@param want string "done" | "blocked" | ...
---@param timeout integer|nil ms
---@param cb fun(rec: table|nil)
function M.wait(key, want, timeout, cb)
	local off, fired
	local function finish(rec)
		if fired then
			return
		end
		fired = true
		if off then
			off()
		end
		cb(rec)
	end
	local rec = state.get(key)
	if rec and rec.state == want then
		return finish(rec)
	end
	off = state.on("state", function(r)
		if r.key == key and r.state == want then
			finish(r)
		end
	end)
	if timeout then
		vim.defer_fn(function()
			finish(nil)
		end, timeout)
	end
end

--- Open the floating window and ask. opts.visual=true includes the current selection
--- opts.extension: extra fields injected into the anchor (e.g. a project module digest); message.render decides the layout
--- opts.note: extra note appended to the floating window title (e.g. "overview ~350 tok")
---@param opts { visual?: boolean, backend?: string, target?: string|number, extension?: table, note?: string, default?: string, prompt_fn?: fun(anchor: table): string }|nil
function M.ask(opts)
	opts = opts or {}
	local mod = backends.get(opts.backend or current)
	if not mod then
		notify.notify(
			("[ask_agent] No backend registered with id %s"):format(opts.backend or current),
			vim.log.levels.WARN
		)
		return
	end
	-- The anchor must be captured before any UI: pickers and floating windows change the current window
	local anchor = context.capture(opts.visual)
	-- A template is rendered against *this* anchor, then prefilled for editing: the
	-- question the agent sees still travels with the anchor, like a hand-written one.
	local default = opts.default
	if type(opts.prompt_fn) == "function" then
		local rendered_ok, rendered = pcall(opts.prompt_fn, anchor)
		if rendered_ok and type(rendered) == "string" then
			default = rendered
		end
	end
	if opts.extension then
		for k, v in pairs(opts.extension) do
			anchor[k] = v
		end
	end
	choose_target(mod, function(target)
		if not target then
			return
		end
		ui.input({
			title = ("Ask %s (%s) · %s%s"):format(
				mod.label,
				name_of(target),
				context.describe(anchor),
				opts.note and (" · " .. opts.note) or ""
			),
			default = default,
			on_submit = function(prompt)
				local text = message.render(anchor, prompt)
				local ok, send_err = deliver_text(mod, target, text, { anchor = anchor })
				if not ok then
					notify.notify(("[%s] %s"):format(mod.label, send_err), vim.log.levels.WARN)
					return
				end
				local where = target.cwd and vim.fn.fnamemodify(target.cwd, ":~") or "?"
				notify.notify(
					("[%s] Sent → #%d %s (%s)"):format(mod.label, target.index or 0, name_of(target), where),
					vim.log.levels.INFO
				)
			end,
		})
	end, opts.target)
end

--- Queue a question for a later batch send instead of sending it now.
--- Same anchor capture as ask(), but the text goes into ask_agent.queue and is drawn
--- in the source buffer as a marker + virtual text.
---@param opts { visual?: boolean, backend?: string }|nil
function M.batch_ask(opts)
	opts = opts or {}
	local mod = backends.get(opts.backend or current)
	if not mod then
		notify.notify(
			("[ask_agent] No backend registered with id %s"):format(opts.backend or current),
			vim.log.levels.WARN
		)
		return
	end
	-- The anchor must be captured before the floating window opens
	local anchor = context.capture(opts.visual)
	ui.input({
		title = ("Batch %s · %s · %d queued"):format(mod.label, context.describe(anchor), queue.count()),
		on_submit = function(prompt)
			local entry = queue.add(anchor, prompt)
			notify.notify(
				("[ask_agent] Queued #%d (%d pending) — :AskAgentBatchSend sends them all"):format(
					entry.index,
					queue.count()
				),
				vim.log.levels.INFO
			)
		end,
	})
end

--- Switch the default backend
---@param id string
---@return boolean ok, string? err
function M.use(id)
	if not backends.get(id) then
		return false, ("No backend registered with id %s"):format(id)
	end
	current = id
	return true
end

---@return string
function M.current()
	return current
end

---@return table[]
function M.list()
	return backends.list()
end

--- List candidate targets for the current backend
---@param id string|nil
---@return table[]
function M.targets(id)
	local mod = backends.get(id or current)
	if not mod then
		return {}
	end
	local ok, list = pcall(mod.targets)
	if not ok or type(list) ~= "table" then
		return {}
	end
	for _, t in ipairs(list) do
		t.backend = t.backend or mod.id
	end
	return list
end

--- Manually set/clear the target (:AskAgentTarget / :AskAgentTarget!). Takes precedence over cwd matching
---@param target_id string|nil nil = clear
---@return boolean ok, string? err
function M.pin(target_id)
	if not target_id then
		pinned = nil
		return true
	end
	local mod, target, err = resolve(current, target_id)
	if not target then
		return false, err
	end
	pinned = { backend = mod.id, target = target.id }
	return true
end

---@return { backend: string, target: string }|nil
function M.pinned()
	return pinned
end

--- Give an instance an alias (used in lists/notifications instead of the pid). An empty or nil name clears it
---@param target table|string target or its id
---@param name string|nil
---@return boolean ok
function M.alias(target, name)
	if type(target) ~= "table" then
		local mod, found = resolve(current, target)
		target = found or { id = tostring(target) }
		if mod then
			target.backend = mod.id
		end
	end
	local ok = aliases.set(target, target.backend, name or "")
	require("ask_agent.state").invalidate_names()
	return ok
end

--- Read the alias
---@param target table|string|nil
---@return string|nil
function M.alias_of(target)
	if type(target) ~= "table" then
		local mod, found = resolve(current, target)
		target = found or { id = tostring(target) }
		if mod then
			target.backend = mod.id
		end
	end
	return aliases.get(target, target.backend)
end

--- Picker for multiple candidates, read/write: "map" (layout split map, default) or "list" (vim.ui.select)
---@param value string|nil read-only when omitted
---@return string
function M.picker(value)
	if value ~= nil then
		if value ~= "map" and value ~= "list" then
			notify.notify(("[ask_agent] Picker must be map or list (currently %s)"):format(picker), vim.log.levels.WARN)
		else
			picker = value
		end
	end
	return picker
end

--- List picker implementation, read/write: "auto" (ui-menu when installed, else vim.ui.select),
--- "ui_menu", or "vim_ui". The map always uses its own renderer.
---@param value string|nil read-only when omitted
---@return string
function M.list_impl(value)
	if value ~= nil then
		if value ~= "auto" and value ~= "ui_menu" and value ~= "vim_ui" then
			notify.notify(
				("[ask_agent] list_impl must be auto, ui_menu, or vim_ui (currently %s)"):format(list_impl),
				vim.log.levels.WARN
			)
		else
			list_impl = value
		end
	end
	return list_impl
end

--- Ready-made backend factory (tmux) for declaring a new agent in a few lines inside setup
M.generic = generic

--- Register a backend module (same as passing it through opts.extra)
---@param mod table
M.register = backends.register

--- Register a layout adapter (where instances sit on screen). nil/"auto" resets to first available
---@param mod table|string|nil
function M.register_layout(mod)
	if mod == nil then
		layout_id = nil
		return nil
	end
	layout_id = require("ask_agent.layouts").register(mod).id
	return layout_id
end

--- Layout adapter id, read/write
---@param value string|nil
---@return string|nil
function M.layout(value)
	if value ~= nil then
		layout_id = value == "auto" and nil or value
	end
	return layout_id
end

--- Turn snapshots and review ("what did the agent change")
-- -------------------------------------------------------------------

---Review one turn (or the whole worktree since HEAD when there is none).
---The interval is two git trees captured at the turn boundaries; rendering is delegated
---to the best installed viewer, so the evidence (`git diff <from> <to>`) is reproducible.
---@param opts { id?: string, cwd?: string, backend?: string, include_unsaved?: boolean }|nil
---@return boolean ok, string|nil err
function M.diff(opts)
	local ok, err = require("ask_agent.review").open(opts)
	if not ok then
		notify.notify("[ask_agent] " .. (err or "review failed"), vim.log.levels.WARN)
	end
	return ok, err
end

---Bracket a review interval by hand: no argument starts one, an id (or "last") closes it.
---@param id string|nil
---@return table|nil rec
function M.snapshot(id)
	local snap = require("ask_agent.snapshot")
	if id == nil or id == "" then
		local rec, err = snap.begin({ trigger = "manual" })
		if not rec then
			notify.notify("[ask_agent] snapshot: " .. (err or "failed"), vim.log.levels.WARN)
			return nil
		end
		notify.notify("[ask_agent] interval started (" .. rec.id:sub(1, 8) .. ")", vim.log.levels.INFO)
		return rec
	end
	local rec = id == "last" and snap.last(nil, { open = true }) or snap.get(id)
	if not rec then
		notify.notify("[ask_agent] no such turn: " .. id, vim.log.levels.WARN)
		return nil
	end
	snap.finish(rec)
	notify.notify("[ask_agent] interval closed (" .. rec.id:sub(1, 8) .. ")", vim.log.levels.INFO)
	return rec
end

---Turns recorded for a directory (or all of them), newest first.
---@param cwd string|nil
---@return table[]
function M.turns(cwd)
	return require("ask_agent.snapshot").list(cwd)
end

--- Recorded questions, newest first; filter by cwd, backend or free text.
---@param opts { cwd?: string, query?: string, backend?: string, limit?: integer }|nil
---@return table[]
function M.history(opts)
	return require("ask_agent.history").list(opts)
end

--- The agent's final answer to a recorded question (`results = true`), or nil.
---@param task_id string
---@return string|nil
function M.answer(task_id)
	local rec = require("ask_agent.history").get(task_id)
	return rec and rec.answer or nil
end

--- Show the question and its answer in a float (also used by the dashboard's `o`).
---@param task table|string  a state task, or a task id
---@return boolean ok, string|nil err
function M.show_answer(task)
	return require("ask_agent.results").show(task)
end

---Prompts visible from a directory: global first, project overrides by name.
---@param cwd string|nil
---@return table[]
function M.prompts(cwd)
	return require("ask_agent.prompts").all(cwd)
end

---Ask with a stored prompt: placeholders are rendered against the anchor captured now.
---@param name string
---@param opts { visual?: boolean, backend?: string, target?: string|number }|nil
---@return boolean ok, string|nil err
function M.prompt(name, opts)
	opts = opts or {}
	local prompts = require("ask_agent.prompts")
	local entry = prompts.get(name)
	if not entry then
		return false, "no prompt named " .. tostring(name)
	end
	M.ask({
		visual = opts.visual,
		backend = opts.backend,
		target = opts.target,
		note = "prompt: " .. entry.name,
		prompt_fn = function(anchor)
			return prompts.render(entry.text, anchor)
		end,
	})
	return true
end

---Create or update a prompt (`project = true` stores it in `.ask-agent/prompts.json`).
---@param name string
---@param text string
---@param opts { desc?: string, project?: boolean, cwd?: string }|nil
---@return boolean ok, string|nil err
function M.prompt_save(name, text, opts)
	return require("ask_agent.prompts").save(name, text, opts)
end

---Delete a prompt from where it is defined.
---@param name string
---@param opts { cwd?: string }|nil
---@return boolean ok, string|nil err
function M.prompt_remove(name, opts)
	return require("ask_agent.prompts").remove(name, opts)
end

--- Register backends and install the user commands.
--- The plugin installs no keymaps on purpose: commands are the public interface, and
--- keymaps belong to the user's config (see README "Usage").
--- `opts.layout` picks a layout adapter (default: first usable one, see ask_agent.layouts).
--- `opts.bridge` is forwarded to ask_agent.bridge (unless false), and `opts.aliases` to ask_agent.aliases when present.
---@param opts { default?: string, extra?: table[], matching?: string, picker?: string, show_stale?: boolean, layout?: string, icons?: table, icon_colors?: table, aliases?: table, map?: table, bridge?: table|false, spinner?: string[], tick?: integer, state_interval?: integer, state_notify?: boolean, notify?: table, notify_gap?: integer, notify_style?: boolean, notify_sound?: boolean, notify_sound_cmd?: string|string[], notify_belloff?: boolean, notify_popup?: boolean, notify_popup_ms?: integer, persist?: boolean|{ path?: string, enabled?: boolean }, tree_lines?: boolean, running_line?: string, task_limit?: integer, keys?: table, context_lines?: integer, max_selection?: integer, max_selection_bytes?: integer, project?: table, task_ttl?: integer, results?: boolean, snapshots?: table|false, history?: table, prompts?: table, review?: table, view?: table }|nil
function M.setup(opts)
	opts = opts or {}
	matching = opts.matching or "exact"
	picker = opts.picker or "map"
	show_stale = opts.show_stale ~= false
	if opts.list_impl ~= nil then
		M.list_impl(opts.list_impl)
	end
	layout_id = opts.layout or nil
	if type(opts.tick) == "number" and opts.tick > 0 then
		tick = opts.tick
	end
	require("ask_agent.icons").setup(opts.icons, opts.icon_colors)
	-- Map canvas size and labels: `map = { width = 0.25, name = true, ... }`
	require("ask_agent.map").setup(type(opts.map) == "table" and opts.map or nil)
	-- Empty/missing falls back to icons.ui.spinner (braille by default); equal-width glyphs are
	-- required (the map centers rows by cell width, the list just swaps one cell).
	spinner = (type(opts.spinner) == "table" and #opts.spinner > 0) and opts.spinner
		or require("ask_agent.icons").frames()
	backends.register(require("ask_agent.backends.pi"))
	for _, mod in ipairs(opts.extra or {}) do
		backends.register(mod)
	end
	current = opts.default or "pi"
	-- One poller for every backend; views subscribe instead of polling on their own
	state.notify = opts.state_notify ~= false
	-- Per-state notification copy, level and bell (see README "Notifications")
	state.configure({ messages = opts.notify, gap = opts.notify_gap })
	-- How much source a question inlines on its own (unsaved buffers, diffs)
	require("ask_agent.context").setup({
		lines = opts.context_lines,
		max_selection = opts.max_selection,
		max_selection_bytes = opts.max_selection_bytes,
	})
	-- What a question says about the project it is asked in (the digest; the anchor is
	-- captured with the question itself). See README "What a question carries".
	require("ask_agent.project").setup(opts.project)
	-- Notification house style: bold + level colour, optional terminal bell
	require("ask_agent.notify").setup({
		style = opts.notify_style,
		sound = opts.notify_sound,
		sound_cmd = opts.notify_sound_cmd,
		respect_belloff = opts.notify_belloff,
		popup = opts.notify_popup,
		popup_ms = opts.notify_popup_ms,
	})
	-- Sidebar tree: connectors between agents and tasks, and the green path to the running task
	dashboard_opts = {
		tree_lines = opts.tree_lines,
		running_line = opts.running_line,
		task_limit = opts.task_limit,
		-- Dashboard keymap overrides; false unbinds a name (see ask_agent.dashboard.KEYS)
		keys = opts.keys,
	}
	-- How long finished tasks stay in the journal (one per agent always stays)
	if type(opts.task_ttl) == "number" and opts.task_ttl > 0 then
		state.task_ttl = opts.task_ttl
	end
	-- Journal (tasks/unread marks survive a restart): true | false | { path, persist }
	local persist = opts.persist
	if type(persist) == "table" then
		state.journal_path = persist.path
		state.persist = persist.enabled ~= false
	else
		state.persist = persist ~= false
	end
	-- Turn snapshots (what did the agent change): git trees taken at turn boundaries.
	-- `snapshots = false` disables them; a table configures keep/ttl/trigger_state/path.
	local snap = require("ask_agent.snapshot")
	if opts.snapshots == false then
		snap.enabled = false
	else
		snap.setup(type(opts.snapshots) == "table" and opts.snapshots or nil)
		snap.attach(state)
	end
	-- Question history (searchable, re-askable) and the prompt library: both are
	-- side channels that never touch the send path's contract.
	local hist = require("ask_agent.history")
	if opts.history == false then
		hist.enabled = false
	else
		hist.setup(type(opts.history) == "table" and opts.history or nil)
	end
	-- Answers (`results = true`) are opt-in: they turn the ledger into a little
	-- transcript, which is exactly what history alone promises not to keep.
	local results = require("ask_agent.results")
	results.enabled = opts.results == true
	hist.answers = results.enabled
	if results.enabled then
		results.attach(state)
	end
	local prompts = require("ask_agent.prompts")
	if type(opts.prompts) == "table" then
		if opts.prompts.global_path then
			prompts.global_path = opts.prompts.global_path
		end
		if opts.prompts.project_file then
			prompts.project_file = opts.prompts.project_file
		end
	end
	-- Review rendering: "auto" picks the best installed viewer (diffbandit → builtin
	-- nvim.difftool → codediff → a plain diff buffer).
	local review = require("ask_agent.review")
	local ropts = type(opts.review) == "table" and opts.review or {}
	if ropts.backend then
		review.backend = ropts.backend
	end
	if ropts.include_unsaved ~= nil then
		review.include_unsaved = ropts.include_unsaved
	end
	-- Viewer floats: a second display for an agent that lives in tmux/herdr/rex.
	local vopts = type(opts.view) == "table" and opts.view or {}
	view_opts = {
		readonly = vopts.readonly == true,
		width = vopts.width,
		height = vopts.height,
	}
	state.start(opts.state_interval or 2000)
	local grp = vim.api.nvim_create_augroup("AskAgentState", { clear = true })
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = grp,
		callback = function()
			view.stop_all()
			state.flush()
			state.stop()
		end,
	})

	-- Bridge to the external agent (RPC socket); a bridge failure must never break setup
	if opts.bridge ~= false then
		pcall(function()
			require("ask_agent.bridge").setup(opts.bridge)
		end)
		pcall(function()
			require("ask_agent.bridge").attach()
		end)
	end
	-- Alias storage may not expose setup yet (another module owns it)
	if opts.aliases then
		pcall(function()
			require("ask_agent.aliases").setup(opts.aliases)
		end)
	end

	require("ask_agent.commands").install({
		api = M,
		icon_prefix = icon_prefix,
		name_of = name_of,
		current = function()
			return current
		end,
		backends = backends,
		aliases = aliases,
	})
end

return M
