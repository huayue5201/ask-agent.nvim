-- lua/ask_agent/notify.lua
---@brief One house style for every user-facing notification.
--
-- `vim.notify` can only colour by level and cannot go bold, so this module
-- paints the message itself: bold text in the level's diagnostic colour. When a
-- notification UI (nvim-notify, noice, snacks, fidget) has taken over
-- `vim.notify`, the message is handed to it instead so it keeps its own
-- rendering. `sound = true` rings the terminal bell on top of every message.
--
--   require("ask_agent.notify").notify("done", vim.log.levels.INFO)
--   notify.setup({ style = true, sound = false })

local M = {}

---Paint notifications bold+coloured (default true). False = plain vim.notify.
M.style = true
---Ring the terminal bell with every notification (default false).
M.sound = false

local HL = {
	[vim.log.levels.TRACE] = "AskAgentNotifyTrace",
	[vim.log.levels.DEBUG] = "AskAgentNotifyDebug",
	[vim.log.levels.INFO] = "AskAgentNotifyInfo",
	[vim.log.levels.WARN] = "AskAgentNotifyWarn",
	[vim.log.levels.ERROR] = "AskAgentNotifyError",
}

local SOURCE = {
	[vim.log.levels.TRACE] = "DiagnosticHint",
	[vim.log.levels.DEBUG] = "DiagnosticHint",
	[vim.log.levels.INFO] = "DiagnosticInfo",
	[vim.log.levels.WARN] = "DiagnosticWarn",
	[vim.log.levels.ERROR] = "DiagnosticError",
}

-- Notification UIs that replace vim.notify; they render level/colour themselves.
local UI_MODULES = { "notify", "noice", "snacks", "fidget", "nvim-notify" }

local groups_ready = false

---Create the bold highlight groups once, taking each level's colour from the
---theme's diagnostics so every colorscheme works. `default = true` leaves a
---user override untouched.
local function ensure_groups()
	if groups_ready then
		return
	end
	groups_ready = true
	for level, group in pairs(HL) do
		local src = SOURCE[level]
		local ok, resolved = pcall(vim.api.nvim_get_hl, 0, { name = src, link = false })
		local fg = ok and resolved.fg or nil
		local spec = { bold = true, default = true }
		if fg then
			spec.fg = fg
		else
			spec.link = src
		end
		pcall(vim.api.nvim_set_hl, 0, group, spec)
	end
end

---@return boolean
local function external_ui()
	for _, name in ipairs(UI_MODULES) do
		if package.loaded[name] then
			return true
		end
	end
	return false
end

---Does Neovim's own vim.notify still own the message, or has something replaced
---it (a notification plugin, or a user/test stub we must not bypass)?
---@return boolean
local function stock_notify()
	local ok, info = pcall(debug.getinfo, vim.notify, "S")
	local source = ok and info and info.source
	if type(source) ~= "string" then
		return false
	end
	return source:find("vim/_core/editor", 1, true) ~= nil or source:find("vim/_editor", 1, true) ~= nil
end

---Ring the terminal bell, unless the user muted it (`:set belloff=all`).
local function ring()
	if vim.o.belloff:find("all", 1, true) then
		return
	end
	pcall(function()
		io.stdout:write("\a")
		io.stdout:flush()
	end)
end

---@param opts { style?: boolean, sound?: boolean }|nil
function M.setup(opts)
	opts = opts or {}
	if opts.style ~= nil then
		M.style = opts.style ~= false
	end
	if opts.sound ~= nil then
		M.sound = opts.sound ~= false
	end
end

---Drop-in replacement for `vim.notify(msg, level, opts)` with the house style.
---@param msg string
---@param level integer|nil
---@param opts table|nil forwarded to vim.notify when a UI plugin owns it
function M.notify(msg, level, opts)
	level = level or vim.log.levels.INFO
	if M.sound then
		ring()
	end
	if not M.style or external_ui() or not stock_notify() then
		vim.notify(msg, level, opts)
		return
	end
	ensure_groups()
	vim.api.nvim_echo({ { msg, HL[level] or HL[vim.log.levels.INFO] } }, true, {})
end

return M
