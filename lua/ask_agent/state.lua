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
--   state.dispatch(backend, id, text, { correlation, anchor })
--   state.reply(key, text)   -- answer something blocked, through the same sender
--   state.result(key, cb)    -- the last turn's output (captured on demand)
--
-- Each record carries `source`: "rex" (OSC 7501, authoritative), "probe" (the
-- backend's own marker/probe) or "heuristic" (a turn that ended after our send).
-- Tasks and unread marks survive a restart through a small journal file.
--
-- States: idle | working | blocked | done | error | unknown | gone.
-- `blocked` carries `kind` (permission | question | auth) and, like `done`,
-- stays until acknowledged.

local backends = require("ask_agent.backends")
local aliases = require("ask_agent.aliases")
local rex = require("ask_agent.status.rex")
local jump = require("ask_agent.jump")

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
local TASK_KEEP = 20
local JOURNAL_KEEP = 50
local JOURNAL_DEBOUNCE = 1000
local JOURNAL_TTL = 7 * 24 * 3600 * 1000

---Send a message to one resolved instance (set by init, which owns the picker-free sender).
---@type fun(mod: table, target: table, text: string, opts: table|nil): boolean, string?
M.sender = nil

---Persist tasks/unread marks across restarts (`setup({ persist = ... })`).
M.persist = true
---Journal override (path string), mainly for tests.
M.journal_path = nil

local journal_timer

---What a task looks like: { text, ts, status = "running" | "done" | "error", correlation, anchor }.
---Every send that reaches an instance appends one (newest first), so the dashboard can
---show "what did I hand this agent, and how did it end". The queue lives in queue.lua.

---@param backend string
---@param id string
---@return string
local function key_of(backend, id)
	return backend .. ":" .. tostring(id)
end

---Wall-clock milliseconds. rec timestamps must survive a restart (the journal), so
---they cannot be monotonic ticks; every age/`since` in this module uses this clock.
---@return integer
function M.now()
	local sec, usec = vim.uv.gettimeofday()
	return sec * 1000 + math.floor(usec / 1000)
end

local function now_ms()
	return M.now()
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
	local now = now_ms()
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

local schedule_save -- journal writer, defined below (apply() is above it)

---Apply a new observation to a record, emitting only what actually changed.
---@param rec table
---@param st { state: string, kind?: string, progress?: integer, msg?: string, gone?: boolean }
---@param src string|nil where this observation came from: "rex" | "probe" | "heuristic"
local function apply(rec, st, src)
	local prev = rec.state
	local state, kind = st.state, st.kind
	-- Completion inference for sources that cannot say "done" (tmux hooks, pi busy flags):
	-- a turn that ends after one of our sends means our message was answered.
	if state == "idle" and prev == "working" and rec.dispatch and (rec.dispatch.ts or 0) > (rec.idle_at or 0) then
		state, kind, src = "done", nil, "heuristic"
		rec.unread = true
	end
	-- a finished turn stays `done` until acknowledged, even though the source now says idle
	if state == "idle" and prev == "done" and rec.unread then
		state = "done"
	end
	rec.source = src or rec.source or "probe"
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
	if state == "done" or state == "error" then
		for _, task in ipairs(rec.tasks or {}) do
			if task.status == "running" then
				task.status = state == "done" and "done" or "error"
			end
		end
	end
	if changed and state ~= prev then
		rec.since = now_ms()
		if state == "idle" then
			rec.idle_at = rec.since
		end
		-- done always starts unread, whatever told us; ack is what clears it
		rec.unread = state == "done"
	end
	emit("update", rec)
	schedule_save()
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

----------------------------------------------------------------------
-- Journal: tasks and unread marks outlive the nvim process
----------------------------------------------------------------------

local restored, restored_loaded

---@return string
local function journal_file()
	return M.journal_path or (vim.fn.stdpath("cache") .. "/ask-agent/journal.json")
end

---@param task table
---@return table
local function slim_task(task)
	return {
		text = task.text,
		ts = task.ts,
		status = task.status,
		reply = task.reply,
		correlation = task.correlation,
		anchor = task.anchor,
	}
end

local function save_journal()
	if journal_timer then
		journal_timer:stop()
		journal_timer:close()
		journal_timer = nil
	end
	if not M.persist then
		return
	end
	local out = { version = 1, agents = {} }
	for _, key in ipairs(order) do
		local rec = agents[key]
		if rec.tasks and #rec.tasks > 0 then
			local tasks = {}
			for i = 1, math.min(#rec.tasks, JOURNAL_KEEP) do
				tasks[i] = slim_task(rec.tasks[i])
			end
			out.agents[key] = { backend = rec.backend, id = rec.id, unread = rec.unread, tasks = tasks }
		end
	end
	local ok, encoded = pcall(vim.json.encode, out)
	if not ok then
		return
	end
	local file = journal_file()
	pcall(vim.fn.mkdir, vim.fn.fnamemodify(file, ":h"), "p")
	pcall(vim.fn.writefile, { encoded }, file)
end

---Write the journal once things settle; every dispatch/state change goes through here.
function schedule_save()
	if not M.persist then
		return
	end
	if journal_timer then
		return
	end
	journal_timer = vim.uv.new_timer()
	journal_timer:start(JOURNAL_DEBOUNCE, 0, vim.schedule_wrap(save_journal))
end

---@return table<string, table>
local function load_journal()
	if not M.persist then
		return {}
	end
	local ok, lines = pcall(vim.fn.readfile, journal_file())
	if not ok or type(lines) ~= "table" or #lines == 0 then
		return {}
	end
	local decoded, data = pcall(vim.json.decode, table.concat(lines, "\n"))
	if not decoded or type(data) ~= "table" or type(data.agents) ~= "table" then
		return {}
	end
	-- tasks older than a week are noise: an instance that comes back with the same
	-- key (a reused pid) must not inherit someone else's history
	local cutoff = M.now() - JOURNAL_TTL
	for _, entry in pairs(data.agents) do
		local tasks = {}
		for _, task in ipairs(entry.tasks or {}) do
			if type(task.ts) == "number" and task.ts > cutoff then
				tasks[#tasks + 1] = task
			end
		end
		entry.tasks = tasks
	end
	return data.agents
end

---Write the journal now (also called from VimLeavePre); tests use it to read it back.
function M.flush()
	save_journal()
end

---Re-read the journal, so an entry that was dismissed can be restored (tests, rare manual use).
function M.reload_journal()
	restored, restored_loaded = load_journal(), true
end

---@param mod table
---@param t table
---@return table record
local function ensure(mod, t)
	local key = key_of(mod.id, t.id)
	local rec = agents[key]
	if not rec then
		rec = { key = key, backend = mod.id, id = tostring(t.id), state = "unknown", since = now_ms() }
		if not restored_loaded then
			restored, restored_loaded = load_journal(), true
		end
		local old = restored[key]
		if old then
			rec.tasks = old.tasks
			rec.unread = old.unread
			restored[key] = nil
		end
		agents[key] = rec
		table.insert(order, key)
	end
	rec.target = t
	return rec
end

----------------------------------------------------------------------
-- rex event stream: react in milliseconds, poll only as a fallback
----------------------------------------------------------------------

local watches = {}
local refresh_pending = false

local function schedule_refresh()
	if refresh_pending then
		return
	end
	refresh_pending = true
	vim.defer_fn(function()
		refresh_pending = false
		M.refresh()
	end, 80)
end

---@param sessions table<string, boolean>
local function watch_sessions(sessions)
	for session in pairs(sessions) do
		if not watches[session] and rex.watch then
			local ok = rex.watch(session, function(ev)
				-- the event itself does not name the block, so drop the whole cache:
				-- the next refresh re-reads only the blocks that have agents in them
				if ev.type == "terminal.program_status_changed" or ev.type == "terminal.program_status_removed" then
					if rex.invalidate then
						rex.invalidate()
					end
					schedule_refresh()
				end
			end)
			watches[session] = ok or nil
		end
	end
	for session in pairs(watches) do
		if not sessions[session] then
			if rex.unwatch then
				rex.unwatch(session)
			end
			watches[session] = nil
		end
	end
end

---One polling pass over every registered backend. Cheap for a 2s timer: targets()
---only reads files / lists panes, and the expensive per-block source (rex) is
---queried asynchronously.
function M.refresh()
	if refreshing then
		return
	end
	refreshing = true
	local seen, sessions = {}, {}
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
				}, "probe")
				-- rex reports the real state for agents that speak OSC 7501; apply it when it arrives
				if t.rex and not rec.rex_pending then
					rec.rex_pending = true
					if t.rex.session then
						sessions[t.rex.session] = true
					end
					rex.query(t.rex, function(value)
						rec.rex_pending = nil
						if value and agents[rec.key] == rec then
							apply(
								rec,
								{ state = value.state, kind = value.kind, progress = value.progress, msg = value.msg },
								"rex"
							)
						end
					end)
				end
			end
		end
	end
	local now = now_ms()
	for _, key in ipairs(order) do
		local rec = agents[key]
		if not seen[key] and not rec.gone then
			apply(rec, { state = rec.state, kind = rec.kind, msg = rec.msg, gone = true })
		elseif rec.gone and (rec.state == "idle" or rec.state == "unknown") and now - (rec.since or 0) > PRUNE_MS then
			M.dismiss(key)
		end
	end
	refreshing = false
	watch_sessions(sessions)
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
	for session in pairs(watches) do
		if rex.unwatch then
			rex.unwatch(session)
		end
		watches[session] = nil
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
			-- an acknowledged done is history, not something that needs you
			local settled = rec.state == "done" and not rec.unread
			if not settled and out[rec.state] ~= nil then
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
---Creates the record for instances the timer has not seen yet. The send also
---becomes the newest entry of `rec.tasks` (shown by the dashboard).
---@param backend string
---@param id string
---@param text string
---@param opts { correlation?: table, anchor?: table, reply?: boolean }|nil
function M.dispatch(backend, id, text, opts)
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
	local ts = now_ms()
	rec.dispatch = { ts = ts, correlation = opts and opts.correlation }
	rec.tasks = rec.tasks or {}
	table.insert(rec.tasks, 1, {
		text = (text:gsub("\n.*", "")),
		ts = ts,
		status = "running",
		reply = opts and opts.reply,
		correlation = opts and opts.correlation,
		anchor = opts and opts.anchor,
	})
	if #rec.tasks > TASK_KEEP then
		rec.tasks[TASK_KEEP + 1] = nil
	end
	rec.unread = false
	emit("update", rec)
	schedule_save()
end

---Newest task handed to an instance: { text, ts, status, reply?, correlation, anchor, output? }.
---@param key string
---@return table|nil
function M.task(key)
	local rec = agents[key]
	return rec and rec.tasks and rec.tasks[1] or nil
end

---Answer what an agent is blocked on, on the same instance (no picker, no queue).
---@param key string
---@param text string
---@return boolean ok, string|nil err
function M.reply(key, text)
	local rec = agents[key]
	if not rec then
		return false, ("unknown agent %s"):format(tostring(key))
	end
	local mod, target = M.resolve(rec)
	if not mod or not target then
		return false, ("%s is not running"):format(M.name(rec))
	end
	if not M.sender then
		return false, "no sender configured"
	end
	return M.sender(mod, target, text, { reply = true })
end

---Output of the newest turn, captured from the terminal on demand and cached on the task.
---`cb(task|nil, err?)`; the task then carries `output`.
---@param key string
---@param cb fun(task: table|nil, err: string|nil)
function M.result(key, cb)
	local rec = agents[key]
	if not rec then
		return vim.schedule(function()
			cb(nil, ("unknown agent %s"):format(tostring(key)))
		end)
	end
	local task = rec.tasks and rec.tasks[1]
	if not task then
		return vim.schedule(function()
			cb(nil, "nothing has been sent to this agent yet")
		end)
	end
	if task.output then
		return vim.schedule(function()
			cb(task)
		end)
	end
	local _, target = M.resolve(rec)
	if not target then
		return vim.schedule(function()
			cb(nil, ("%s is not running"):format(M.name(rec)))
		end)
	end
	jump.capture(target, function(text)
		if not text or text == "" then
			return cb(nil, "this agent has no capture adapter")
		end
		task.output = text
		schedule_save()
		cb(task)
	end)
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
	schedule_save()
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
	schedule_save()
end

return M
