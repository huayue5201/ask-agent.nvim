-- lua/ask_agent/views/rex.lua
---@brief Viewer provider for agents running in a Rex block.
--
-- Rex has no attach command and its data connection is one-way, so the viewer
-- is a small helper (bin/rex-view.py): it paints the block's screen with
-- `rex capture --format=vt`, then follows the block's data stream and writes
-- the live bytes to the terminal buffer. Input is never forwarded — the float
-- is read-only by contract, type in Rex itself.

local registry = require("ask_agent.views")

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
	readonly_only = true,
	can = function(target)
		return type(target.rex) == "table" and target.rex.block ~= nil
	end,
	cmd = function(target, _)
		if vim.fn.executable("rex") ~= 1 then
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
		local spec = { cmd = cmd, note = "Rex viewers are read-only — type in Rex" }

		-- match the float to the block so VT coordinates line up
		local size = first_line({ "rex", "block", "call", "-b", tostring(block), "size" }, 800)
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
