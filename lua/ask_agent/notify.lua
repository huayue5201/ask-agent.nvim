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
---Play this command instead of the bell (`{ "afplay", "/System/Library/Sounds/
---Glass.aiff" }`); the terminal's own bell is silent in most setups.
---@type string[]|nil
M.sound_cmd = nil
---Neovim defaults to `belloff=all`, which would make every bell a no-op for
---everyone who never touched the option. The plugin's own `sound` setting is the
---mute switch, so the bell is written regardless; set this to respect `belloff`.
M.respect_belloff = false
---Show state notifications as a small floating card instead of one cmdline line
---(default false: a toast is a visible change, opt in with `notify_popup`).
M.popup = false
---How long the card stays up, in ms.
M.popup_ms = 3000
local popup_win
local popup_timer

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

---Ring the terminal bell (or play `sound_cmd`).
local function ring()
	if M.sound_cmd then
		pcall(function()
			vim.system(M.sound_cmd, { detach = true })
		end)
		return
	end
	if M.respect_belloff and vim.o.belloff:find("all", 1, true) then
		return
	end
	pcall(function()
		io.stdout:write("\a")
		io.stdout:flush()
	end)
end

---Keep a notification to a single screen line.
--
-- `nvim_echo(..., true, {})` is a pager: a message that wraps or spans lines
-- raises "Press ENTER or type command to continue", which blocks whatever the
-- user was doing (very visible when it happens while a float is open). Newlines
-- are folded and overlong text is cut with an ellipsis, so a notification can
-- never steal the keyboard.
--
-- The margin is deliberately wide: the exact width at which Neovim decides to
-- page is narrower than 'columns' (measured in an 80-column float: 69 cells
-- already paged, 60 did not), and it is not worth guessing per UI.
---@param msg string
---@return string
local function fit(msg)
	local one = msg:gsub("%s*\n%s*", " "):gsub("\t", " ")
	local width = math.max(20, vim.o.columns - 20)
	-- the ellipsis counts too: cutting to `width - 1` cells and then appending "…" would
	-- land exactly on `columns` and wrap, which is the pager again
	return require("ask_agent.text").fit(one, width, { min = 2 }) or "…"
end

---@param opts { style?: boolean, sound?: boolean, sound_cmd?: string|string[],
---  popup?: boolean, popup_ms?: integer, respect_belloff?: boolean }|nil
function M.setup(opts)
	opts = opts or {}
	if opts.style ~= nil then
		M.style = opts.style ~= false
	end
	if opts.sound ~= nil then
		M.sound = opts.sound ~= false
	end
	if opts.sound_cmd ~= nil then
		M.sound_cmd = type(opts.sound_cmd) == "string" and { "sh", "-c", opts.sound_cmd } or opts.sound_cmd
	end
	if opts.popup ~= nil then
		M.popup = opts.popup ~= false
	end
	if opts.popup_ms ~= nil then
		M.popup_ms = opts.popup_ms
	end
	if opts.respect_belloff ~= nil then
		M.respect_belloff = opts.respect_belloff ~= false
	end
end

---A card in the corner: the one shape a cmdline echo cannot give you — it stays
---put until it is read, instead of being redrawn away by the next keystroke.
---@param msg string
local function toast(msg)
	ensure_groups()
	local text = fit(msg)
	local ok, res = pcall(function()
		local ui = vim.api.nvim_list_uis()[1]
		if not ui then
			return false
		end
		local width = math.min(vim.api.nvim_strwidth(text) + 2, math.max(20, ui.width - 4))
		local rows = math.max(1, math.ceil(vim.api.nvim_strwidth(text) / width))
		if popup_win and vim.api.nvim_win_is_valid(popup_win) then
			pcall(vim.api.nvim_win_close, popup_win, true)
		end
		local buf = vim.api.nvim_create_buf(false, true)
		-- the window is closed on dismiss/timeout, so the buffer must follow it out
		vim.bo[buf].bufhidden = "wipe"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
		popup_win = vim.api.nvim_open_win(buf, false, {
			relative = "editor",
			anchor = "NE",
			row = 1,
			col = ui.width - 2,
			width = width,
			height = rows,
			style = "minimal",
			border = "rounded",
			title = " ask-agent ",
			title_pos = "left",
			zindex = 200,
			focusable = false,
			noautocmd = true,
		})
		vim.wo[popup_win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"
		vim.bo[buf].filetype = "ask-agent-notify"
		return true
	end)
	if not ok or not res then
		return false
	end
	if popup_timer then
		popup_timer:stop()
		popup_timer:close()
	end
	popup_timer = vim.uv.new_timer()
	popup_timer:start(M.popup_ms, 0, function()
		vim.schedule(function()
			if popup_win and vim.api.nvim_win_is_valid(popup_win) then
				pcall(vim.api.nvim_win_close, popup_win, true)
			end
			popup_win = nil
		end)
	end)
	return true
end

---Drop-in replacement for `vim.notify(msg, level, opts)` with the house style.
---`opts.sound` overrides the module-wide bell for this one message (`true` rings
---even when `M.sound` is off, `false` stays quiet even when it is on).
---@param msg string
---@param level integer|nil
---@param opts table|nil forwarded to vim.notify when a UI plugin owns it
function M.notify(msg, level, opts)
	level = level or vim.log.levels.INFO
	local sound = opts and opts.sound
	if sound == nil then
		sound = M.sound
	end
	if sound then
		ring()
	end
	-- a notification UI plugin owns the message only when it actually replaced
	-- vim.notify; merely being loaded (fidget, snacks, noice often are) must not
	-- cost us the styled line — otherwise every state change is a plain cmdline
	-- flicker, which is exactly the "I never saw a notification" complaint
	if not stock_notify() or not M.style then
		vim.notify(msg, level, opts)
		return
	end
	if M.popup and toast(msg) then
		return
	end
	ensure_groups()
	vim.api.nvim_echo({ { fit(msg), HL[level] or HL[vim.log.levels.INFO] } }, true, {})
end

return M
