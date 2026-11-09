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
--             layout/register_layout/batch_ask/batch_send/batch_list/batch_delete/batch_undo
--             /batch_clear/batch_count.

local backends = require("ask_agent.backends")
local generic = require("ask_agent.backends.generic")
local context = require("ask_agent.context")
local message = require("ask_agent.message")
local ui = require("ask_agent.ui")
local aliases = require("ask_agent.aliases")
local queue = require("ask_agent.queue")

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

--- Frames for the busy spinner. Only the picker implementation decides whether it animates: menu.lua
--- honours `opts.tick` and re-renders every tick, passing the frame to `format_item(item, frame)`. Everywhere
--- else (telescope/fzf-lua/snacks/dropbar) the frame is nil and the first frame is shown static.
local default_spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
--- Active frames: `setup({ spinner = {...} })` can point this at the picker menu's own spinner
--- (e.g. `require("lib.menu").frames`) so the list and the map animate with the same glyphs.
local spinner = default_spinner

--- Animation interval in ms for the busy spinner (`setup({ tick = ... })`). Both pickers honour
--- `opts.tick`: the list picker re-renders every tick, the map repaints on a uv timer. Point it at
--- the picker menu's own interval (`require("lib.menu").config.tick`) to keep the cadence identical.
local tick = 90

--- Layout adapter id (nil = first available). See ask_agent.layouts
local layout_id = nil

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

--- Instance color (matching color in list and map): preferred over the brand color — otherwise two instances of the same brand are indistinguishable
---@param t table|nil
---@return string|nil
local function inst_key(t)
	if type(t) ~= "table" or t.id == nil then
		return nil
	end
	return ("%s:%s"):format(tostring(t.id), tostring(t.ts or ""))
end

--- Main icon color: instance color first (stable within a single run), then the brand color
---@param mod table|nil
---@param t table|nil
---@return string|nil
local function icon_color(mod, t)
	local icons = require("ask_agent.icons")
	return icons.accent(inst_key(t)) or icons.color(t and t.id) or icons.color(mod and mod.id)
end

--- Name shown in lists: alias > instance label > id
---@param t table|nil
---@return string
local function name_of(t)
	return aliases.get(t) or (t and (t.label or t.id)) or "?"
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

--- Picker prefix: filled dot = idle, half dot = busy (the question gets queued as a
---follow-up), hollow dot = gone. The detail text ("busy", "process exited", ...) rides along.
---@param st { running: boolean, busy?: boolean, stale?: boolean, detail?: string }
---@return string mark, string|nil detail
local function status_mark(st)
	if st.stale then
		return "○", st.detail or "exited"
	end
	if not st.running then
		return "○", st.detail or "not running"
	end
	if st.busy then
		return "◐", st.detail or "busy"
	end
	return "●", st.detail
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
	vim.notify(
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
			vim.notify(("[%s] %s"):format(mod.label or mod.id, t.avoid), vim.log.levels.WARN)
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

--- Paint each list item's icon with that instance's fixed color.
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
	local icons = require("ask_agent.icons")
	vim.api.nvim_buf_clear_namespace(buf, NS_LIST, 0, -1)
	for i, c in ipairs(cands) do
		local t = c.target
		local hl = icons.accent_hl(inst_key(t))
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
	end
end

--- The old picker: a plain list that also includes candidates across tabs/windows (the map only covers the current window)
---@param back fun()|nil go back to the map (nil when the map is unavailable)
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
			return
		end
		local st = candidate_status(mod, c)
		if not st.running then
			local mark, detail = status_mark(st)
			vim.notify(
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
	vim.ui.select(cands, {
		prompt = ("Send to which %s%s? (:AskAgentTarget remembers the choice; <Tab> in the map also gets you here)"):format(
			icon_prefix(mod),
			mod.label or mod.id
		),
		tick = animate and tick or nil,
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
	local panes = layout.panes(window)
	if #panes == 0 then
		return false
	end

	local in_window = {}
	for _, pane in ipairs(panes) do
		in_window[pane.id] = true
	end

	local items, located, animate = {}, 0, false
	for i, c in ipairs(cands) do
		-- The map cannot grey a cell out, so exited instances are list-only
		if not c.stale then
			local t = c.target
			local pane_id = layout.match(t)
			if pane_id and in_window[pane_id] then
				located = located + 1
			end
			local st = candidate_status(mod, c)
			local busy = st.running and st.busy == true
			if busy then
				animate = true
			end
			table.insert(items, {
				index = i,
				pane_id = pane_id,
				target = t,
				label = t.label,
				name = vim.fn.fnamemodify(t.cwd or "?", ":t"),
				icon = icon_prefix(mod, t):gsub("%s+$", ""),
				-- busy cells get a rotating icon instead of the agent glyph (map.lua repaints per frame)
				icon_frames = busy and spinner or nil,
				icon_hl = icon_color(mod, t),
				tier = c.tier,
				status = st,
				busy = busy,
			})
		end
	end
	-- With only 1 locatable pane the map is meaningless (the user cannot see where the others are), so fall back to the list
	if located < 2 then
		return false
	end

	require("ask_agent.map").select({
		tick = animate and tick or nil,
		panes = panes,
		labels = type(layout.labels) == "function" and layout.labels(data) or {},
		items = items,
		cursor_pane = layout.cursor and layout.cursor() or nil,
		on_choose = function(item)
			if not item then
				return -- cancelled: do nothing
			end
			if item.status and not item.status.running then
				local _, detail = status_mark(item.status)
				vim.notify(
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

local function choose_target(mod, cb)
	local function note_avoid(t)
		if t and t.avoid then
			vim.notify(("[%s] %s"):format(mod.label or mod.id, t.avoid), vim.log.levels.WARN)
		end
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
		vim.notify(("[%s] %s"):format(mod.label or mod.id, reason or "no available instances"), vim.log.levels.WARN)
		return cb(nil)
	end
	-- Sole exact-cwd candidate: no picker at all, unless its process just went away
	-- (then the picker opens with it marked "not running", instead of silently sending into the void)
	if #live == 1 and live[1].tier == 1 and not live[1].target.avoid then
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

--- Send text directly to the current backend (for reuse by other commands/plugins; skips the floating window)
---@param text string
---@param opts { backend?: string, target?: string }|nil
---@return boolean ok, string? err
function M.send(text, opts)
	local mod, target, err = resolve(opts and opts.backend, opts and opts.target)
	if not mod then
		return false, err
	end
	local ok, send_err = mod.send(target, text)
	if not ok then
		return false, send_err
	end
	return true, nil
end

--- Open the floating window and ask. opts.visual=true includes the current selection
--- opts.extension: extra fields injected into the anchor (e.g. a project module digest); message.render decides the layout
--- opts.note: extra note appended to the floating window title (e.g. "overview ~350 tok")
---@param opts { visual?: boolean, backend?: string, extension?: table, note?: string }|nil
function M.ask(opts)
	opts = opts or {}
	local mod = backends.get(opts.backend or current)
	if not mod then
		vim.notify(
			("[ask_agent] No backend registered with id %s"):format(opts.backend or current),
			vim.log.levels.WARN
		)
		return
	end
	-- The anchor must be captured before any UI: pickers and floating windows change the current window
	local anchor = context.capture(opts.visual)
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
			on_submit = function(prompt)
				local ok, send_err = mod.send(target, message.render(anchor, prompt))
				if not ok then
					vim.notify(("[%s] %s"):format(mod.label, send_err), vim.log.levels.WARN)
					return
				end
				local where = target.cwd and vim.fn.fnamemodify(target.cwd, ":~") or "?"
				vim.notify(
					("[%s] Sent → #%d %s (%s)"):format(mod.label, target.index or 0, name_of(target), where),
					vim.log.levels.INFO
				)
			end,
		})
	end)
end

--- Queue a question for a later batch send instead of sending it now.
--- Same anchor capture as ask(), but the text goes into ask_agent.queue and is drawn
--- in the source buffer as a marker + virtual text.
---@param opts { visual?: boolean, backend?: string }|nil
function M.batch_ask(opts)
	opts = opts or {}
	local mod = backends.get(opts.backend or current)
	if not mod then
		vim.notify(
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
			vim.notify(
				("[ask_agent] Queued #%d (%d pending) — :AskAgentBatchSend sends them all"):format(
					entry.index,
					queue.count()
				),
				vim.log.levels.INFO
			)
		end,
	})
end

--- Send every queued question, one message each, to a single target chosen once.
--- Successfully sent entries are removed (their markers disappear); failed ones stay queued.
---@param opts { backend?: string }|nil
---@return boolean ok
function M.batch_send(opts)
	opts = opts or {}
	local pending = queue.list()
	if #pending == 0 then
		vim.notify("[ask_agent] Batch queue is empty", vim.log.levels.INFO)
		return false
	end
	local mod = backends.get(opts.backend or current)
	if not mod then
		vim.notify(
			("[ask_agent] No backend registered with id %s"):format(opts.backend or current),
			vim.log.levels.WARN
		)
		return false
	end
	choose_target(mod, function(target)
		if not target then
			return
		end
		local sent, failed = 0, {}
		for _, entry in ipairs(pending) do
			local index = entry.index
			local anchor = queue.sync(entry)
			local ok, send_err = mod.send(target, message.render(anchor, entry.prompt))
			if ok then
				sent = sent + 1
				queue.remove(entry.id)
			else
				table.insert(failed, { index = index, err = send_err })
			end
		end
		if sent > 0 then
			local where = target.cwd and vim.fn.fnamemodify(target.cwd, ":~") or "?"
			vim.notify(
				("[%s] Sent %d batched question(s) → #%d %s (%s)"):format(
					mod.label,
					sent,
					target.index or 0,
					name_of(target),
					where
				),
				vim.log.levels.INFO
			)
		end
		for _, f in ipairs(failed) do
			vim.notify(
				("[%s] Batch #%d failed: %s"):format(mod.label, f.index, f.err or "unknown error"),
				vim.log.levels.WARN
			)
		end
	end)
	return true
end

--- Jump to the code an entry is attached to.
---@param entry table
local function goto_entry(entry)
	local buf = entry.buf
	if not vim.api.nvim_buf_is_valid(buf) then
		vim.notify("[ask_agent] The buffer of this anchor no longer exists", vim.log.levels.WARN)
		return
	end
	if entry.bufname ~= "" and vim.api.nvim_buf_get_name(buf) ~= entry.bufname then
		vim.notify("[ask_agent] The buffer number was reused by another file", vim.log.levels.WARN)
		return
	end
	local win = vim.fn.bufwinid(buf)
	if win ~= -1 then
		vim.api.nvim_set_current_win(win)
	else
		vim.api.nvim_set_current_buf(buf)
	end
	local line = math.max(1, math.min(entry.line or 1, vim.api.nvim_buf_line_count(buf)))
	vim.api.nvim_win_set_cursor(0, { line, entry.col or 0 })
	vim.cmd("normal! zz")
end

--- List queued questions: jump / edit / delete.
function M.batch_list()
	local list = queue.list()
	if #list == 0 then
		vim.notify("[ask_agent] Batch queue is empty", vim.log.levels.INFO)
		return
	end
	local function describe(entry)
		local a = entry.anchor
		local first = (entry.prompt:gsub("\n.*", ""))
		return ("#%d  %s:%d  %s"):format(entry.index, a.path or "<no filename>", entry.line or 1, first)
	end
	vim.ui.select(list, {
		prompt = ("Queued questions (%d)"):format(#list),
		format_item = describe,
	}, function(entry)
		if not entry then
			return
		end
		vim.ui.select({ "jump to code", "edit question", "delete" }, {
			prompt = describe(entry),
		}, function(action)
			if action == "jump to code" then
				goto_entry(entry)
			elseif action == "edit question" then
				ui.input({
					title = ("Edit #%d · %s"):format(entry.index, context.describe(entry.anchor)),
					default = entry.prompt,
					on_submit = function(text)
						queue.update(entry.id, text)
					end,
				})
			elseif action == "delete" then
				queue.remove(entry.id)
				vim.notify(
					("[ask_agent] Deleted queued question #%d (:AskAgentBatchUndo restores it)"):format(entry.index),
					vim.log.levels.INFO
				)
			end
		end)
	end)
end

--- Delete the queued question(s) sitting on the cursor line of the current buffer.
--- With several entries on the line, asks which one; undo with M.batch_undo().
function M.batch_delete()
	local buf = vim.api.nvim_get_current_buf()
	local line = vim.api.nvim_win_get_cursor(0)[1]
	local hits = {}
	for _, it in ipairs(queue.list()) do
		if it.buf == buf then
			queue.sync(it)
			if it.line == line then
				table.insert(hits, it)
			end
		end
	end
	if #hits == 0 then
		vim.notify(
			("[ask_agent] No queued question on this line (queue has %d)"):format(queue.count()),
			vim.log.levels.INFO
		)
		return
	end
	local function drop(entry)
		queue.remove(entry.id)
		vim.notify(("[ask_agent] Deleted queued question on line %d (:AskAgentBatchUndo restores it)"):format(line))
	end
	if #hits == 1 then
		return drop(hits[1])
	end
	vim.ui.select(hits, {
		prompt = ("%d queued questions on this line"):format(#hits),
		format_item = function(entry)
			return ("#%d  %s"):format(entry.index, (entry.prompt:gsub("\n.*", "")))
		end,
	}, function(entry)
		if entry then
			drop(entry)
		end
	end)
end

--- Undo the last delete (or clear): put the question(s) back with their markers.
function M.batch_undo()
	local restored, skipped, label = queue.undo()
	if not label then
		vim.notify("[ask_agent] Nothing to undo in the batch queue", vim.log.levels.INFO)
		return
	end
	local msg = ("[ask_agent] Restored %d queued question(s) from last %s"):format(restored, label)
	if skipped > 0 then
		msg = msg .. (" (%d skipped: buffer was wiped)"):format(skipped)
	end
	vim.notify(msg, skipped > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
end

--- Drop every queued question and its marker. Undoable with M.batch_undo().
function M.batch_clear()
	local n = queue.count()
	if n == 0 then
		vim.notify("[ask_agent] Batch queue is empty", vim.log.levels.INFO)
		return
	end
	queue.clear()
	vim.notify(
		("[ask_agent] Cleared %d queued question(s) (:AskAgentBatchUndo restores them)"):format(n),
		vim.log.levels.INFO
	)
end

---@return integer
function M.batch_count()
	return queue.count()
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
	return ok and list or {}
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
		target = { id = target }
	end
	return aliases.set(target, name or "")
end

--- Read the alias
---@param target table|string|nil
---@return string|nil
function M.alias_of(target)
	if type(target) ~= "table" then
		target = { id = target }
	end
	return aliases.get(target)
end

--- Picker for multiple candidates, read/write: "map" (layout split map, default) or "list" (vim.ui.select)
---@param value string|nil read-only when omitted
---@return string
function M.picker(value)
	if value ~= nil then
		if value ~= "map" and value ~= "list" then
			vim.notify(("[ask_agent] Picker must be map or list (currently %s)"):format(picker), vim.log.levels.WARN)
		else
			picker = value
		end
	end
	return picker
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

--- Register backends and install the user commands.
--- The plugin installs no keymaps on purpose: commands are the public interface, and
--- keymaps belong to the user's config (see README "Usage").
--- `opts.layout` picks a layout adapter (default: first usable one, see ask_agent.layouts).
--- `opts.bridge` is forwarded to ask_agent.bridge (unless false), and `opts.aliases` to ask_agent.aliases when present.
---@param opts { default?: string, extra?: table[], matching?: string, picker?: string, show_stale?: boolean, layout?: string, icons?: table, icon_colors?: table, aliases?: table, bridge?: table|false, spinner?: string[], tick?: integer }|nil
function M.setup(opts)
	opts = opts or {}
	matching = opts.matching or "exact"
	picker = opts.picker or "map"
	show_stale = opts.show_stale ~= false
	layout_id = opts.layout or nil
	-- Empty/missing falls back to the built-in braille frames; equal-width glyphs are required
	-- (the map centers rows by cell width, the list just swaps one cell).
	if type(opts.spinner) == "table" and #opts.spinner > 0 then
		spinner = opts.spinner
	end
	if type(opts.tick) == "number" and opts.tick > 0 then
		tick = opts.tick
	end
	require("ask_agent.icons").setup(opts.icons, opts.icon_colors)
	backends.register(require("ask_agent.backends.pi"))
	for _, mod in ipairs(opts.extra or {}) do
		backends.register(mod)
	end
	current = opts.default or "pi"

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

	vim.api.nvim_create_user_command("AskAgent", function()
		M.ask()
	end, { desc = "Ask agent: open a floating window and send the question with the current anchor" })
	vim.api.nvim_create_user_command("AskAgentVisual", function()
		M.ask({ visual = true })
	end, { desc = "Ask agent: like AskAgent but includes the current selection" })
	vim.api.nvim_create_user_command("AskAgentBatch", function()
		M.batch_ask()
	end, { desc = "Ask agent: queue a question at the cursor instead of sending it now" })
	vim.api.nvim_create_user_command("AskAgentBatchVisual", function()
		M.batch_ask({ visual = true })
	end, { desc = "Ask agent: queue a question anchored to the current selection" })
	vim.api.nvim_create_user_command("AskAgentBatchSend", function()
		M.batch_send()
	end, { desc = "Ask agent: send every queued question (one message each) to one target" })
	vim.api.nvim_create_user_command("AskAgentBatchList", function()
		M.batch_list()
	end, { desc = "Ask agent: list queued questions (jump/edit/delete)" })
	vim.api.nvim_create_user_command("AskAgentBatchDelete", function()
		M.batch_delete()
	end, { desc = "Ask agent: delete the queued question on the cursor line (undoable)" })
	vim.api.nvim_create_user_command("AskAgentBatchUndo", function()
		M.batch_undo()
	end, { desc = "Ask agent: undo the last queue delete/clear" })
	vim.api.nvim_create_user_command("AskAgentBatchClear", function()
		M.batch_clear()
	end, { desc = "Ask agent: drop every queued question (undoable)" })
	-- Legacy name
	vim.api.nvim_create_user_command("AskAgentPi", function()
		M.ask()
	end, { desc = "Ask agent: same as :AskAgent (legacy name)" })
	vim.api.nvim_create_user_command("AskAgentBackend", function(args)
		if args.args ~= "" then
			local ok, err = M.use(args.args)
			if not ok then
				vim.notify("[ask_agent] " .. err, vim.log.levels.WARN)
			else
				vim.notify("[ask_agent] Current backend → " .. args.args, vim.log.levels.INFO)
			end
			return
		end
		local items = M.list()
		vim.ui.select(items, {
			prompt = "Ask agent backend (current: " .. current .. ")",
			format_item = function(item)
				return ("%s%s%s"):format(icon_prefix(item), item.label, item.available and "" or " (unavailable)")
			end,
		}, function(item)
			if item then
				M.use(item.id)
			end
		end)
	end, {
		nargs = "?",
		complete = function()
			local out = {}
			for _, item in ipairs(M.list()) do
				table.insert(out, item.id)
			end
			return out
		end,
		desc = "Ask agent: select or switch the default backend",
	})

	vim.api.nvim_create_user_command("AskAgentPicker", function(args)
		local want = args.args ~= "" and args.args or (picker == "map" and "list" or "map")
		if want ~= "map" and want ~= "list" then
			vim.notify(("[ask_agent] Picker must be map or list (currently %s)"):format(picker), vim.log.levels.WARN)
			return
		end
		picker = want
		vim.notify(("[ask_agent] Picker for multiple candidates → %s"):format(picker), vim.log.levels.INFO)
	end, {
		nargs = "?",
		complete = function()
			return { "map", "list" }
		end,
		desc = "Ask agent: picker for multiple candidates (map=split map, list=list)",
	})

	vim.api.nvim_create_user_command("AskAgentTarget", function(args)
		if args.bang then
			M.pin(nil)
			vim.notify("[ask_agent] Cleared the manually pinned target", vim.log.levels.INFO)
			return
		end
		local items = M.targets()
		if args.args ~= "" then
			local ok, err = M.pin(args.args)
			if not ok then
				vim.notify("[ask_agent] " .. err, vim.log.levels.WARN)
			else
				vim.notify("[ask_agent] Target pinned to " .. args.args, vim.log.levels.INFO)
			end
			return
		end
		if #items == 0 then
			vim.notify("[ask_agent] Current backend has no available targets", vim.log.levels.WARN)
			return
		end
		for i, it in ipairs(items) do
			it.index = i
		end
		vim.ui.select(items, {
			prompt = "Pin sends to which target (:AskAgentTarget! to cancel)",
			format_item = function(item)
				return ("#%d %s%s  %s"):format(
					item.index or 0,
					icon_prefix(backends.get(current)),
					name_of(item),
					item.cwd or "?"
				)
			end,
		}, function(item)
			if item then
				M.pin(tostring(item.id))
			end
		end)
	end, { nargs = "?", bang = true, desc = "Ask agent: pin or clear the target used for sending" })

	vim.api.nvim_create_user_command("AskAgentAlias", function(args)
		local items = M.targets()
		if #items == 0 then
			vim.notify("[ask_agent] Current backend has no available targets", vim.log.levels.WARN)
			return
		end
		for i, it in ipairs(items) do
			it.index = i
		end
		vim.ui.select(items, {
			prompt = args.bang and "Clear the alias of which instance"
				or "Give which instance an alias (:AskAgentAlias! clears)",
			format_item = function(item)
				local alias = aliases.get(item)
				return ("#%d %s%s%s  %s"):format(
					item.index or 0,
					icon_prefix(backends.get(current)),
					alias or item.label or item.id,
					alias and ("  (« " .. (item.label or item.id)) or "",
					vim.fn.fnamemodify(item.cwd or "?", ":~")
				)
			end,
		}, function(item)
			if not item then
				return
			end
			if args.bang then
				aliases.clear(item)
				vim.notify(("[ask_agent] Cleared alias for #%d"):format(item.index or 0), vim.log.levels.INFO)
				return
			end
			vim.ui.input({
				prompt = ("#%d name (empty = clear): "):format(item.index or 0),
				default = aliases.get(item) or "",
			}, function(name)
				if name == nil then
					return
				end
				if not aliases.set(item, name) then
					vim.notify("[ask_agent] Could not write the alias to the cache file", vim.log.levels.WARN)
					return
				end
				local now = aliases.get(item)
				vim.notify(
					now and ("[ask_agent] #%d is now called %s"):format(item.index or 0, now)
						or ("[ask_agent] Alias for #%d cleared"):format(item.index or 0),
					vim.log.levels.INFO
				)
			end)
		end)
	end, {
		nargs = 0,
		bang = true,
		desc = "Ask agent: give an instance an alias (shown in lists, same color in the map)",
	})
end

return M
