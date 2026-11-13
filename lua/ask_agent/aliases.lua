-- lua/ask_agent/aliases.lua
---@brief Give agent instances a human name: "this pi is the api refactor".
--
-- A pid is a poor identity: it changes on every restart and two pi instances in
-- the same directory look the same. Names are therefore stored twice:
--
--   exact  pid + start time, so the current instance keeps its name immediately
--   group  backend + real cwd + slot, so the name survives a restart
--
-- A slot is only inherited once the process that earned it is gone: while it is
-- still running, its name belongs to it and nobody else in that directory gets
-- it. Once there are several names the slots are shown as `name ·2`, `name ·3`
-- and an instance only inherits a name that was bound to its own pid. Renaming
-- an unbound instance claims the first free slot. This never guesses which
-- conversation came back — it only remembers which name belongs to which slot.
--
-- The file lives in `<cache>/ask-agent/aliases.json` (override with
-- `require("ask_agent.aliases").setup({ file = "/path/to/aliases.json" })`).

local M = {}

local fn = vim.fn
local uv = vim.uv

local FILE = fn.stdpath("cache") .. "/ask-agent/aliases.json"

---@class AskAgentAliasStore
---@field version integer
---@field exact table<string, { name: string, ts: string, cwd: string|nil, backend: string|nil }>
---@field groups table<string, table<integer, { name: string, id: string, ts: string }>>

---@type AskAgentAliasStore|nil
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

---@return AskAgentAliasStore
local function blank()
	return { version = 2, exact = {}, groups = {} }
end

-- A name is a label, not a paragraph: cap it by display cells so a terminal
-- title or a pasted statusline chunk cannot swallow the agent list.
local MAX_NAME = 32

---Collapse whitespace and shorten to MAX_NAME cells (ellipsis included).
---@param name string|nil
---@return string|nil
local function tidy(name)
	if type(name) ~= "string" then
		return name
	end
	name = vim.trim((name:gsub("[%c]", " ")):gsub("%s+", " "))
	if name == "" then
		return name
	end
	return require("ask_agent.text").fit(name, MAX_NAME) or name
end

---@param rec table
---@return boolean
local function valid(rec)
	return type(rec) == "table" and type(rec.name) == "string" and rec.name ~= ""
end

---Read both the current format and the old flat `pid -> alias` file.
---@return AskAgentAliasStore
local function load()
	if cache then
		return cache
	end
	cache = blank()
	local file = M.file()
	if fn.filereadable(file) == 1 then
		local ok, data = pcall(vim.json.decode, table.concat(fn.readfile(file), "\n"))
		if ok and type(data) == "table" then
			if data.version == 2 and type(data.exact) == "table" and type(data.groups) == "table" then
				for id, rec in pairs(data.exact) do
					if valid(rec) then
						cache.exact[tostring(id)] = rec
					end
				end
				for group, slots in pairs(data.groups) do
					if type(slots) == "table" then
						local clean = {}
						for slot, rec in pairs(slots) do
							if tonumber(slot) and valid(rec) then
								clean[tonumber(slot)] = rec
							end
						end
						cache.groups[tostring(group)] = clean
					end
				end
			else
				-- v1 stored one flat map keyed by pid; keep those names exact.
				for id, rec in pairs(data) do
					if valid(rec) then
						cache.exact[tostring(id)] = rec
					end
				end
			end
		end
	end
	return cache
end

---@return boolean
local function save()
	local ok, encoded = pcall(vim.json.encode, load())
	if not ok then
		return false
	end
	local file = M.file()
	pcall(fn.mkdir, fn.fnamemodify(file, ":h"), "p")
	local fd = io.open(file, "w")
	if not fd then
		return false
	end
	fd:write(encoded)
	fd:close()
	return true
end

---@param t table|nil
---@param backend string|nil
---@return string|nil
local function backend_of(t, backend)
	return backend or (type(t) == "table" and t.backend) or nil
end

---@param t table|nil
---@return string|nil
local function id_of(t)
	if type(t) ~= "table" or t.id == nil then
		return nil
	end
	return tostring(t.id)
end

---@param t table|nil
---@param backend string|nil
---@return string|nil
local function exact_key(t, backend)
	local id = id_of(t)
	if not id then
		return nil
	end
	local b = backend_of(t, backend)
	return b and (b .. "|" .. id) or id
end

---@param dir string|nil
---@return string|nil
local function norm_dir(dir)
	if type(dir) ~= "string" or dir == "" then
		return nil
	end
	return uv.fs_realpath(dir) or dir:gsub("/+$", "")
end

---@param t table|nil
---@param backend string|nil
---@return string|nil
local function group_key(t, backend)
	local dir = norm_dir(type(t) == "table" and t.cwd or nil)
	if not dir then
		return nil
	end
	local b = backend_of(t, backend)
	return b and (b .. "|" .. dir) or dir
end

---@param t table|nil
---@return string
local function ts_of(t)
	return type(t) == "table" and t.ts ~= nil and tostring(t.ts) or ""
end

---Is the process behind this slot still running? `false` for anything we cannot
---prove alive: an id that is not a pid (herdr names, tmux panes) has no liveness
---to check, and a name must not be handed around on a guess.
---@param id string|nil
---@return boolean
local function owner_alive(id)
	local pid = tonumber(id)
	if not pid or pid <= 0 then
		return false
	end
	-- luv reports a failed kill as (nil, "ESRCH: no such process") rather than raising
	local ok, res, err = pcall(uv.kill, pid, 0)
	if not ok then
		return false
	end
	if res ~= nil then
		return true
	end
	-- not ours to signal
	return type(err) == "string" and err:find("EPERM", 1, true) ~= nil
end

---@param t table|nil
---@return string|nil
local function bound_slot(t, backend)
	local group = group_key(t, backend)
	local id = id_of(t)
	if not group or not id then
		return nil
	end
	for slot, rec in pairs(load().groups[group] or {}) do
		if rec.id == id and rec.ts == ts_of(t) then
			return slot
		end
	end
	return nil
end

---The slot number is a disambiguator, so it is only shown when another slot in
---the same directory carries the same name.
---@param slots table<integer, table>|nil
---@param slot integer
---@param name string
---@return boolean
local function needs_slot(slots, slot, name)
	for other, rec in pairs(slots or {}) do
		if other ~= slot and rec.name == name then
			return true
		end
	end
	return false
end

---@param slots table<integer, table>|nil
---@return integer
local function free_slot(slots)
	local n = 1
	while slots and slots[n] do
		n = n + 1
	end
	return n
end

---Name for the list: a single stored slot is inherited by the next instance in
---the same directory; with several slots only the slot this pid was bound to is
---used. The slot number is shown only when it is needed to disambiguate.
---@param t table|nil target
---@param backend string|nil
---@return string|nil
function M.get(t, backend)
	local slot = bound_slot(t, backend)
	local group = group_key(t, backend)
	local slots = group and load().groups[group] or {}
	local count = vim.tbl_count(slots)
	local key = exact_key(t, backend)
	if key then
		local rec = load().exact[key] or load().exact[id_of(t) or ""]
		if rec and (rec.ts == "" or ts_of(t) == "" or rec.ts == ts_of(t)) then
			return tidy(slot and needs_slot(slots, slot, rec.name) and (rec.name .. " ·" .. slot) or rec.name)
		end
	end
	if not group then
		return nil
	end
	if slot then
		local rec = slots[slot]
		return tidy(needs_slot(slots, slot, rec.name) and (rec.name .. " ·" .. slot) or rec.name)
	end
	if count == 1 then
		local only
		for _, rec in pairs(slots) do
			only = rec
		end
		-- A restart inherits the name; a second live agent in the same directory
		-- does not — that was two instances wearing one name.
		if only and not owner_alive(only.id) then
			return tidy(only.name)
		end
	end
	return nil
end

---Bind a name to this instance and to its directory slot (an empty name clears it).
---@param t table target
---@param backend string|nil
---@param name string
---@return boolean ok
function M.set(t, backend, name)
	local id = id_of(t)
	if not id then
		return false
	end
	name = tidy(tostring(name or "")) or ""
	if name == "" then
		return M.clear(t, backend)
	end
	local store = load()
	local key = exact_key(t, backend)
	if key then
		store.exact[key] = { name = name, ts = ts_of(t), cwd = t.cwd, backend = backend_of(t, backend) }
	end
	local group = group_key(t, backend)
	if group then
		local slots = store.groups[group] or {}
		store.groups[group] = slots
		local slot = bound_slot(t, backend) or free_slot(slots)
		slots[slot] = { name = name, id = id, ts = ts_of(t) }
	end
	return save()
end

---Remove this instance's name and the slot it occupies.
---@param t table target
---@param backend string|nil
---@return boolean ok
function M.clear(t, backend)
	local store = load()
	local key = exact_key(t, backend)
	if key then
		store.exact[key] = nil
	end
	local id = id_of(t)
	if id then
		store.exact[id] = nil
	end
	local slot = bound_slot(t, backend)
	local group = group_key(t, backend)
	if slot and group then
		store.groups[group][slot] = nil
	end
	return save()
end

---A readable name when nothing was stored: the directory, not the pid.
---@param t table|nil
---@return string
function M.default_name(t)
	t = type(t) == "table" and t or {}
	if type(t.title) == "string" and vim.trim(t.title) ~= "" then
		return tidy(t.title)
	end
	-- pi calls every target "pid 1234"; that is the number users cannot use.
	if type(t.label) == "string" and vim.trim(t.label) ~= "" and not t.label:match("^pid ") then
		return tidy(t.label)
	end
	local dir = norm_dir(t.cwd)
	if dir then
		local base = fn.fnamemodify(dir, ":t")
		if base ~= "" and base ~= "/" then
			return tidy(base)
		end
	end
	return tidy(t.label and tostring(t.label) or tostring(t.id or "?"))
end

---@return table
function M.all()
	return vim.deepcopy(load())
end

---Drop exact names for instances that no longer exist. Group slots are kept:
---they are the names that must survive a restart.
---@param live table<string, true> instance ids still alive
---@return integer removed
function M.prune(live)
	local store = load()
	local removed = 0
	for key in pairs(store.exact) do
		local id = tostring(key):match("|([^|]+)$") or tostring(key)
		if not live[id] then
			store.exact[key] = nil
			removed = removed + 1
		end
	end
	if removed > 0 then
		save()
	end
	return removed
end

return M
