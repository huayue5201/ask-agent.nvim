-- lua/ask_agent/views/herdr.lua
---@brief Viewer provider for agents running under herdr.
--
-- `herdr agent attach <target>` is rendered by herdr itself (a second display,
-- not a takeover), so the agent and its ownership stay where they are. herdr
-- has no read-only flag: the float accepts input, and keys go to the agent.

local registry = require("ask_agent.views")

registry.register({
	id = "herdr",
	priority = 15,
	can = function(target)
		return type(target.herdr) == "table" and (target.herdr.agent or target.herdr.id) ~= nil
	end,
	cmd = function(target, opts)
		if vim.fn.executable("herdr") ~= 1 then
			return nil, "herdr is not installed"
		end
		local spec = target.herdr
		local id = spec.agent or spec.id
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
