-- lua/ask_agent/views/tmux.lua
---@brief Viewer provider for agents running in a tmux pane.
--
-- `tmux attach-session` gives this Neovim another client of the same session:
-- the agent process is untouched, the pane is shared, and closing the float
-- detaches. Attaching is session-wide, not pane-wide (tmux has no per-pane
-- client), and `-r` makes the client read-only.

local registry = require("ask_agent.views")

---The session a pane belongs to; falls back to the pane string itself (callers
---often already store a session id or name).
---@param pane string
---@return string|nil
local function session_of(pane)
	local ok, res = pcall(function()
		return vim.system({ "tmux", "display-message", "-p", "-t", tostring(pane), "#{session_id}" }, { text = true })
			:wait(1000)
	end)
	if ok and res and res.code == 0 then
		local sid = (res.stdout or ""):gsub("%s+$", "")
		if sid ~= "" then
			return sid
		end
	end
	return nil
end

---The size of the session's window. With `-f ignore-size` the attached client
---never resizes it, so the float must match this grid exactly: a client grid
---larger than the window leaves tmux filling the rest, smaller one clips it.
---`#{window_height}` is the pane area: a client that should fit the window
---exactly needs the status rows on top of it, otherwise tmux shrinks the window
---by that much on attach.
---@param session string
---@return integer|nil width, integer|nil height
local function window_size(session)
	local function ask(fmt)
		local ok, res = pcall(function()
			return vim.system({ "tmux", "display-message", "-p", "-t", tostring(session), fmt }, { text = true })
				:wait(1000)
		end)
		return ok and res and res.code == 0 and ((res.stdout or ""):gsub("%s+$", "")) or nil
	end
	local size = ask("#{window_width}x#{window_height}")
	if not size then
		return nil
	end
	local w, h = size:match("(%d+)x(%d+)")
	local status = ask("#{status}") -- "off", "on" or a line count
	local rows = 1
	if status == "off" then
		rows = 0
	elseif status and status:match("^%d+$") then
		rows = tonumber(status)
	end
	return tonumber(w), tonumber(h) + rows
end

---`env` for a nested-client attach: tmux refuses to attach when TMUX is set
---(it thinks the client is nested). Neovim stringifies `vim.NIL` in `jobstart`
---env into the literal "v:null" -- tmux sees a set variable and exits -- so the
---only reliable way to unset is to hand over a copy of the environment without
---those keys.
---@return table<string,string>
local function detached_env()
	local env = vim.fn.environ()
	env.TMUX = nil
	env.TMUX_PANE = nil
	return env
end

registry.register({
	id = "tmux",
	priority = 10,
	can = function(target)
		return type(target.pane) == "string" and target.pane ~= ""
	end,
	cmd = function(target, opts)
		if vim.fn.executable("tmux") ~= 1 then
			return nil, "tmux is not installed"
		end
		local session = session_of(target.pane)
		local cmd = { "tmux", "attach-session" }
		-- `ignore-size` keeps the attached client from resizing the shared
		-- window: viewing an agent must not reflow the panes of whoever else is
		-- attached (and of the agent itself)
		vim.list_extend(cmd, { "-f", "ignore-size" })
		if opts and opts.readonly then
			vim.list_extend(cmd, { "-r" })
		end
		if session then
			local w, h = window_size(session)
			return {
				cmd = vim.list_extend(cmd, { "-t", session }),
				width = w,
				height = h,
				-- inside tmux, a nested client would be a tmux-in-tmux; drop the
				-- marker so the attach below is a fresh client
				env = detached_env(),
			}
		end
		vim.list_extend(cmd, { "-t", target.pane })
		return { cmd = cmd, env = detached_env() }
	end,
})
