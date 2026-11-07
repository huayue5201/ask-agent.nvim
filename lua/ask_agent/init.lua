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
--             layout/register_layout.

local backends = require("ask_agent.backends")
local generic = require("ask_agent.backends.generic")
local context = require("ask_agent.context")
local message = require("ask_agent.message")
local ui = require("ask_agent.ui")
local aliases = require("ask_agent.aliases")

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
		note_avoid(c.target)
		cb(c.target)
	end
	vim.ui.select(cands, {
		prompt = ("Send to which %s%s? (:AskAgentTarget remembers the choice; <Tab> in the map also gets you here)"):format(
			icon_prefix(mod),
			mod.label or mod.id
		),
		format_item = function(c)
			local t = c.target
			local parts = {
				("#%d"):format(t.index or 0),
				icon_prefix(mod, t) .. name_of(t),
				vim.fn.fnamemodify(t.cwd or "?", ":~"),
			}
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

	local items, located = {}, 0
	for i, c in ipairs(cands) do
		local t = c.target
		local pane_id = layout.match(t)
		if pane_id and in_window[pane_id] then
			located = located + 1
		end
		table.insert(items, {
			index = i,
			pane_id = pane_id,
			target = t,
			label = t.label,
			name = vim.fn.fnamemodify(t.cwd or "?", ":t"),
			icon = icon_prefix(mod, t):gsub("%s+$", ""),
			icon_hl = icon_color(mod, t),
			tier = c.tier,
		})
	end
	-- With only 1 locatable pane the map is meaningless (the user cannot see where the others are), so fall back to the list
	if located < 2 then
		return false
	end

	require("ask_agent.map").select({
		panes = panes,
		labels = type(layout.labels) == "function" and layout.labels(data) or {},
		items = items,
		cursor_pane = layout.cursor and layout.cursor() or nil,
		on_choose = function(item)
			if not item then
				return -- cancelled: do nothing
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

	local cands = backends.candidates(mod, vim.fn.getcwd(), pick_opts())
	if #cands == 0 then
		local _, reason = backends.status(mod)
		vim.notify(("[%s] %s"):format(mod.label or mod.id, reason or "no available instances"), vim.log.levels.WARN)
		return cb(nil)
	end
	if #cands == 1 and cands[1].tier == 1 and not cands[1].target.avoid then
		return cb(cands[1].target)
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

--- Register backends, install user commands and keymaps
--- `opts.keymaps` defaults to { ask = "<leader>aq", ask_visual = "<leader>aq", alias = "<leader>ai" };
--- set `opts.keymaps = false` to disable all keymaps. A keymap is only installed when its value is a non-empty string.
--- `opts.layout` picks a layout adapter (default: first usable one, see ask_agent.layouts).
--- `opts.bridge` is forwarded to ask_agent.bridge (unless false), and `opts.aliases` to ask_agent.aliases when present.
---@param opts { default?: string, extra?: table[], matching?: string, picker?: string, layout?: string, icons?: table, icon_colors?: table, aliases?: table, bridge?: table|false, keymaps?: { ask?: string|false, ask_visual?: string|false, alias?: string|false }|false }|nil
function M.setup(opts)
	opts = opts or {}
	matching = opts.matching or "exact"
	picker = opts.picker or "map"
	layout_id = opts.layout or nil
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

	-- Keymaps: defaults match the historical <leader> mappings; keymaps = false disables all of them
	local keymaps = opts.keymaps
	if keymaps == nil then
		keymaps = { ask = "<leader>aq", ask_visual = "<leader>aq", alias = "<leader>ai" }
	end
	if keymaps then
		if type(keymaps.ask) == "string" and keymaps.ask ~= "" then
			vim.keymap.set("n", keymaps.ask, function()
				M.ask()
			end, { desc = "Ask agent: ask the current backend (cursor anchor)" })
		end
		if type(keymaps.ask_visual) == "string" and keymaps.ask_visual ~= "" then
			vim.keymap.set("v", keymaps.ask_visual, function()
				M.ask({ visual = true })
			end, { desc = "Ask agent: ask the current backend (selection anchor)" })
		end
		if type(keymaps.alias) == "string" and keymaps.alias ~= "" then
			vim.keymap.set("n", keymaps.alias, "<cmd>AskAgentAlias<cr>", { desc = "Ask agent: alias an instance" })
		end
	end
end

return M
