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
-- Keys in the float: `i` starts typing (unless the viewer is read-only), `q` closes.

local M = {}

local notify = require("ask_agent.notify")
local registry = require("ask_agent.views")

local active = {} -- win -> { job, readonly, id }
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

local function close_win(win)
	if not vim.api.nvim_win_is_valid(win) then
		return
	end
	local job = active[win] and active[win].job
	if job then
		pcall(vim.fn.jobstop, job)
	end
	if #vim.api.nvim_tabpage_list_wins(0) > 1 then
		pcall(vim.api.nvim_win_close, win, true)
	end
end

---Close a viewer float (the agent itself is not touched).
---@param win integer|nil defaults to the current window
function M.close(win)
	win = win or vim.api.nvim_get_current_win()
	local rec = active[win]
	active[win] = nil
	if not rec then
		return close_win(win)
	end
	if rec.job then
		pcall(vim.fn.jobstop, rec.job)
	end
	if vim.api.nvim_win_is_valid(win) and #vim.api.nvim_tabpage_list_wins(0) > 1 then
		pcall(vim.api.nvim_win_close, win, true)
	end
end

local function label(target)
	return (target.label and target.label ~= "") and target.label or tostring(target.id or "agent")
end

---Open a float showing the agent's terminal. Returns false + reason when no
---provider knows the target or the host command fails.
---@param target table
---@param opts { readonly?: boolean, width?: number, height?: number }|nil
---@return boolean ok, string|nil err
function M.open(target, opts)
	opts = opts or {}
	local p = M.find(target)
	if not p then
		return false, "no view provider knows this agent (ask.register_view({...}) adds one)"
	end
	local readonly = opts.readonly == true or p.readonly_only == true
	local spec, err = p.cmd(target, { readonly = readonly })
	if not spec or not spec.cmd then
		return false, err or ("view provider %s cannot show this agent"):format(p.id)
	end

	seq = seq + 1
	local width = math.max(20, math.min(vim.o.columns - 4, math.floor(vim.o.columns * (opts.width or 0.8))))
	local height = math.max(6, math.min(vim.o.lines - 4, math.floor(vim.o.lines * (opts.height or 0.75))))
	if spec.width and spec.height then
		-- a terminal viewer wants the block's own cell grid: replayed VT assumes it
		width = math.max(20, math.min(vim.o.columns - 4, spec.width))
		height = math.max(6, math.min(vim.o.lines - 4, spec.height))
	end
	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		width = width,
		height = height,
		row = math.max(0, math.floor((vim.o.lines - height) / 2) - 2),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		title = (" %s · %s — %s "):format(
			label(target),
			p.id,
			readonly and "read only · q closes" or "i to type · q closes"
		),
		title_pos = "center",
		zindex = 60,
	})
	vim.bo[buf].buflisted = false
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false

	local jopts = { term = true }
	if spec.env and next(spec.env) ~= nil then
		jopts.env = spec.env
	end
	local job = vim.fn.jobstart(spec.cmd, jopts)
	if job <= 0 then
		pcall(vim.api.nvim_win_close, win, true)
		return false, ("could not start %s"):format(spec.cmd[1])
	end
	vim.bo[buf].filetype = "terminal"
	active[win] = { job = job, readonly = readonly, id = p.id }

	vim.keymap.set("n", "q", function()
		M.close(win)
	end, { buffer = buf, desc = "Close the viewer (the agent keeps running)" })
	if not readonly then
		vim.keymap.set("n", "i", function()
			vim.cmd("startinsert")
		end, { buffer = buf, desc = "Type into the agent" })
	end

	local group = vim.api.nvim_create_augroup("AskAgentView" .. seq, { clear = true })
	vim.api.nvim_create_autocmd("TermClose", {
		group = group,
		buffer = buf,
		once = true,
		callback = function()
			vim.schedule(function()
				if active[win] then
					active[win] = nil
					if vim.api.nvim_win_is_valid(win) and #vim.api.nvim_tabpage_list_wins(0) > 1 then
						pcall(vim.api.nvim_win_close, win, true)
					end
				end
				pcall(vim.api.nvim_del_augroup_by_id, group)
			end)
		end,
	})

	vim.cmd("stopinsert")
	if spec.note then
		notify.notify("[ask_agent] " .. spec.note, vim.log.levels.INFO)
	end
	return true
end

---Stop every viewer (used on VimLeavePre).
function M.stop_all()
	for win, rec in pairs(active) do
		if rec.job then
			pcall(vim.fn.jobstop, rec.job)
		end
		active[win] = nil
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
