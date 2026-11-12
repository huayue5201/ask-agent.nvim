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
		if opts and opts.readonly then
			vim.list_extend(cmd, { "-r" })
		end
		if session then
			return {
				cmd = vim.list_extend(cmd, { "-t", session }),
				-- inside tmux, a nested client would be a tmux-in-tmux; drop the
				-- marker so the attach below is a fresh client
				env = { TMUX = vim.NIL, TMUX_PANE = vim.NIL },
			}
		end
		vim.list_extend(cmd, { "-t", target.pane })
		return { cmd = cmd, env = { TMUX = vim.NIL, TMUX_PANE = vim.NIL } }
	end,
})
