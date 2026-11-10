-- lua/ask_agent/layouts/rex.lua
---@brief Layout adapter for rex (terminal multiplexer): reads its pane geometry so
---agent instances can be mapped onto concrete cells in the terminal.
--
-- Data source: `rex session inspect <session> --json` (~30ms in practice), whose
-- core structure is
--   { label, active_window_id, windows = { { window_id, layers = { { kind = "tiled",
--     layout = <node>, blocks = { ... } } } } }, blocks = { { block_id, label } } }
--   <node> = { block_id, rect = {x, y, w, h} }              -- leaf: 0..1 normalised
--          | { split = { direction, ratio, before, after } } -- branch
--
-- When the nvim process itself lives in rex it gets REX_SESSION / REX_BLOCK in
-- its environment; that locates "the window I am looking at", and flattening
-- that window's leaves gives the map data.
local M = { id = "rex", label = "rex" }

local CACHE_MS = 1500
local cache = {}

local function env(name)
	local v = vim.env[name]
	if type(v) ~= "string" or v == "" then
		return nil
	end
	return v
end

function M.session()
	return env("REX_SESSION")
end

function M.block()
	return env("REX_BLOCK")
end

---Whether the map is usable at all: inside rex and the rex command is available.
function M.available()
	return M.session() ~= nil and vim.fn.executable("rex") == 1
end

---Get the inspect result for a session (short cache so one picker session does
---not spawn the process over and over).
---@param session string|nil
---@return table|nil data, string|nil err
function M.inspect(session)
	session = session or M.session()
	if not session then
		return nil, "not inside rex (no REX_SESSION)"
	end
	local now = vim.uv.now()
	local hit = cache[session]
	if hit and now - hit.ts < CACHE_MS then
		return hit.data
	end
	local ok, res = pcall(function()
		return vim.system({ "rex", "session", "inspect", session, "--json" }, { text = true }):wait(2000)
	end)
	if not ok or not res or res.code ~= 0 then
		return nil, "rex session inspect failed"
	end
	local decoded, data = pcall(vim.json.decode, res.stdout)
	if not decoded or type(data) ~= "table" then
		return nil, "cannot parse rex output"
	end
	cache[session] = { ts = now, data = data }
	return data
end

local function flatten(node, out)
	if type(node) ~= "table" then
		return
	end
	if node.block_id then
		if node.rect then
			table.insert(out, { block_id = node.block_id, rect = node.rect })
		end
		return
	end
	local split = node.split
	if type(split) ~= "table" then
		return
	end
	flatten(split.before, out)
	flatten(split.after, out)
end

---Flatten every layer of a window -> { { id, block_id, rect, kind }, ... }
--
-- Array order is stacking order: the tiled layer is at the bottom, floating
-- layers stack upwards in array order (later entries are on top, matching rex's
-- raise_layer/lower_layer order). `rect` is already absolute within the whole
-- window (floating layers write their bounds into it), so the layers can simply
-- be painted over each other.
---@param window table
---@return table[]
function M.panes(window)
	local out = {}
	for _, layer in ipairs((window or {}).layers or {}) do
		local kind = layer.kind or "tiled"
		if layer.layout then
			local layer_panes = {}
			flatten(layer.layout, layer_panes)
			for _, p in ipairs(layer_panes) do
				p.kind = kind
				p.id = p.block_id
				table.insert(out, p)
			end
		end
	end
	return out
end

---block_id -> label (things like "lively-prairie") lookup table.
---@param data table
---@return table<string, string>
function M.labels(data)
	local out = {}
	local function collect(blocks)
		for _, b in ipairs(blocks or {}) do
			if b.block_id then
				out[b.block_id] = b.label
			end
		end
	end
	collect(data.blocks)
	for _, w in ipairs(data.windows or {}) do
		for _, layer in ipairs(w.layers or {}) do
			collect(layer.blocks)
		end
	end
	return out
end

---Pane id nvim is focused on (the "cursor" of the map).
---@return string|nil
function M.cursor()
	return M.block()
end

---Panes of a window, always from the full split tree.
--
-- Rex zoom (`rex zoom`) only changes what is drawn; the window still reports its
-- full split tree. The map needs that tree: agents often live in a pane that is
-- hidden by zoom, and collapsing to the zoomed pane made them unplaceable (the
-- picker then fell back to the list). Keep every pane so the map stays useful.
---@param window table
---@return table[]
function M.visible_panes(window)
	return M.panes(window)
end

---Every window of a session, in map order: the window nvim lives in first, then
---the active window, then the rest. `panes` already accounts for zoom.
--
-- The session can have several windows (each with its own split tree), and agents
-- may live in any of them; drawing only nvim's window silently dropped the rest.
---@param session string|nil
---@return table[] windows, table|nil data, string|nil err
function M.windows(session)
	local data, err = M.inspect(session)
	if not data then
		return {}, nil, err
	end
	local want = M.block()
	local cur, active
	local rest = {}
	for _, w in ipairs(data.windows or {}) do
		local entry = { window = w, panes = M.visible_panes(w) }
		local is_current = false
		if want then
			for _, p in ipairs(entry.panes) do
				if p.block_id == want then
					is_current = true
					break
				end
			end
		end
		entry.current = is_current
		if is_current and not cur then
			cur = entry
		elseif w.window_id == data.active_window_id and not active then
			active = entry
		else
			rest[#rest + 1] = entry
		end
	end
	local out = {}
	if cur then
		out[#out + 1] = cur
	end
	if active then
		out[#out + 1] = active
	end
	for _, e in ipairs(rest) do
		out[#out + 1] = e
	end
	return out, data
end

---Which pane hosts a given agent instance: the rex locator is stamped onto the
---target by the backend (`target.rex = { session, block }`).
---@param t table
---@return string|nil
function M.match(t)
	local loc = t and t.rex
	return type(loc) == "table" and loc.block or nil
end

---Adapter contract: the window nvim lives in (falls back to the active window).
---@param session string|nil
---@return table|nil window, table|nil data, string|nil err
function M.window(session)
	return M.current_window(session)
end

---The window nvim itself lives in (falls back to the active window).
---@param session string|nil
---@return table|nil window, table|nil data, string|nil err
function M.current_window(session)
	local data, err = M.inspect(session)
	if not data then
		return nil, nil, err
	end
	local want = M.block()
	if want then
		for _, w in ipairs(data.windows or {}) do
			for _, p in ipairs(M.panes(w)) do
				if p.block_id == want then
					return w, data
				end
			end
		end
	end
	for _, w in ipairs(data.windows or {}) do
		if w.window_id == data.active_window_id then
			return w, data
		end
	end
	return (data.windows or {})[1], data
end

require("ask_agent.layouts").register(M)

return M
