-- lua/ask_agent/state.lua
---@brief The single source of truth for "what are my agents doing".
--
-- Every backend contributes instances (targets) and their raw state; this module
-- polls them, merges the better sources (rex's OSC 7501 program status wins over
-- a busy marker), turns raw states into user-meaningful ones (a turn that ended
-- right after we sent something is `done`), keeps the dispatch log that lets a
-- `done` be attributed, and publishes changes as events.
--
-- Views (picker dots, `:AskAgentDashboard`, `ask_agent.statusline()`, other
-- plugins) only ever read from here, so they cannot disagree.
--
--   state.on("state", fn)    -- a state changed (fn(rec, prev_state))
--   state.on("update", fn)   -- anything changed, including msg/progress (fn(rec))
--   state.on("done"|"blocked"|"error", fn)
--   state.all()              -- every instance, most attention-worthy first
--   state.dispatch(backend, id, text, correlation)
--
-- States: idle | working | blocked | done | error | unknown | gone.
-- `blocked` carries `kind` (permission | question | auth) and, like `done`,
-- stays until acknowledged.

local backends = require("ask_agent.backends")
local aliases = require("ask_agent.aliases")
local rex = require("ask_agent.status.rex")

local M = {}

---Suppress "finished"/"needs you" notifications (setup({ state_notify = false })).
M.notify = true

local agents, order = {}, {}
local listeners = {}
local timer, refreshing = nil, false

local ORDER = { blocked = 1, done = 2, error = 3, working = 4, unknown = 5, idle = 6, gone = 7 }
local KIND = { permission = 0, question = 1, auth = 2 }
local NOTIFY_GAP = 30000
local PRUNE_MS = 600000

---@param backend string
---@param id string
---@return string
local function key_of(backend, id)
	return backend .. ":" .. tostring(id)
end

---Lower number = more attention-worthy (permission > question > done > error > working > idle).
---@param rec table
---@return integer
function M.priority(rec)
	local base = (ORDER[rec.state] or ORDER.unknown) * 10
	if rec.state == "blocked" then
		base = base + (KIND[rec.kind] or 3)
	elseif rec.state == "done" and not rec.unread then
		base = base + 5
	end
	if rec.gone then
		base = base + 1
	end
	return base
end

---@param rec table
---@return string
function M.name(rec)
	return aliases.get(rec.target) or (rec.target and (rec.target.label or rec.target.id)) or rec.id
end

---@param event string
---@param fn function
---@return fun() unsubscribe
function M.on(event, fn)
	local list = listeners[event] or {}
	listeners[event] = list
	table.insert(list, fn)
	return function()
		for i, f in ipairs(list) do
			if f == fn then
				table.remove(list, i)
				return
			end
		end
	end
end

---@param event string
---@param ... any
local function emit(event, ...)
	for _, fn in ipairs(listeners[event] or {}) do
		pcall(fn, ...)
	end
end

---@param rec table
local function notify_change(rec)
	if not M.notify or rec.gone then
		return
	end
	local now = vim.uv.now()
	if rec.notified and now - rec.notified < NOTIFY_GAP then
		return
	end
	rec.notified = now
	local name = M.name(rec)
	if rec.state == "blocked" then
		local what = rec.kind == "permission" and "needs your permission" or "is waiting for you"
		vim.notify(
			("[%s] %s %s%s"):format(rec.backend, name, what, rec.msg and (": " .. rec.msg) or ""),
			vim.log.levels.WARN
		)
	elseif rec.state == "done" then
		vim.notify(
			("[%s] %s finished%s"):format(rec.backend, name, rec.msg and (": " .. rec.msg) or ""),
			vim.log.levels.INFO
		)
	elseif rec.state == "error" then
		vim.notify(
			("[%s] %s failed%s"):format(rec.backend, name, rec.msg and (": " .. rec.msg) or ""),
			vim.log.levels.ERROR
		)
	end
end

---Apply a new observation to a record, emitting only what actually changed.
---@param rec table
---@param st { state: string, kind?: string, progress?: integer, msg?: string, gone?: boolean }
local function apply(rec, st)
	local prev = rec.state
	local state, kind = st.state, st.kind
	-- Completion inference for sources that cannot say "done" (tmux hooks, pi busy flags):
	-- a turn that ends after one of our sends means our message was answered.
	if state == "idle" and prev == "working" and rec.dispatch and (rec.dispatch.ts or 0) > (rec.idle_at or 0) then
		state, kind = "done", nil
		rec.unread = true
	end
	-- a finished turn stays `done` until acknowledged, even though the source now says idle
	if state == "idle" and prev == "done" and rec.unread then
		state = "done"
	end
	local changed = state ~= prev
		or kind ~= rec.kind
		or st.msg ~= rec.msg
		or st.progress ~= rec.progress
		or (st.gone or false) ~= (rec.gone or false)
	if not changed then
		return
	end
	rec.state, rec.kind, rec.progress, rec.msg = state, kind, st.progress, st.msg
	rec.gone = st.gone or nil
	if changed and state ~= prev then
		rec.since = vim.uv.now()
		if state == "idle" then
			rec.idle_at = rec.since
		end
		if state ~= "done" then
			rec.unread = false
		end
	end
	emit("update", rec)
	if state == prev then
		return
	end
	emit("state", rec, prev)
	emit(state, rec, prev)
	if prev ~= nil then
		notify_change(rec)
	end
	vim.schedule(function()
		pcall(vim.api.nvim_exec_autocmds, "User", {
			pattern = "AskAgentStateChanged",
			data = { agent = rec, prev = prev },
		})
	end)
end

---@param mod table
---@param t table
---@return table record
local function ensure(mod, t)
	local key = key_of(mod.id, t.id)
	local rec = agents[key]
	if not rec then
		rec = { key = key, backend = mod.id, id = tostring(t.id), state = "unknown", since = vim.uv.now() }
		agents[key] = rec
		table.insert(order, key)
	end
	rec.target = t
	return rec
end

---One polling pass over every registered backend. Cheap for a 2s timer: targets()
---only reads files / lists panes, and the expensive per-block source (rex) is
---queried asynchronously.
function M.refresh()
	if refreshing then
		return
	end
	refreshing = true
	local seen = {}
	for _, info in ipairs(backends.list()) do
		local mod = backends.get(info.id)
		if mod and info.available then
			local ok, targets = pcall(mod.targets)
			for _, t in ipairs(ok and targets or {}) do
				local rec = ensure(mod, t)
				seen[rec.key] = true
				local st = backends.probe(mod, t)
				apply(rec, {
					state = st.state,
					kind = st.kind,
					progress = st.progress,
					msg = st.msg or st.detail,
					gone = not st.running,
				})
				-- rex reports the real state for agents that speak OSC 7501; apply it when it arrives
				if t.rex and not rec.rex_pending then
					rec.rex_pending = true
					rex.query(t.rex, function(value)
						rec.rex_pending = nil
						if value and agents[rec.key] == rec then
							apply(
								rec,
								{ state = value.state, kind = value.kind, progress = value.progress, msg = value.msg }
							)
						end
					end)
				end
			end
		end
	end
	local now = vim.uv.now()
	for _, key in ipairs(order) do
		local rec = agents[key]
		if not seen[key] and not rec.gone then
			apply(rec, { state = rec.state, kind = rec.kind, msg = rec.msg, gone = true })
		elseif rec.gone and (rec.state == "idle" or rec.state == "unknown") and now - (rec.since or 0) > PRUNE_MS then
			M.dismiss(key)
		end
	end
	refreshing = false
end

---Start the polling timer.
---@param interval integer|nil ms (default 2000)
function M.start(interval)
	M.stop()
	timer = vim.uv.new_timer()
	timer:start(0, interval or 2000, vim.schedule_wrap(M.refresh))
end

function M.stop()
	if timer then
		timer:stop()
		timer:close()
		timer = nil
	end
end

---@param key string
---@return table|nil
function M.get(key)
	return agents[key]
end

---Find the live backend + target behind a record (it may have exited since the last refresh).
---@param rec table
---@return table|nil mod, table|nil target
function M.resolve(rec)
	local mod = rec and backends.get(rec.backend)
	if not mod then
		return nil
	end
	local ok, targets = pcall(mod.targets)
	for _, t in ipairs(ok and targets or {}) do
		if tostring(t.id) == rec.id then
			return mod, t
		end
	end
	return nil
end

---Every observed instance, most attention-worthy first.
---@param opts { state?: string, backend?: string, correlation?: table }|nil
---@return table[]
function M.all(opts)
	opts = opts or {}
	local list = {}
	for _, key in ipairs(order) do
		local rec = agents[key]
		local keep = true
		if opts.state and rec.state ~= opts.state then
			keep = false
		elseif opts.backend and rec.backend ~= opts.backend then
			keep = false
		elseif opts.correlation then
			local d = rec.dispatch and rec.dispatch.correlation
			keep = type(d) == "table"
				and d.plugin == opts.correlation.plugin
				and tostring(d.key) == tostring(opts.correlation.key)
		end
		if keep then
			list[#list + 1] = rec
		end
	end
	table.sort(list, function(a, b)
		local pa, pb = M.priority(a), M.priority(b)
		if pa ~= pb then
			return pa < pb
		end
		return (a.since or 0) < (b.since or 0)
	end)
	return list
end

---Counts by state, `blocked` split by kind.
---@return { blocked: integer, done: integer, working: integer, error: integer, total: integer }
function M.counts()
	local out = { blocked = 0, done = 0, working = 0, error = 0, total = 0 }
	for _, rec in ipairs(M.all()) do
		if not rec.gone then
			out.total = out.total + 1
			if rec.state == "done" and not rec.unread then
				-- acknowledged: not worth a counter
			elseif out[rec.state] ~= nil then
				out[rec.state] = out[rec.state] + 1
			end
		end
	end
	return out
end

---One statusline chunk, empty when there is nothing to report.
---@return string
function M.statusline()
	local c = M.counts()
	local parts = {}
	if c.blocked > 0 then
		parts[#parts + 1] = "⚠" .. c.blocked
	end
	if c.done > 0 then
		parts[#parts + 1] = "✓" .. c.done
	end
	if c.error > 0 then
		parts[#parts + 1] = "✗" .. c.error
	end
	if c.working > 0 then
		parts[#parts + 1] = "◐" .. c.working
	end
	return table.concat(parts, " ")
end

---Record that we just sent something, so a following `idle` can be attributed.
---Creates the record for instances the timer has not seen yet.
---@param backend string
---@param id string
---@param text string
---@param correlation table|nil opaque, handed back with every event of that record
function M.dispatch(backend, id, text, correlation)
	local key = key_of(backend, id)
	local rec = agents[key]
	if not rec then
		local mod = backends.get(backend)
		if not mod then
			return
		end
		for _, t in ipairs(mod.targets()) do
			if tostring(t.id) == tostring(id) then
				rec = ensure(mod, t)
				break
			end
		end
		if not rec then
			return
		end
	end
	rec.dispatch = { text = text, ts = vim.uv.now(), correlation = correlation }
	rec.unread = false
	emit("update", rec)
end

---Mark a finished instance as seen (keeps the row, drops the unread mark).
---@param key string
function M.ack(key)
	local rec = agents[key]
	if not rec then
		return
	end
	rec.unread = false
	rec.notified = nil
	emit("update", rec)
end

---Forget an instance entirely (a later refresh re-adds it if it is still running).
---@param key string
function M.dismiss(key)
	local rec = agents[key]
	if not rec then
		return
	end
	agents[key] = nil
	for i, k in ipairs(order) do
		if k == key then
			table.remove(order, i)
			break
		end
	end
	emit("update", rec)
end

return M
