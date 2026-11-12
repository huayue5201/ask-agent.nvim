-- lua/ask_agent/views/rex.lua
---@brief Viewer provider for agents running in a Rex block.
--
-- Rex has no attach command, so the viewer is a mirror: bin/rex-view.py asks
-- rex for the block's screen as VT text a few dozen times a second and repaints
-- whole frames, and it forwards typed keys with
-- `com.superlogical.terminal.write`. Frames (instead of a spliced byte stream)
-- keep the picture correct even when the float and the block differ in size.

local registry = require("ask_agent.views")
local rex = require("ask_agent.rex_cli")

local function root()
	local src = debug.getinfo(1, "S").source:sub(2)
	return (src:match("^(.*)/lua/ask_agent/views/rex%.lua$")) or ""
end

---@param cmd table
---@param timeout integer
---@return string|nil
local function first_line(cmd, timeout)
	local ok, res = pcall(function()
		return vim.system(cmd, { text = true }):wait(timeout)
	end)
	if not ok or not res or res.code ~= 0 then
		return nil
	end
	return (res.stdout or ""):gsub("%s+$", "")
end

registry.register({
	id = "rex",
	priority = 20,
	can = function(target)
		return type(target.rex) == "table" and target.rex.block ~= nil
	end,
	cmd = function(target, opts)
		local bin = rex.path()
		if not bin then
			return nil, "rex is not installed"
		end
		local py = vim.g.ask_agent_python or "python3"
		if vim.fn.executable(py) ~= 1 then
			return nil, ("%s is needed for the rex viewer"):format(py)
		end
		local helper = root() .. "/bin/rex-view.py"
		if vim.fn.filereadable(helper) ~= 1 then
			return nil, "bin/rex-view.py is missing"
		end
		local block = target.rex.block
		local session = target.rex.session
		local cmd = { py, helper, "--block", tostring(block) }
		if session then
			vim.list_extend(cmd, { "--session", tostring(session) })
		else
			return nil, "the rex target has a block but no session"
		end
		if opts and opts.readonly then
			vim.list_extend(cmd, { "--readonly" })
		end
		-- the helper shells out to rex on its own: hand it the resolved binary
		local spec = {
			cmd = cmd,
			env = { REX_BIN = bin },
			note = "rex mirror — keys go to the agent",
		}

		-- Match the float to the block so VT coordinates line up. The session is
		-- required: without it `block call` only resolves the block when the shell
		-- that runs Neovim happens to sit in the same rex session (otherwise the
		-- lookup fails and the float falls back to a guessed size, which wraps).
		local size_cmd = { bin, "block", "call", "-b", tostring(block) }
		if session then
			vim.list_extend(size_cmd, { "-s", tostring(session) })
		end
		size_cmd[#size_cmd + 1] = "size"
		local size = first_line(size_cmd, 1500)
		if size then
			local ok, data = pcall(vim.json.decode, size)
			if ok and type(data) == "table" and tonumber(data.columns) and tonumber(data.rows) then
				spec.width = tonumber(data.columns)
				spec.height = tonumber(data.rows)
			end
		end
		return spec
	end,
})
