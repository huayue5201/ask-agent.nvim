-- lua/ask_agent/views/herdr.lua
---@brief Viewer provider for agents running under herdr.
--
-- `herdr agent attach <target>` is rendered by herdr itself (a second display,
-- not a takeover), so the agent and its ownership stay where they are. herdr
-- has no read-only flag: the float accepts input, and keys go to the agent.

local registry = require("ask_agent.views")

---The pane a target lives in: declared, or looked up by pid.
---@param target table
---@return string|nil pane
local function pane_of(target)
	if type(target.pane) == "string" and target.pane ~= "" then
		return target.pane
	end
	if not target.pid then
		return nil
	end
	local ok, backend = pcall(require, "ask_agent.backends.herdr")
	if not ok or type(backend.pane_of_pid) ~= "function" then
		return nil
	end
	return backend.pane_of_pid(target.pid)
end

registry.register({
	id = "herdr",
	priority = 15,
	can = function(target)
		if type(target.herdr) == "table" and (target.herdr.agent or target.herdr.id) ~= nil then
			return true
		end
		-- an agent herdr did not start (pi begun by hand inside a herdr pane) has
		-- no herdr field, but its pid tells us which pane it belongs to
		return pane_of(target) ~= nil
	end,
	cmd = function(target, opts)
		if vim.fn.executable("herdr") ~= 1 then
			return nil, "herdr is not installed"
		end
		local spec = type(target.herdr) == "table" and target.herdr or {}
		local id = spec.agent or spec.id or pane_of(target)
		local cmd = { "herdr", "agent", "attach", tostring(id) }
		local note
		if opts and opts.readonly then
			note = "herdr attach cannot be read-only — the float accepts input"
		end
		if spec.takeover then
			cmd[#cmd + 1] = "--takeover"
		end
		return { cmd = cmd, note = note }
	end,
})
