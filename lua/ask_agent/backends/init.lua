-- lua/ask_agent/backends/init.lua
---@brief Backend registry plus the shared "pick a target" strategy.
--
-- A backend module is the extension point for talking to another agent. It only
-- has to implement four things:
--   id       string                          unique id (used by :AskAgentBackend)
--   label    string                          human-readable name
--   targets  fun(): table[]                  available targets, empty = unusable
--   send     fun(target, text): ok, err      deliver already-rendered text
-- Each target is `{ id, label, cwd, ts?, sock?, rex = { session, block }?, icon?, avoid? }`:
-- the rest is backend-specific (pi uses pid/sock/cwd, tmux uses pane, ...). Only
-- `cwd` (may be nil) and `label` are required by this module.
--
-- Optional members:
--   icon       string                        glyph for pickers/notifications
--   available  fun(): ok, reason?            default = #targets() > 0
--   status     fun(): ok, reason?            alias for available, if provided
--   probe      fun(target): { running: boolean, state?: string, kind?: string,
--                              progress?: integer, msg?: string, busy?: boolean, detail?: string }
--                                            live check for pickers and the state layer (default: a
--                                            target is assumed to be running unless stale).
--                                            `state` is one of idle/working/blocked/done/error;
--                                            prefer it when the agent can report it, `busy` is the
--                                            legacy shorthand for working, and no `state` at all
--                                            means "unknown" (the picker still sends).
--                                            `kind` (permission/question/auth) refines blocked.
--   stale_targets fun(): table[]             recently exited instances, shown greyed out in
--                                            the picker so the user sees what is *not* running
--
-- Adding a new agent means writing `lua/ask_agent/backends/<name>.lua`, or
-- creating one in three lines with the `generic.tmux()` factory from
-- `lua/ask_agent/backends/generic.lua`. Neither requires touching this file.
-- Only "deliver to an already running process" is supported here; spawning,
-- reading stdout and session management belong to codecompanion.

local M = {}

---@type table<string, table>
local registry = {}
---@type string[]
local order = {}

---Register a backend. The same id overwrites (handy for reloads/tests).
---@param mod table
function M.register(mod)
	assert(type(mod) == "table" and type(mod.id) == "string", "backend needs an id")
	assert(type(mod.targets) == "function", ("backend %s is missing targets()"):format(mod.id))
	assert(type(mod.send) == "function", ("backend %s is missing send()"):format(mod.id))
	if not registry[mod.id] then
		table.insert(order, mod.id)
	end
	registry[mod.id] = mod
end

---@param id string
---@return table|nil
function M.get(id)
	return registry[id]
end

---Whether a backend is usable (single error-tolerant entry point: available()
---may return available, reason).
---@param mod table
---@return boolean available, string? reason
function M.status(mod)
	local check = mod.available or mod.status or function()
		return #mod.targets() > 0
	end
	local ok, avail, reason = pcall(check)
	if not ok then
		return false, tostring(avail)
	end
	return avail and true or false, reason
end

---List every backend in registration order (unusable ones included, with reason).
---@return { id: string, label: string, available: boolean, reason: string? }[]
function M.list()
	local out = {}
	for _, id in ipairs(order) do
		local mod = registry[id]
		local available, reason = M.status(mod)
		out[#out + 1] = {
			id = id,
			label = mod.label or id,
			icon = mod.icon or require("ask_agent.icons").find(id),
			available = available,
			reason = reason,
		}
	end
	return out
end

---List candidate targets for an interactive picker, ordered by
---"same cwd > same project > other; live > stale; unmanaged > managed".
---tier=1 means the cwd matches exactly (the strict tier that may send directly).
---Stale candidates (opts.include_stale) carry `stale=true`: they are only there so the picker
---can show that instance as "not running"; they must never be sent to.
---@param mod table
---@param cwd string|nil
---@param opts { related?: boolean, single?: boolean, include_stale?: boolean, stale_limit?: integer }|nil
---@return table[] {{ target: table, tier: integer, stale?: boolean }}
function M.candidates(mod, cwd, opts)
	opts = opts or {}
	local function norm(p)
		if not p then
			return nil
		end
		return vim.uv.fs_realpath(p) or p
	end
	local ok, targets = pcall(mod.targets)
	if not ok then
		return {}
	end
	cwd = norm(cwd or vim.fn.getcwd())
	local out = {}
	local function add(t, stale)
		local tcwd = norm(t.cwd)
		local tier = 3 -- a different project
		if tcwd == cwd then
			tier = 1
		elseif tcwd and (cwd:sub(1, #tcwd) == tcwd or tcwd:sub(1, #cwd) == cwd) then
			tier = 2
		end
		table.insert(out, { target = t, tier = tier, stale = stale or nil })
	end
	for _, t in ipairs(targets or {}) do
		add(t, false)
	end
	if opts.include_stale and type(mod.stale_targets) == "function" then
		local ok, dead = pcall(mod.stale_targets)
		if ok then
			local limit = opts.stale_limit or 3
			for i, t in ipairs(dead or {}) do
				if i > limit then
					break
				end
				add(t, true)
			end
		end
	end
	table.sort(out, function(a, b)
		if a.tier ~= b.tier then
			return a.tier < b.tier
		end
		if (a.stale ~= nil) ~= (b.stale ~= nil) then
			return not a.stale -- live instances first
		end
		local aa, bb = a.target.avoid ~= nil, b.target.avoid ~= nil
		if aa ~= bb then
			return not aa
		end
		return (a.target.ts or 0) > (b.target.ts or 0)
	end)
	return out
end

local STATES = { idle = true, working = true, blocked = true, done = true, error = true }

---Is this target usable right now, and what is it doing? Backends may implement probe();
---stale candidates are never running, and a backend without probe() is trusted to be
---running but its state stays unknown (its targets() already filtered).
---@param mod table
---@param target table
---@param stale boolean|nil candidate came from stale_targets()
---@return { running: boolean, state: string, kind?: string, progress?: integer, msg?: string, busy?: boolean, detail?: string }
function M.probe(mod, target, stale)
	if stale then
		return { running = false, state = "gone" }
	end
	if type(mod.probe) == "function" then
		local ok, res = pcall(mod.probe, target)
		if ok and type(res) == "table" then
			local running = res.running ~= false
			local state = running and (STATES[res.state] and res.state or (res.busy and "working") or "idle") or "gone"
			return {
				running = running,
				state = state,
				kind = res.kind,
				progress = res.progress,
				msg = res.msg,
				busy = state == "working",
				detail = res.detail or res.msg,
			}
		elseif ok and res == false then
			return { running = false, state = "gone" }
		end
	end
	return { running = true, state = "unknown" }
end

---Pick a target. Strict by default: only an identical cwd (after realpath
---normalisation) matches, so a question is never dropped into another project's
---agent and pollutes its context. Looser modes must be enabled explicitly.
---Targets carrying an `avoid` field (e.g. a pi hosted by an ACP client) are
---excluded by default: they have their own host UI, replies never come back, and
---silently sending into them just looks like nothing happened.
---@param mod table
---@param cwd string|nil
---@param opts { related?: boolean, single?: boolean }|nil related=allow parent/child dirs, single=accept the only target
---@return table|nil target, string|nil err
function M.pick(mod, cwd, opts)
	opts = opts or {}
	-- Normalise paths: on macOS /tmp and /private/tmp, and symlinked directories,
	-- all collapse onto the same cwd.
	local function norm(p)
		if not p then
			return nil
		end
		return vim.uv.fs_realpath(p) or p
	end
	cwd = norm(cwd or vim.fn.getcwd())
	local ok, targets = pcall(mod.targets)
	if not ok then
		return nil, ("%s backend failed to get targets: %s"):format(mod.label or mod.id, tostring(targets))
	end
	targets = targets or {}
	if #targets == 0 then
		local _, reason = M.status(mod)
		return nil, ("%s unavailable: %s"):format(mod.label or mod.id, reason or "no live instances")
	end

	local usable, skipped = {}, {}
	for _, t in ipairs(targets) do
		table.insert(t.avoid and skipped or usable, t)
	end
	targets = usable
	if #targets == 0 then
		local lines = {}
		for _, t in ipairs(skipped) do
			table.insert(lines, ("  %s  %s  <- %s"):format(t.label or t.id, t.cwd or "?", t.avoid))
		end
		return nil,
			("%s only found skipped instances:\n%s\nUse that host's own input (e.g. the codecompanion chat buffer), or select it explicitly with :AskAgentTarget."):format(
				mod.label or mod.id,
				table.concat(lines, "\n")
			)
	end

	-- 1) exact cwd match (targets are already sorted by activity, take the first)
	for _, t in ipairs(targets) do
		if norm(t.cwd) == cwd then
			return t
		end
	end

	-- 2) a unique parent/child directory pair -- only when explicitly enabled
	--    (the repository root vs. a subdirectory case)
	if opts.related then
		local related = {}
		for _, t in ipairs(targets) do
			local tcwd = norm(t.cwd)
			if tcwd and (cwd:sub(1, #tcwd) == tcwd or tcwd:sub(1, #cwd) == cwd) then
				table.insert(related, t)
			end
		end
		if #related == 1 then
			return related[1]
		end
	end

	-- 3) only one target -- also only when explicitly enabled, otherwise this
	--    would happily send into an unrelated project
	if opts.single and #targets == 1 then
		return targets[1]
	end

	local names = {}
	for _, t in ipairs(targets) do
		table.insert(names, ("  %s  %s"):format(t.label or t.id, t.cwd or "?"))
	end
	for _, t in ipairs(skipped) do
		table.insert(names, ("  %s  %s  (skipped: %s)"):format(t.label or t.id, t.cwd or "?", t.avoid))
	end
	return nil,
		("%s has no target for %s (use :AskAgentTarget to choose one explicitly, or :AskAgentBackend to switch backend). Available:\n%s"):format(
			mod.label or mod.id,
			cwd,
			table.concat(names, "\n")
		)
end

return M
