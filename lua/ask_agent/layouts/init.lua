-- lua/ask_agent/layouts/init.lua
---@brief Layout adapters: how the plugin learns where each agent instance sits on screen.
--
-- The map picker needs pane geometry; every terminal multiplexer reports it
-- differently, so multiplexers are adapters, not hardcoded calls. A layout
-- adapter is a plain table:
--
--   id            unique id, e.g. "rex"
--   label         shown in prompts and health
--   available()   -> ok:boolean, reason:string|nil
--   window()      -> win:table|nil, data:table|nil, err:string|nil
--                    "the window nvim itself lives in" (opaque to core)
--   panes(win)    -> { { id = string, rect = { x, y, w, h }, kind = "tiled"|"float" }, ... }
--                    rect is normalised 0..1 within that window, y measured from the top;
--                    array order is stacking order (later entries are painted on top)
--   match(t)      -> pane id|nil  -- which pane hosts the agent instance `t`
--   cursor()      -> pane id|nil  -- the pane nvim is focused on (optional)
--   labels(data)  -> table<string, string>  -- pane id -> human label (optional)
--
-- Adapters register themselves (rex does it on require); extra ones can be added
-- from a config with `require("ask_agent").register_layout(mod)`.
local M = {}

local adapters = {}

-- Built-in adapters register themselves, but only on first use: loading them from
-- here at load time would require this module again from inside its own load.
local builtins_loaded = false
local function load_builtins()
	if builtins_loaded then
		return
	end
	builtins_loaded = true
	pcall(require, "ask_agent.layouts.rex")
end

---@param mod table
function M.register(mod)
	if type(mod) ~= "table" or type(mod.id) ~= "string" then
		error("layout adapter needs an id")
	end
	adapters[mod.id] = mod
	return mod
end

---@param id string
---@return table|nil
function M.get(id)
	load_builtins()
	return adapters[id]
end

---Registered adapter ids, in registration order.
---@return string[]
function M.list()
	load_builtins()
	local ids = {}
	for id in pairs(adapters) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	return ids
end

---Whatever the user asked for first, else the first one that reports itself usable.
---@param prefer string|nil
---@return table|nil adapter
function M.active(prefer)
	load_builtins()
	if prefer then
		local mod = adapters[prefer]
		if mod then
			return mod
		end
	end
	for _, id in ipairs(M.list()) do
		local mod = adapters[id]
		local ok = type(mod.available) ~= "function" and true or mod.available()
		if ok then
			return mod
		end
	end
	return nil
end

return M
