-- lua/ask_agent/view.lua
---@brief A second display for an agent that lives somewhere else.
--
-- ask-agent does not own the terminal the agent runs in; the terminal does. So a
-- "viewer" is a thin adapter over the host's own client command:
--
--   {
--     id = "tmux",                    -- unique, shown in errors
--     priority = 10,                  -- higher wins when several can handle a target
--     readonly_only = false,          -- true when the host cannot accept input (rex)
--     can = function(target) bool end,
--     cmd = function(target, opts)   -- opts = { readonly = bool }
--       return { cmd = {...}, env = {...}, note = "..." } | nil, err
--     end,
--   }
--
-- Built in: tmux (target.pane), herdr (target.herdr) and rex (target.rex). Register
-- your own with ask.register_view({...}). The float is just a terminal buffer: the
-- agent keeps running in its own pane and closing the float detaches.
--
-- Keys in the float -- these and nothing else (the footer shows them):
--   <C-q>  close the viewer (normal and terminal mode)
--   q      close the viewer (normal mode)
--   i      start typing into the agent (normal mode, writable viewers only)
-- <Esc> is deliberately left to the agent (there it means "interrupt"), so the
-- float opens already in terminal mode: you land in the agent.
--
-- The float is tied to the agent's lifecycle: when the state layer reports the
-- agent gone, or the host client exits (TermClose), the float closes itself
-- instead of sitting there as a picture of a dead process.
--
-- The float also never lies about the grid: when the agent's terminal is larger
-- than the screen, the float is clipped (and says so in the footer) and lines
-- are not allowed to wrap -- wrapping turns a TUI into garbage.

local M = {}

local notify = require("ask_agent.notify")
local registry = require("ask_agent.views")

local active = {} -- win -> rec
local by_key = {} -- instance key -> win (one viewer per agent)
local seq = 0

---Register (or replace, by id) a viewer provider. See ask_agent/views/init.lua.
---@param mod table { id, can, cmd, priority?, readonly_only? }
function M.register(mod)
	registry.register(mod)
end

---@return table[]
function M.list()
	return registry.list()
end

---The provider that handles this target, if any.
---@param target table
---@return table|nil
function M.find(target)
	return registry.find(target)
end

---Detach: SIGTERM, then SIGKILL if the host client is still around. tmux's
---client can take a moment to let go of the session, and a viewer that outlives
---its float keeps the session attached (and may hold a read lock on a pane).
---@param job integer|nil
local function kill(job)
	if not job or job <= 0 then
		return
	end
	-- take the pid first: jobstop() can retire the channel immediately, and
	-- jobpid() then raises E900 for a process that is still shutting down
	local ok, pid = pcall(vim.fn.jobpid, job)
	pcall(vim.fn.jobstop, job)
	if not ok or not pid or pid <= 0 then
		return
	end
	vim.defer_fn(function()
		local ok2, res = pcall(vim.fn.jobwait, { job }, 0)
		if ok2 and res[1] == -1 then
			pcall(vim.uv.kill, pid, "sigkill")
		end
	end, 400)
end

---Forget a viewer, stop its client and (optionally) close its window. Safe to
---call from WinClosed/TermClose, where the window may already be gone.
---@param win integer
---@param close boolean
local function detach(win, close)
	local rec = active[win]
	if rec then
		active[win] = nil
		if rec.key and by_key[rec.key] == win then
			by_key[rec.key] = nil
		end
		if rec.off then
			pcall(rec.off)
			rec.off = nil
		end
		if rec.job then
			kill(rec.job)
			rec.job = nil
		end
	end
	if not close or not vim.api.nvim_win_is_valid(win) then
		return
	end
	-- Closing the current window makes Neovim pick a neighbour; put the user back
	-- where they opened the viewer instead.
	local prev = rec and rec.prev_win
	if vim.api.nvim_get_current_win() == win and prev and vim.api.nvim_win_is_valid(prev) then
		pcall(vim.api.nvim_set_current_win, prev)
	end
	if #vim.api.nvim_tabpage_list_wins(0) > 1 then
		pcall(vim.api.nvim_win_close, win, true)
	end
end

---Close a viewer float (the agent itself is not touched).
---@param win integer|nil defaults to the current window
function M.close(win)
	win = win or vim.api.nvim_get_current_win()
	detach(win, true)
end

---Interior size available to a float: the screen minus the border and the
---command line. Anything larger is clipped by Neovim and wraps inside the
---terminal grid, which is worse than an honest crop.
---@return integer width, integer height
local function available()
	return math.max(20, vim.o.columns - 2), math.max(6, vim.o.lines - 3)
end

local function label(target)
	return (target.label and target.label ~= "") and target.label or tostring(target.id or "agent")
end

---The instance key used by the state layer (`backend:id`), unless the caller
---passed one explicitly.
---@param target table
---@param opts table
---@return string|nil
local function instance_key(target, opts)
	if opts.key then
		return tostring(opts.key)
	end
	if target.backend and target.id then
		return target.backend .. ":" .. tostring(target.id)
	end
	return nil
end

---Title: agent name, provider, state -- dropping the less important parts until
---it fits (a long name in a narrow float used to shove the whole title out).
---@param rec table
---@param state string|nil
---@return string
local function title_text(rec, state)
	local parts = { rec.label, rec.id }
	if state and state ~= "" and state ~= "unknown" then
		parts[#parts + 1] = state
	end
	while #parts > 0 do
		local s = (" %s "):format(table.concat(parts, " · "))
		if vim.api.nvim_strwidth(s) <= rec.width then
			return s
		end
		table.remove(parts)
	end
	local name = rec.label
	if vim.api.nvim_strwidth(name) + 3 > rec.width then
		name = vim.fn.strcharpart(name, 0, math.max(1, rec.width - 4)) .. "…"
	end
	return (" %s "):format(name)
end

---Footer: exactly the keys the viewer provides, then the facts that are easy to
---miss (read-only, clipped grid, provider note). Items are dropped from the end
---until it fits, so the close key never disappears.
---@param rec table
---@return string
local function footer_text(rec)
	local items = { "<C-q> close" }
	items[#items + 1] = rec.readonly and "read only" or "i type"
	if rec.clipped then
		items[#items + 1] = rec.clipped
	end
	if rec.note and rec.note ~= "" then
		items[#items + 1] = rec.note
	end
	for n = #items, 1, -1 do
		local s = " " .. table.concat(items, " · ", 1, n) .. " "
		if vim.api.nvim_strwidth(s) <= rec.width then
			return s
		end
	end
	return ""
end

---Repaint title/footer (state changes the title, nothing else does).
---@param rec table
---@param state string|nil
local function restyle(rec, state)
	if not vim.api.nvim_win_is_valid(rec.win) then
		return
	end
	pcall(vim.api.nvim_win_set_config, rec.win, {
		title = title_text(rec, state),
		footer = footer_text(rec),
	})
end

---Follow the agent through the state layer: show its state in the title and
---close the float when it is gone. The rex helper and TermClose cover viewers
---whose agent the state layer does not track.
---@param rec table
local function watch(rec)
	if not rec.key then
		restyle(rec, nil)
		return
	end
	local ok, state = pcall(require, "ask_agent.state")
	if not ok then
		restyle(rec, nil)
		return
	end
	local first = state.get(rec.key)
	restyle(rec, first and first.state or nil)
	rec.off = state.on("state", function(r)
		if r.key ~= rec.key then
			return
		end
		if active[rec.win] ~= rec then
			return
		end
		restyle(rec, r.state)
		if r.gone then
			-- never close from inside the emit loop: unsubscribing there would
			-- skip the next listener
			local win = rec.win
			vim.schedule(function()
				if active[win] ~= rec then
					return
				end
				notify.notify(("[ask_agent] %s exited — viewer closed"):format(rec.label), vim.log.levels.INFO)
				M.close(win)
			end)
		end
	end)
end

---Open a float showing the agent's terminal. Returns false + reason when no
---provider knows the target or the host command fails. A viewer already open for
---the same agent is focused instead of being duplicated.
---@param target table
---@param opts { readonly?: boolean, width?: number, height?: number, key?: string }|nil
---@return boolean ok, string|nil err
function M.open(target, opts)
	opts = opts or {}
	local key = instance_key(target, opts)

	local existing = key and by_key[key]
	if existing and vim.api.nvim_win_is_valid(existing) then
		pcall(vim.api.nvim_set_current_win, existing)
		return true
	end

	local p = M.find(target)
	if not p then
		return false, "no view provider knows this agent (ask.register_view({...}) adds one)"
	end

	if key then
		local ok, state = pcall(require, "ask_agent.state")
		local rec = ok and state.get(key) or nil
		if rec and rec.gone then
			return false, ("%s has exited"):format(rec.label or label(target))
		end
	end

	local readonly = opts.readonly == true or p.readonly_only == true
	local spec, err = p.cmd(target, { readonly = readonly })
	if not spec or not spec.cmd then
		return false, err or ("view provider %s cannot show this agent"):format(p.id)
	end

	seq = seq + 1
	local max_w, max_h = available()
	-- Ask for the agent's whole grid, but never more than a share of the screen:
	-- a 175x52 agent on a 80x24 screen would otherwise cover everything.
	-- `width`/`height` are fractions, so 1 fills the screen.
	local share_w = math.floor(max_w * (opts.width or 0.85))
	local share_h = math.floor(max_h * (opts.height or 0.75))
	local width, height, clipped
	if spec.width and spec.height then
		width = math.min(math.max(20, spec.width), math.max(20, share_w))
		height = math.min(math.max(6, spec.height), math.max(6, share_h))
		if width ~= spec.width or height ~= spec.height then
			clipped = ("clipped %d×%d→%d×%d"):format(spec.width, spec.height, width, height)
		end
	else
		width = math.min(max_w, math.max(20, share_w))
		height = math.min(max_h, math.max(6, share_h))
	end

	local prev_win = vim.api.nvim_get_current_win()
	local rec = {
		readonly = readonly,
		id = p.id,
		key = key,
		label = label(target),
		prev_win = prev_win,
		width = width,
		clipped = clipped,
		note = spec.note,
	}
	local buf = vim.api.nvim_create_buf(false, true)
	rec.win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		width = width,
		height = height,
		row = math.max(0, math.floor((vim.o.lines - height) / 2) - 2),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		title = title_text(rec, nil),
		title_pos = "center",
		footer = footer_text(rec),
		footer_pos = "center",
		zindex = 60,
	})
	local win = rec.win
	vim.bo[buf].buflisted = false
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	-- A full-screen repaint of an agent whose grid is wider than the float must
	-- clip, not wrap: wrapped TUI lines are unreadable. The helper crops at the
	-- source; this is the second line of defence.
	vim.wo[win].wrap = false
	vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"
	active[win] = rec
	if key then
		by_key[key] = win
	end

	local jopts = { term = true }
	if spec.env and next(spec.env) ~= nil then
		jopts.env = spec.env
	end
	local job = vim.fn.jobstart(spec.cmd, jopts)
	if job <= 0 then
		detach(win, true)
		return false, ("could not start %s"):format(spec.cmd[1])
	end
	rec.job = job
	vim.bo[buf].filetype = "terminal"

	vim.keymap.set({ "n", "t" }, "<C-q>", function()
		M.close(win)
	end, { buffer = buf, desc = "Close the viewer (the agent keeps running)" })
	vim.keymap.set("n", "q", function()
		M.close(win)
	end, { buffer = buf, desc = "Close the viewer (the agent keeps running)" })
	if not readonly then
		vim.keymap.set("n", "i", function()
			vim.cmd("startinsert")
		end, { buffer = buf, desc = "Type into the agent" })
	end

	local group = vim.api.nvim_create_augroup("AskAgentView" .. seq, { clear = true })
	---The helper prints `[ask-agent] <reason> — closing the viewer` when it
	---decides the agent is gone; surface that line instead of letting the float
	---vanish without a word.
	local function exit_reason()
		local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
		if not ok or not lines then
			return nil
		end
		for i = #lines, math.max(1, #lines - 6), -1 do
			local reason = lines[i]:match("%[ask%-agent%] (.-) %— closing the viewer")
			if reason then
				return reason
			end
		end
		return nil
	end
	vim.api.nvim_create_autocmd("TermClose", {
		group = group,
		buffer = buf,
		once = true,
		callback = function()
			local reason = exit_reason()
			vim.schedule(function()
				detach(win, true)
				pcall(vim.api.nvim_del_augroup_by_id, group)
			end)
			if reason then
				notify.notify(("[ask_agent] %s: %s"):format(rec.label, reason), vim.log.levels.INFO)
			end
		end,
	})

	-- Closing the float any other way (:q, :close, a plugin) must detach too,
	-- otherwise the host client keeps the session attached in the background.
	vim.api.nvim_create_autocmd("WinClosed", {
		group = group,
		pattern = tostring(win),
		callback = function()
			detach(win, false)
			pcall(vim.api.nvim_del_augroup_by_id, group)
		end,
	})

	watch(rec)

	-- Open in terminal mode like sidekick's float: you land in the agent and can
	-- type straight away. <Esc> belongs to the agent (interrupt), so leaving
	-- means <C-q> (or <C-\><C-n> then q).
	vim.schedule(function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_set_current_win(win)
			if not readonly then
				vim.cmd("startinsert")
			end
		end
	end)
	return true
end

---Stop every viewer (used on VimLeavePre).
function M.stop_all()
	for win in pairs(active) do
		detach(win, false)
	end
end

---Provider ids, for health and status lines.
---@return string
function M.describe()
	local ids = {}
	for _, p in ipairs(registry.list()) do
		ids[#ids + 1] = p.id
	end
	return table.concat(ids, ", ")
end

-- providers register themselves on first require
require("ask_agent.views.tmux")
require("ask_agent.views.herdr")
require("ask_agent.views.rex")

return M
