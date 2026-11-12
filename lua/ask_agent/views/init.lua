-- lua/ask_agent/views/init.lua
---@brief The viewer provider registry (kept apart from view.lua so providers
---can register themselves without a require cycle).
--
--   { id, can(target) -> bool, cmd(target, opts) -> {cmd, env?, note?, width?, height?}, priority?, readonly_only? }

local M = {}

local providers = {}

local function sort()
	table.sort(providers, function(a, b)
		return (a.priority or 10) > (b.priority or 10)
	end)
end

---Register (or replace, by id) a viewer provider.
---@param mod table
function M.register(mod)
	assert(type(mod) == "table" and type(mod.id) == "string", "view provider needs an id")
	assert(type(mod.can) == "function", ("view provider %s is missing can()"):format(mod.id))
	assert(type(mod.cmd) == "function", ("view provider %s is missing cmd()"):format(mod.id))
	for i, p in ipairs(providers) do
		if p.id == mod.id then
			table.remove(providers, i)
			break
		end
	end
	table.insert(providers, mod)
	sort()
end

---@return table[]
function M.list()
	return providers
end

---The provider that handles this target, if any.
---@param target table
---@return table|nil
function M.find(target)
	if type(target) ~= "table" then
		return nil
	end
	for _, p in ipairs(providers) do
		local ok, can = pcall(p.can, target)
		if ok and can then
			return p
		end
	end
	return nil
end

return M
