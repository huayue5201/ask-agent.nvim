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
--   }
--
-- Built in: rex (target.rex = { session, block }) and tmux (target.pane).
-- Register your own with ask.register_jump({...}) — no plugin changes needed.

local M = {}
local notify = require("ask_agent.notify")

local adapters = {}

local function sort()
	table.sort(adapters, function(a, b)
		return (a.priority or 10) > (b.priority or 10)
	end)
end

---Register (or replace, by id) a jump adapter.
---@param mod table { id, can, focus, priority? }
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
	local reasons = {}
	for _, a in ipairs(adapters) do
		local can = pcall(a.can, target)
		if can then
			local ok, err = pcall(a.focus, target)
			if ok then
				return true, nil
			end
			reasons[#reasons + 1] = tostring(err)
		end
	end
	if #reasons == 0 then
		return false, "no jump adapter knows this agent (ask.register_jump({...}) adds one)"
	end
	return false, table.concat(reasons, "; ")
end

-- ================================
-- Built-in adapters
-- ================================

---Run commands one after another; `on_error(cmd, res)` gets the first failure.
local function run(cmds, on_error)
	local function step(i)
		if i > #cmds then
			return
		end
		vim.system(cmds[i], { text = true }, function(res)
			if res.code ~= 0 then
				vim.schedule(function()
					on_error(cmds[i], res)
				end)
				return
			end
			vim.schedule(function()
				step(i + 1)
			end)
		end)
	end
	step(1)
end

-- The rex app shows one session at a time and one window (tab) per session, so
-- `block focus` alone only reaches panes of the window that is already visible.
-- Find the owning window first, focus it, and finally ask the app to show the
-- session — three server/app actions, in that order.

---The connected rex app to address with `-C`; REX_CLIENT wins when set. Without
---one, `session.select` has no visible effect (it is a client action).
---@param session string|nil
---@return string|nil client
local function rex_bin()
	return require("ask_agent.rex_cli").path() or "rex"
end

---@param session string|nil
---@return string|nil client
local function app_client(session)
	local env = vim.env.REX_CLIENT
	if type(env) == "string" and env ~= "" then
		return env
	end
	local ok, res = pcall(function()
		return vim.system({ rex_bin(), "client", "ls", "--json" }, { text = true }):wait(1000)
	end)
	if not ok or not res or res.code ~= 0 then
		return nil
	end
	local decoded, data = pcall(vim.json.decode, res.stdout)
	if not decoded or type(data) ~= "table" then
		return nil
	end
	local fallback
	for _, c in ipairs(data.clients or {}) do
		local info = c.info or {}
		if info.kind == "app" and c.connection_state == "connected" then
			local id = c.client_id or info.label
			if id then
				-- prefer the app that already has the session open
				for _, sid in ipairs(c.session_ids or {}) do
					if sid == session then
						return id
					end
				end
				fallback = fallback or id
			end
		end
	end
	return fallback
end

---@param block string
---@param session string|nil
---@return string|nil window_id
local function block_window(block, session)
	local cmd = { rex_bin(), "block", "inspect", block }
	if session then
		vim.list_extend(cmd, { "-s", session })
	end
	local ok, res = pcall(function()
		return vim.system(cmd, { text = true }):wait(1000)
	end)
	if not ok or not res or res.code ~= 0 then
		return nil
	end
	local decoded, data = pcall(vim.json.decode, res.stdout)
	if not decoded or type(data) ~= "table" then
		return nil
	end
	return data.block and data.block.window_id or nil
end

M.register({
	id = "rex",
	priority = 20,
	can = function(target)
		return type(target.rex) == "table" and target.rex.block ~= nil
	end,
	focus = function(target)
		local session, block = target.rex.session, target.rex.block
		local window = block_window(block, session)
		local cmds = {}
		if window then
			local focus_window = { rex_bin(), "window", "focus", window }
			if session then
				vim.list_extend(focus_window, { "-s", session })
			end
			cmds[#cmds + 1] = focus_window
		end
		local focus_block = { rex_bin(), "block", "focus", block }
		if session then
			vim.list_extend(focus_block, { "-s", session })
		end
		cmds[#cmds + 1] = focus_block
		if session then
			local select = { rex_bin() }
			local client = app_client(session)
			if client then
				vim.list_extend(select, { "-C", client })
			end
			vim.list_extend(select, { "do", "session.select", "session_id=" .. session })
			cmds[#cmds + 1] = select
		end
		run(cmds, function(cmd, res)
			notify.notify(
				("[ask_agent] %s failed: %s"):format(cmd[1] .. " " .. cmd[2], (res.stderr or ""):gsub("%s+$", "")),
				vim.log.levels.WARN
			)
		end)
	end,
})

M.register({
	id = "herdr",
	priority = 15,
	can = function(target)
		if type(target.pane) == "string" and target.pane ~= "" then
			return true
		end
		local spec = target.herdr
		if type(spec) == "table" and (spec.agent or spec.id or spec.pane) ~= nil then
			return true
		end
		-- an agent herdr did not start (pi begun by hand in a pane) is matched
		-- by pid, the same way the viewer matches it
		if target.pid then
			local ok, backend = pcall(require, "ask_agent.backends.herdr")
			return ok and type(backend.pane_of_pid) == "function" and backend.pane_of_pid(target.pid) ~= nil
		end
		return false
	end,
	focus = function(target)
		local spec = type(target.herdr) == "table" and target.herdr or {}
		local name = spec.agent or spec.id or spec.pane or target.pane
		if not name and target.pid then
			local ok, backend = pcall(require, "ask_agent.backends.herdr")
			name = ok and backend.pane_of_pid and backend.pane_of_pid(target.pid) or nil
		end
		-- `agent focus` takes a name or a pane id, switches to its workspace/tab
		-- and marks the completion seen on the way, which is what we want here.
		run({ { "herdr", "agent", "focus", tostring(name) } }, function(cmd, res)
			notify.notify(
				("[ask_agent] herdr agent focus failed: %s"):format((res.stderr or ""):gsub("%s+$", "")),
				vim.log.levels.WARN
			)
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
