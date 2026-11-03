-- lua/ask_agent/aliases.lua
---@brief Give agent instances a human alias: "this pi is the api refactor", so it
---is instantly recognisable in the picker next time.
--
-- With only pid + cwd, two pi instances in the same directory are impossible to
-- tell apart; the alias is the only reliable name. Aliases live in
-- `<cache>/ask-agent/aliases.json` (override with
-- `require("ask_agent.aliases").setup({ file = "/path/to/aliases.json" })`) and
-- are keyed by instance id (pid). The registration time `ts` is stored alongside:
-- pid values get reused, so when `ts` no longer matches it is a different
-- instance and the old alias is ignored.

local M = {}

local fn = vim.fn

local FILE = fn.stdpath("cache") .. "/ask-agent/aliases.json"

---@type table<string, { name: string, ts: string, cwd: string|nil }>|nil
local cache

---Override the aliases file path.
---@param opts { file?: string }|nil
function M.setup(opts)
	opts = opts or {}
	if type(opts.file) == "string" and opts.file ~= "" then
		FILE = opts.file
		cache = nil
	end
end

---Where instance names are stored.
---@return string
function M.file()
	return FILE
end

local function path()
	return FILE
end

local function load()
	if cache then
		return cache
	end
	cache = {}
	local file = path()
	if fn.filereadable(file) == 1 then
		local ok, data = pcall(vim.json.decode, table.concat(fn.readfile(file), "\n"))
		if ok and type(data) == "table" then
			for id, rec in pairs(data) do
				if type(rec) == "table" and type(rec.name) == "string" then
					cache[tostring(id)] = rec
				end
			end
		end
	end
	return cache
end

local function save()
	local ok, encoded = pcall(vim.json.encode, load())
	if not ok then
		return false
	end
	local file = path()
	local dir = fn.fnamemodify(file, ":h")
	pcall(fn.mkdir, dir, "p")
	local fd = io.open(file, "w")
	if not fd then
		return false
	end
	fd:write(encoded)
	fd:close()
	return true
end

---Address of an instance (its pid); instances without an id cannot be aliased.
---@param t table|nil
---@return string|nil
local function key_of(t)
	if type(t) ~= "table" or t.id == nil then
		return nil
	end
	return tostring(t.id)
end

---Look up an alias. Returns nil when `ts` does not match (pid was reused).
---@param t table|nil target
---@return string|nil
function M.get(t)
	local id = key_of(t)
	if not id then
		return nil
	end
	local rec = load()[id]
	if not rec then
		return nil
	end
	if rec.ts ~= nil and t.ts ~= nil and rec.ts ~= tostring(t.ts) then
		return nil
	end
	return rec.name
end

---Set/rename an alias (an empty name clears it).
---@param t table target
---@param name string
---@return boolean ok
function M.set(t, name)
	local id = key_of(t)
	if not id then
		return false
	end
	name = vim.trim(tostring(name or ""))
	if name == "" then
		return M.clear(t)
	end
	load()[id] = { name = name, ts = t.ts ~= nil and tostring(t.ts) or "", cwd = t.cwd }
	return save()
end

---Remove an alias.
---@param t table target
---@return boolean ok
function M.clear(t)
	local id = key_of(t)
	if not id then
		return false
	end
	load()[id] = nil
	return save()
end

---@return table<string, table>
function M.all()
	return vim.deepcopy(load())
end

---Drop records left behind by instances that no longer exist.
---@param live table<string, true> ids of instances still alive
---@return integer removed
function M.prune(live)
	local data = load()
	local removed = 0
	for id in pairs(data) do
		if not live[id] then
			data[id] = nil
			removed = removed + 1
		end
	end
	if removed > 0 then
		save()
	end
	return removed
end

return M
