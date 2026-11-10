-- lua/ask_agent/jump.lua
---@brief "Bring the agent's window to the front" — one small adapter registry.
--
-- Which terminal / multiplexer hosts an agent is not something this plugin can
-- know, and it should not hard-code the answer: rex, tmux, herdr, kitty, wezterm,
-- a desktop window manager — every user has a different one. A jump adapter is
-- the whole interface:
--
--   {
--     id = "rex",                          -- unique, shown in errors
--     priority = 10,                       -- higher wins when several can handle a target
--     can = function(target) return bool end,
--     focus = function(target) end,        -- bring it to the front (may be async)
--     capture = function(target, cb) end,  -- optional: cb(text) with recent output
--   }
--
-- Built in: rex (target.rex = { session, block }) and tmux (target.pane).
-- Register your own with ask.register_jump({...}) — no plugin changes needed.

local M = {}

local adapters = {}

local function sort()
	table.sort(adapters, function(a, b)
		return (a.priority or 10) > (b.priority or 10)
	end)
end

---Register (or replace, by id) a jump adapter.
---@param mod table { id, can, focus, capture?, priority? }
function M.register(mod)
	assert(type(mod) == "table" and type(mod.id) == "string", "jump adapter needs an id")
	assert(type(mod.can) == "function", ("jump adapter %s is missing can()"):format(mod.id))
	assert(type(mod.focus) == "function", ("jump adapter %s is missing focus()"):format(mod.id))
	for i, a in ipairs(adapters) do
		if a.id == mod.id then
			table.remove(adapters, i)
			break
		end
	end
	table.insert(adapters, mod)
	sort()
end

---@return table[]
function M.list()
	return adapters
end

---The adapter that handles this target, if any.
---@param target table
---@return table|nil
function M.find(target)
	if type(target) ~= "table" then
		return nil
	end
	for _, a in ipairs(adapters) do
		local ok, can = pcall(a.can, target)
		if ok and can then
			return a
		end
	end
	return nil
end

---Focus the window an instance lives in.
---@param target table
---@return boolean ok, string|nil err
function M.focus(target)
	local a = M.find(target)
	if not a then
		return false, "no jump adapter knows this agent (ask.register_jump({...}) adds one)"
	end
	local ok, err = pcall(a.focus, target)
	if not ok then
		return false, tostring(err)
	end
	return true, nil
end

---Recent output of an instance, if an adapter can read it. cb(text|nil).
---@param target table
---@param cb fun(text: string|nil)
function M.capture(target, cb)
	local a = M.find(target)
	if not a or type(a.capture) ~= "function" then
		return cb(nil)
	end
	pcall(a.capture, target, cb)
end

-- ================================
-- Built-in adapters
-- ================================

M.register({
	id = "rex",
	priority = 20,
	can = function(target)
		return type(target.rex) == "table" and target.rex.block ~= nil
	end,
	focus = function(target)
		local cmd = { "rex", "block", "focus", "-b", target.rex.block }
		if target.rex.session then
			vim.list_extend(cmd, { "-s", target.rex.session })
		end
		vim.system(cmd)
	end,
	capture = function(target, cb)
		local cmd = { "rex", "block", "capture", "-b", target.rex.block, "--trim" }
		if target.rex.session then
			vim.list_extend(cmd, { "-s", target.rex.session })
		end
		vim.system(cmd, { text = true }, function(res)
			vim.schedule(function()
				cb(res.code == 0 and res.stdout or nil)
			end)
		end)
	end,
})

M.register({
	id = "tmux",
	priority = 10,
	can = function(target)
		return target.pane ~= nil
	end,
	focus = function(target)
		vim.system({ "tmux", "select-pane", "-t", target.pane })
	end,
})

return M
