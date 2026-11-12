-- lua/ask_agent/backends/herdr.lua
---@brief herdr backend: the agents herdr already recognizes, with the state
---herdr already knows.
--
-- herdr is a terminal workspace manager that watches the agents in its panes and
-- classifies them itself: `idle`, `working`, `blocked` (an approval or question
-- UI it recognized), `done`, `unknown`. That vocabulary is exactly ours, so this
-- backend delegates instead of guessing, and the state layer gets "waiting for
-- you" without screen scraping:
--
--   herdr agent list                 -> {"result": {"agents": [...]}}
--   herdr agent get <name|pane>      -> {"result": {"agent": {...}}}
--   herdr agent prompt <name> <text> -> submit a prompt (rejects when blocked)
--   herdr agent attach <name>        -> the viewer (see ask_agent/views/herdr.lua)
--   herdr agent focus <name>         -> jump out to its pane (see ask_agent/jump.lua)
--
-- One `agent list` per polling pass feeds both `targets()` and `probe()`, so a
-- dashboard refresh costs a single CLI call however many agents are running.
--
-- Opt in (nothing is registered automatically — an agent running under herdr may
-- also be visible through another backend, and you probably do not want it twice):
--
--   ai.setup({ extra = { require("ask_agent.backends.herdr") } })
--
-- Restrict to some workspaces/labels with `M.filter` before passing the module.

local M = { id = "herdr", label = "herdr" }

---Optional: `fun(agent: table): boolean` to drop agents from the list.
---@type fun(agent: table): boolean|nil
M.filter = nil

-- How long one `agent list` is reused (ms). A refresh pass polls every ~2s; this
-- only keeps `probe()` from shelling out once per agent in the same pass.
local TTL = 900
local cache = { ts = -math.huge, agents = {}, by = {} }

---States herdr reports that mean the same thing to us.
local STATE = { idle = "idle", working = "working", blocked = "blocked", done = "done", unknown = "unknown" }

local function cli(args)
	if vim.fn.executable("herdr") ~= 1 then
		return nil, "herdr is not installed"
	end
	local ok, res = pcall(function()
		return vim.system({ "herdr", unpack(args) }, { text = true }):wait()
	end)
	if not ok then
		return nil, tostring(res)
	end
	if res.code ~= 0 then
		local err = (res.stderr or ""):gsub("%s+$", "")
		if err == "" then
			err = "herdr " .. table.concat(args, " ") .. " failed"
		end
		return nil, err
	end
	local decoded, data = pcall(vim.json.decode, res.stdout or "")
	if not decoded or type(data) ~= "table" then
		return nil, "herdr returned no JSON"
	end
	return data
end

-- pane -> foreground pid, so an agent that herdr did not start (pi begun by hand
-- inside a herdr pane) can still be recognized as living in that pane. Built by
-- asking every pane for its process info, which is one call per pane, so it is
-- cached longer than the agent list.
local PID_TTL = 3000
local pid_cache = { ts = -math.huge, by = {} }

---Which herdr pane is running this pid?
---@param pid string|number|nil
---@return string|nil pane
function M.pane_of_pid(pid)
	local wanted = tonumber(pid)
	if not wanted then
		return nil
	end
	local now = vim.uv.now()
	if now - pid_cache.ts >= PID_TTL then
		local by = {}
		local list = cli({ "pane", "list" })
		local rows = (type(list) == "table" and list.result and list.result.panes) or {}
		for _, row in ipairs(rows) do
			local id = row.pane_id or row.id
			if id then
				local info = cli({ "pane", "process-info", "--pane", id })
				local procs = info and info.result and info.result.process_info
				for _, proc in ipairs((procs and procs.foreground_processes) or {}) do
					if proc.pid then
						by[tostring(proc.pid)] = id
					end
				end
				-- the pane's shell, in case the agent is its foreground child
				if procs and procs.shell_pid then
					by[tostring(procs.shell_pid)] = by[tostring(procs.shell_pid)] or id
				end
			end
		end
		pid_cache = { ts = now, by = by }
	end
	return pid_cache.by[tostring(wanted)]
end

---Index one agent record by name and by pane id.
---@param a table
local function index(a)
	local rec = {
		name = a.name,
		pane = a.pane_id,
		agent = a.agent,
		cwd = a.cwd or a.foreground_cwd,
		status = STATE[a.agent_status] or "unknown",
		title = a.terminal_title_stripped,
		workspace = a.workspace_id,
		tab = a.tab_id,
	}
	cache.agents[#cache.agents + 1] = rec
	if rec.name then
		cache.by[rec.name] = rec
	end
	if rec.pane then
		cache.by[rec.pane] = rec
	end
end

---Re-read `herdr agent list` (no-op inside the TTL unless `force`).
---@param force boolean|nil
---@return table[] agents
function M.refresh(force)
	local now = vim.uv.now()
	if not force and now - cache.ts < TTL then
		return cache.agents
	end
	local data = cli({ "agent", "list" })
	cache = { ts = now, agents = {}, by = {} }
	for _, a in ipairs(type(data) == "table" and (data.result or {}).agents or {}) do
		index(a)
	end
	return cache.agents
end

---Locate one agent by name or pane id (cached, refreshed when unknown).
---@param target table
---@return table|nil
local function locate(target)
	local spec = target.herdr or {}
	local key = spec.agent or spec.id or target.pane or target.id
	if not key then
		return nil
	end
	if vim.uv.now() - cache.ts >= TTL then
		M.refresh(true)
	end
	local hit = cache.by[key]
	if hit then
		return hit
	end
	M.refresh(true)
	hit = cache.by[key]
	if not hit and vim.uv.now() - cache.ts > TTL then
		local data = cli({ "agent", "get", tostring(key) })
		local a = type(data) == "table" and (data.result or {}).agent
		if a then
			cache.by[key] = {
				name = a.name,
				pane = a.pane_id,
				agent = a.agent,
				cwd = a.cwd or a.foreground_cwd,
				status = STATE[a.agent_status] or "unknown",
				title = a.terminal_title_stripped,
				workspace = a.workspace_id,
				tab = a.tab_id,
			}
		end
	end
	return cache.by[key]
end

---Live herdr agents as targets. The `herdr` sub-table is what the viewer float
---(`herdr agent attach`) and the jump adapter (`herdr agent focus`) look for.
---@return table[]
function M.targets()
	local out = {}
	if not M.available() then
		return out
	end
	for _, a in ipairs(M.refresh()) do
		if a.name and (not M.filter or M.filter(a)) then
			out[#out + 1] = {
				id = a.name,
				label = a.name,
				cwd = a.cwd,
				pane = a.pane,
				-- which recognized agent it is, for pickers that want to say so
				kind = a.agent,
				herdr = { agent = a.name, pane = a.pane },
			}
		end
	end
	return out
end

---Herdr already knows whether the agent is waiting for you, so the probe just
---reports it. `running` stays true while herdr still lists the agent: a target
---that vanished from the list is gone, not busy.
---@param target table
---@return { running: boolean, state?: string, busy?: boolean, detail?: string }
function M.probe(target)
	local a = locate(target)
	if not a then
		return { running = true }
	end
	local state = a.status
	local out = { running = true }
	if state == "unknown" then
		return out
	end
	out.state = state
	out.busy = state == "working"
	if state == "blocked" then
		out.detail = "herdr saw an approval or question in its pane"
	end
	return out
end

---Deliver a prompt. herdr rejects the call when the agent is blocked, which is
---the honest answer — the user has to clear the dialog first.
---@param target table
---@param text string
---@return boolean ok, string|nil err
function M.send(target, text)
	local a = locate(target)
	local name = (a and a.name) or (target.herdr or {}).agent or target.id
	if not name then
		return false, "herdr: no agent name"
	end
	local data, err = cli({ "agent", "prompt", tostring(name), text })
	if not data then
		if err and err:find("agent_blocked", 1, true) then
			return false, "the agent is blocked: clear its dialog first"
		end
		return false, err or "herdr agent prompt failed"
	end
	-- the state moved (working), so the next probe should not trust the cache
	M.invalidate()
	return true
end

---Whether herdr can be used at all.
---@return boolean ok, string|nil reason
function M.available()
	if vim.fn.executable("herdr") ~= 1 then
		return false, "herdr is not installed"
	end
	return true
end

---Drop the cache (tests, and after we know state moved).
function M.invalidate()
	cache = { ts = -math.huge, agents = {}, by = {} }
	pid_cache = { ts = -math.huge, by = {} }
end

return M
