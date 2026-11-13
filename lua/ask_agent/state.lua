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
--
-- Each record carries `source`: "rex" (OSC 7501, authoritative), "probe" (the
-- backend's own marker/probe) or "heuristic" (a turn that ended after our send).
-- Tasks and unread marks survive a restart through a small journal file.
--
-- States: idle | working | blocked | done | error | unknown | gone.
-- `blocked` carries `kind` (permission | question | auth) and, like `done`,
-- stays until acknowledged.

local backends = require("ask_agent.backends")
local notify = require("ask_agent.notify")
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
local PRUNE_MS = 600000
local TASK_KEEP = 20
---Finished tasks older than this are dropped from the journal; one per agent stays
---so a restart can still show what the instance did last.
M.task_ttl = 24 * 3600 * 1000
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

---What a task looks like: { text, ts, status = "running" | "done" | "error", finish, correlation, anchor }.
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

---The name an instance would wear on its own: an alias if it has one, else the
---directory it lives in.
---@param rec table
---@return string
local function raw_name(rec)
	return aliases.get(rec.target, rec.backend) or aliases.default_name(rec.target or { id = rec.id })
end

-- Display names for the whole list, rebuilt whenever the set of instances or one
-- of their aliases changes: names must be unique across the panel, not just
-- inside one directory slot (see M.name).
local name_cache

---@param rec table
---@return string
function M.name(rec)
	if not name_cache then
		local cache = {}
		local counts, seen = {}, {}
		for _, key in ipairs(order) do
			local other = agents[key]
			if other then
				cache[key] = raw_name(other)
				counts[cache[key]] = (counts[cache[key]] or 0) + 1
			end
		end
		-- Two agents fall back to the same directory name (`pi` twice in one
		-- project), or an alias happens to equal somebody else's default; the
		-- list has to tell them apart, so a shared name gets the same `·2`
		-- suffix the alias slots use. Numbering follows the list order, which is
		-- stable while the same agents stay alive.
		for _, key in ipairs(order) do
			local base = cache[key]
			if base and counts[base] > 1 then
				seen[base] = (seen[base] or 0) + 1
				cache[key] = ("%s ·%d"):format(base, seen[base])
			end
		end
		name_cache = cache
	end
	return name_cache[rec.key] or raw_name(rec)
end

---Rename an instance; it also claims a directory slot so the name survives a restart.
---@param rec table
---@param name string|nil empty clears
---@return boolean ok
function M.rename(rec, name)
	if not rec or not rec.target then
		return false
	end
	local ok = aliases.set(rec.target, rec.backend, name or "")
	name_cache = nil
	return ok
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

---One message per state, overridable through `setup({ notify = { … } })`.
--
-- `{backend}`, `{name}`, `{msg}`, `{state}`, `{kind}` and `{was}` are filled in;
-- `{msg}` already carries its ": " separator, so `"…finished{msg}"` reads right.
-- `sound = true` rings the terminal bell (unless `belloff` contains "all"), and
-- `level` is a key of `vim.log.levels` as a name. A state set to `false` is silent.
M.messages = {
	done = { text = "[{backend}] {name} finished{msg}", level = "INFO", sound = true },
	blocked = { text = "[{backend}] {name} is waiting for you{msg}", level = "WARN", sound = true },
	permission = { text = "[{backend}] {name} needs your permission{msg}", level = "WARN", sound = true },
	auth = { text = "[{backend}] {name} is waiting for credentials{msg}", level = "WARN", sound = true },
	question = { text = "[{backend}] {name} is waiting for your answer{msg}", level = "WARN", sound = true },
	error = { text = "[{backend}] {name} failed{msg}", level = "ERROR", sound = true },
	gone = { text = "[{backend}] {name} exited while {was}", level = "WARN", sound = true },
}

---What a vanished agent was doing, as it reads in the `{was}` placeholder.
---Configurable so the copy can be translated: `notify = { was = { blocked = "在等你" } }`.
M.was = { blocked = "waiting for you", working = "working" }

---Minimum milliseconds between two notifications of the same kind for one agent
---(`done`/`error`/`gone` bursts are throttled, a blocked transition is not).
M.notify_gap = 30000

local LEVELS = {
	TRACE = vim.log.levels.TRACE,
	DEBUG = vim.log.levels.DEBUG,
	INFO = vim.log.levels.INFO,
	WARN = vim.log.levels.WARN,
	ERROR = vim.log.levels.ERROR,
}

---Fill `{name}` placeholders; unknown keys expand to nothing.
---@param tpl string
---@param ctx table<string, string>
---@return string
local function fill(tpl, ctx)
	return (
		tpl:gsub("{(%w+)}", function(key)
			local value = ctx[key]
			return value ~= nil and tostring(value) or ""
		end)
	)
end

---Render the message configured for `key`.
---@param rec table
---@param key string
---@param ctx table<string, string>
---@return string|nil text, integer|nil level, boolean sound
local function message(rec, key, ctx)
	local cfg = M.messages[key]
	if cfg == nil then
		cfg = M.messages.blocked
	end
	if cfg == false or type(cfg) ~= "table" or type(cfg.text) ~= "string" then
		return nil
	end
	ctx.backend, ctx.name = rec.backend, M.name(rec)
	ctx.msg = rec.msg and (": " .. rec.msg) or ""
	local level = LEVELS[cfg.level or "INFO"] or vim.log.levels.INFO
	return fill(cfg.text, ctx), level, cfg.sound ~= false
end

---Say it once: render the configured text, at the configured level, with the bell
---when the state asks for one.
---@param rec table
---@param key string
---@param ctx table<string, string>
local function announce(rec, key, ctx)
	local text, level, sound = message(rec, key, ctx)
	if text then
		notify.notify(text, level, { sound = sound })
	end
end

---Override the notification copy (merged into `M.messages`).
--
--   state.configure({ messages = {
--     done = "✅ {name} 完成{msg}",
--     error = false,                            -- never notify about errors
--     blocked = { text = "⏸ {name} 等你{msg}", sound = false },
--   }, gap = 10000 })
---@param o { messages?: table, gap?: integer }|nil
---@return table messages
function M.configure(o)
	o = o or {}
	local messages = vim.deepcopy(o.messages or {})
	if type(messages.was) == "table" then
		M.was = vim.tbl_extend("force", M.was, messages.was)
		messages.was = nil
	end
	for key, cfg in pairs(messages) do
		if cfg == false then
			M.messages[key] = false
		elseif type(cfg) == "string" then
			M.messages[key] = vim.tbl_extend("force", M.messages[key] or {}, { text = cfg })
		elseif type(cfg) == "table" then
			M.messages[key] = vim.tbl_extend("force", M.messages[key] or {}, cfg)
		end
	end
	if type(o.gap) == "number" and o.gap >= 0 then
		M.notify_gap = o.gap
	end
	return M.messages
end

---One throttle per instance and notification kind: short task bursts must not spam,
---but a blocked transition is always new and is never dropped.
---@param rec table
---@param kind string
---@return boolean suppressed
local function throttled(rec, kind)
	local now = now_ms()
	if type(rec.notified) ~= "table" then
		rec.notified = {}
	end
	if now - (rec.notified[kind] or 0) < M.notify_gap then
		return true
	end
	rec.notified[kind] = now
	return false
end

---Is the agent's own terminal the one the user is looking at? Only local Neovim
---terminals can be checked; an external multiplexer pane is outside this process.
---@param rec table
---@return boolean
local function watching(rec)
	local _, target = M.resolve(rec)
	local pid = tonumber(target and target.id)
	if not pid then
		return false
	end
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		local buf = vim.api.nvim_win_get_buf(win)
		if vim.bo[buf].buftype == "terminal" then
			local ok, job = pcall(vim.api.nvim_buf_get_var, buf, "terminal_job_pid")
			if ok and tonumber(job) == pid then
				return true
			end
		end
	end
	return false
end

---@param rec table
local function notify_change(rec)
	if not M.notify then
		return
	end
	if rec.state == "blocked" then
		local key = (rec.kind and M.messages[rec.kind] ~= nil) and rec.kind or "blocked"
		announce(rec, key, { kind = rec.kind or "", state = rec.state })
	elseif rec.state == "done" then
		if watching(rec) or throttled(rec, "done") then
			return
		end
		announce(rec, "done", { state = rec.state })
	elseif rec.state == "error" then
		if throttled(rec, "error") then
			return
		end
		announce(rec, "error", { state = rec.state })
	end
end

---An agent disappearing is only news while it still owed the user something.
---@param rec table
---@param prev string
local function notify_gone(rec, prev)
	if not M.notify or (prev ~= "working" and prev ~= "blocked") then
		return
	end
	if throttled(rec, "gone") then
		return
	end
	announce(rec, "gone", {
		state = rec.state,
		was = M.was[prev] or M.was.working,
	})
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
	if rec.gone then
		notify_gone(rec, prev)
	end
	if state == "done" or state == "error" then
		for _, task in ipairs(rec.tasks or {}) do
			if task.status == "running" then
				task.status = state == "done" and "done" or "error"
				task.finish = now_ms()
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
		finish = task.finish,
		correlation = task.correlation,
		anchor = task.anchor,
		-- the id the agent got, so an answer can be attached after a restart, and the
		-- turn this send opened, so `v` can diff exactly this exchange
		task_id = task.task_id,
		turn_id = task.turn_id,
		has_answer = task.has_answer,
	}
end

---A finished task nobody will look at again (the newest one per agent is exempt).
---@param task table
---@param cutoff integer
---@return boolean
local function stale_task(task, cutoff)
	local finished = task.status == "done" or task.status == "error"
	local at = task.finish or task.ts
	return finished and type(at) == "number" and at < cutoff
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
	local cutoff = M.now() - M.task_ttl
	for _, key in ipairs(order) do
		local rec = agents[key]
		if rec.tasks and #rec.tasks > 0 then
			local tasks = {}
			for i = 1, math.min(#rec.tasks, JOURNAL_KEEP) do
				if i == 1 or not stale_task(rec.tasks[i], cutoff) then
					tasks[#tasks + 1] = slim_task(rec.tasks[i])
				end
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
	local task_cutoff = M.now() - M.task_ttl
	for _, entry in pairs(data.agents) do
		local tasks = {}
		for i, task in ipairs(entry.tasks or {}) do
			if type(task.ts) == "number" and task.ts > cutoff and (i == 1 or not stale_task(task, task_cutoff)) then
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
		name_cache = nil
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
	-- a poll can learn about a rename or a new/vanished instance from another nvim
	name_cache = nil
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
---
---`gone` is excluded (an exited agent is history, not a thing to act on), `done`
---only counts while it is unread (acknowledging it is what makes the count go away),
---and `live` is what the statusline calls "agents running right now".
---@return { blocked: integer, permission: integer, question: integer, auth: integer,
---  done: integer, error: integer, working: integer, idle: integer, unknown: integer,
---  gone: integer, live: integer, total: integer }
function M.counts()
	local out = {
		blocked = 0,
		permission = 0,
		question = 0,
		auth = 0,
		done = 0,
		working = 0,
		error = 0,
		idle = 0,
		unknown = 0,
		gone = 0,
		live = 0,
		total = 0,
	}
	for _, rec in ipairs(M.all()) do
		out.total = out.total + 1
		if rec.gone then
			out.gone = out.gone + 1
		else
			out.live = out.live + 1
			-- an acknowledged done is history, not something that needs you
			local settled = rec.state == "done" and not rec.unread
			if not settled and out[rec.state] ~= nil then
				out[rec.state] = out[rec.state] + 1
			end
			if rec.state == "blocked" then
				-- already counted by the generic branch above; only the kind split is new
				local kind = rec.kind
				if kind == "permission" or kind == "question" or kind == "auth" then
					out[kind] = out[kind] + 1
				end
			end
		end
	end
	return out
end

---Animation for the statusline spinner: only runs while something is working, and its
---only job is to make the statusline redraw (the frame itself is derived from the clock,
---so any redraw — cursor movement, a message — shows the right one).
local anim = { timer = nil, tick = 120 }

---@param want boolean
local function animate(want)
	if not want then
		if anim.timer then
			anim.timer:stop()
		end
		return
	end
	if anim.timer then
		if not anim.timer:is_active() then
			anim.timer:start(anim.tick, anim.tick, anim.timer._cb)
		end
		return
	end
	local timer = vim.uv.new_timer()
	if not timer then
		return
	end
	anim.cb = anim.cb
		or vim.schedule_wrap(function()
			if M.counts().working == 0 then
				if anim.timer then
					anim.timer:stop()
				end
			end
			-- Two kinds of consumers: an expression statusline (`%{%...%}`) is re-evaluated
			-- by redrawstatus alone, while a statusline composed once into a string needs
			-- an event to be rebuilt -- hence both. redrawstatus raises in some modes
			-- (cmdline), and a missing autocmd is not an error either.
			pcall(vim.cmd, "redrawstatus")
			pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "AskAgentStatuslineTick" })
		end)
	timer:start(anim.tick, anim.tick, anim.cb)
	anim.timer = timer
end

---@return integer current spinner frame
local function frame()
	return math.floor(vim.uv.now() / anim.tick)
end

---One statusline chunk: what the agents are doing, most urgent first.
---
---    ⠹2 ⚠1 ?1 ✓3 ✗1
---    │  │  │  │  └ errors
---    │  │  │  └ finished turns you have not looked at yet
---    │  │  └ waiting for an answer to a question
---    │  └ waiting for your confirmation / credentials
---    └ working (animated; plain ◐ when animated = false)
---
---`idle` only shows when there is nothing else: a quiet `●3` says "three agents are
---up and doing nothing", which is exactly what you want to know when the rest is empty.
---Empty string = no agents at all.
---@param opts? { animated?: boolean, idle?: boolean|string, blocked?: boolean }
---@return string
function M.statusline(opts)
	opts = opts or {}
	local c = M.counts()
	local icons = require("ask_agent.icons")
	local mark = function(state)
		return icons.ui("state", state) or ""
	end
	local parts = {}
	local add = function(text)
		parts[#parts + 1] = text
	end

	if c.working > 0 then
		local spin = (opts.animated == false) and mark("working") or icons.spin(frame())
		add(spin .. c.working)
	end
	-- permission/auth ("waiting for you") and question are different things to do:
	-- one needs a yes/no, the other needs an answer
	-- `blocked - question` rather than permission + auth: a source that says "blocked"
	-- without a kind still wants you, and it needs a confirmation, not an answer
	local confirm = c.blocked - c.question
	if confirm > 0 then
		add(mark("blocked") .. confirm)
	end
	if c.question > 0 then
		add("?" .. c.question)
	end
	if c.done > 0 then
		add(mark("done") .. c.done)
	end
	if c.error > 0 then
		add(mark("error") .. c.error)
	end
	-- idle is the fallback: only interesting when nothing above is happening
	local want_idle = opts.idle
	if want_idle == nil then
		want_idle = #parts == 0
	elseif want_idle == "auto" then
		want_idle = #parts == 0
	end
	if want_idle and c.idle > 0 then
		add(mark("idle") .. c.idle)
	end
	if opts.animated ~= false then
		animate(c.working > 0)
	end
	return table.concat(parts, " ")
end

---Record that we just sent something, so a following `idle` can be attributed.
---Creates the record for instances the timer has not seen yet. The send also
---becomes the newest entry of `rec.tasks` (shown by the dashboard).
---@param backend string
---@param id string
---@param text string
---@param opts { correlation?: table, anchor?: table, task_id?: string, turn_id?: string|number }|nil
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
	rec.dispatch = { ts = ts, correlation = opts and opts.correlation, task_id = opts and opts.task_id }
	rec.tasks = rec.tasks or {}
	table.insert(rec.tasks, 1, {
		text = (text:gsub("\n.*", "")),
		ts = ts,
		status = "running",
		correlation = opts and opts.correlation,
		anchor = opts and opts.anchor,
		task_id = opts and opts.task_id,
		turn_id = opts and opts.turn_id,
	})
	if #rec.tasks > TASK_KEEP then
		rec.tasks[TASK_KEEP + 1] = nil
	end
	rec.unread = false
	emit("update", rec)
	schedule_save()
end

---The task carrying that task id, across every agent (an answer comes back with
---nothing but the id the agent was given).
---@param task_id string|nil
---@return table|nil task, table|nil rec
function M.task_by_id(task_id)
	if type(task_id) ~= "string" or task_id == "" then
		return nil
	end
	for _, rec in pairs(agents) do
		for _, task in ipairs(rec.tasks or {}) do
			if task.task_id == task_id then
				return task, rec
			end
		end
	end
	return nil
end

---Mark a task as answered (the text itself lives in history). A no-op when the
---task is gone: the agent may answer after the journal was pruned.
---@param task_id string|nil
---@param ts integer|nil
---@return table|nil task
function M.attach_result(task_id, ts)
	local task = M.task_by_id(task_id)
	if not task then
		return nil
	end
	task.has_answer = true
	task.answer_ts = ts or now_ms()
	schedule_save()
	return task
end

---Newest task handed to an instance: { text, ts, status, correlation, anchor }.
---@param key string
---@return table|nil
function M.task(key)
	local rec = agents[key]
	return rec and rec.tasks and rec.tasks[1] or nil
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
	name_cache = nil
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
