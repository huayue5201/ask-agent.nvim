-- lua/ask_agent/chat.lua
---@brief A group chat over one transcript: several agents, one log, `@`-routed tasks.
--
-- The log is the truth and every view is a projection of it (same rule as
-- state.lua): entries are append-only, and an agent never reads another agent's
-- transcript — it reads the projection this module builds for it (pinned facts
-- plus the last few entries whose cursor it has not reached). `@name` is routing,
-- not decoration: a mention names a target, and that target gets a task whose
-- prompt carries the projection.
--
-- Three rules keep this from becoming a token fire hose:
--   * cursor  every target remembers "the last entry I have seen", so only what
--             came after it is injected (at most M.window entries)
--   * pin     facts a human pinned explicitly are always injected; they replace
--             "send the whole history"
--   * gate    one target runs one chat task at a time; later mentions are queued
--
-- Agents cannot mention each other (only messages a human posts are routed):
-- collaboration is supposed to happen through the shared transcript and the
-- artifacts in it, not through agents chatting in a loop.
--
--   chat.on("entry"|"thread", fn)      -- a new entry / thread list changed
--   chat.thread(name)                  -- find or create, and select
--   chat.post(text, opts)              -- the human speaks; returns the entry
--   chat.reply(thread, key, text, o)   -- an agent's result lands here
--   chat.context(thread, key)          -- the projection an agent would receive
--   chat.pin(thread, text)             -- a fact that always travels
--   chat.running() / chat.pending()    -- who is busy, who is waiting

local backends = require("ask_agent.backends")
local aliases = require("ask_agent.aliases")
local state = require("ask_agent.state")

local M = {}

---How many entries an agent sees at most (newest first).
M.window = 24
---A thread keeps at most this many entries; older ones are dropped from the journal.
M.max_entries = 600
---Persist the log across nvim restarts (tests turn this off).
M.persist = true
---Where the log lives when persist is on.
M.journal_path = nil
---Route `@name` to a target's send(). Tests replace it.
M.send = nil
---Read an agent's answer back out of its terminal. Tests replace it.
M.capture = nil

local threads = {}
local thread_order = {}
local current_id = nil
local next_id = 1

---@type table<string, { thread: string, entry: integer, target: table, backend: table }>
local running = {}
---@type table<string, { thread: string, text: string, entry: integer, target: table, backend: table }[]>
local pending = {}
---@type table<string, table> target cache: a reply needs the target after a restart
local target_cache = {}

local listeners = {}
local save_timer

local function now()
	return state.now()
end

---@param event string
---@param fn function
---@return fun() unsubscribe
function M.on(event, fn)
	local list = listeners[event] or {}
	listeners[event] = list
	list[#list + 1] = fn
	return function()
		for i, f in ipairs(list) do
			if f == fn then
				table.remove(list, i)
				return
			end
		end
	end
end

local function emit(event, ...)
	for _, fn in ipairs(listeners[event] or {}) do
		pcall(fn, ...)
	end
end

----------------------------------------------------------------------
-- Journal
----------------------------------------------------------------------

local function journal_file()
	return M.journal_path or (vim.fn.stdpath("cache") .. "/ask-agent/chat.json")
end

local function slim(thread)
	local entries = {}
	local from = math.max(1, #thread.entries - M.max_entries + 1)
	for i = from, #thread.entries do
		local e = thread.entries[i]
		entries[#entries + 1] = {
			id = e.id,
			ts = e.ts,
			kind = e.kind,
			author = e.author,
			target = e.target,
			name = e.name,
			text = e.text,
			status = e.status,
			task = e.task,
		}
	end
	return { name = thread.name, ts = thread.ts, pins = thread.pins, cursors = thread.cursors, entries = entries }
end

local function save()
	if save_timer then
		save_timer:stop()
		save_timer:close()
		save_timer = nil
	end
	if not M.persist then
		return
	end
	local out = { version = 1, next_id = next_id, current = current_id, threads = {} }
	for _, id in ipairs(thread_order) do
		out.threads[id] = slim(threads[id])
	end
	local ok, encoded = pcall(vim.json.encode, out)
	if not ok then
		return
	end
	local file = journal_file()
	pcall(vim.fn.mkdir, vim.fn.fnamemodify(file, ":h"), "p")
	pcall(vim.fn.writefile, { encoded }, file)
end

local function changed()
	save_timer = save_timer or vim.uv.new_timer()
	save_timer:stop()
	save_timer:start(300, 0, vim.schedule_wrap(save))
end

---Write the log now (VimLeavePre calls this); tests read it back.
function M.flush()
	save()
end

local loaded = false

local function load()
	if loaded then
		return
	end
	loaded = true
	if not M.persist then
		return
	end
	local ok, lines = pcall(vim.fn.readfile, journal_file())
	if not ok or type(lines) ~= "table" or #lines == 0 then
		return
	end
	local decoded, data = pcall(vim.json.decode, table.concat(lines, "\n"))
	if not decoded or type(data) ~= "table" or type(data.threads) ~= "table" then
		return
	end
	next_id = tonumber(data.next_id) or 1
	current_id = data.current
	for id, t in pairs(data.threads) do
		threads[id] = {
			id = id,
			name = t.name or id,
			ts = t.ts or now(),
			pins = t.pins or {},
			cursors = t.cursors or {},
			entries = t.entries or {},
		}
		thread_order[#thread_order + 1] = id
	end
	table.sort(thread_order)
end

----------------------------------------------------------------------
-- Threads
----------------------------------------------------------------------

---@param id string
---@return table|nil
function M.get(id)
	load()
	local t = threads[id or current_id or ""]
	if t or not id then
		return t
	end
	-- ids and names are both accepted everywhere an id is (":AskAgentChat main")
	for _, tid in ipairs(thread_order) do
		if threads[tid].name:lower() == tostring(id):lower() then
			return threads[tid]
		end
	end
	return nil
end

---Find a thread by name (case-insensitive) or create it, and select it.
---@param name string|nil
---@return string id
function M.thread(name)
	load()
	name = vim.trim(name or "")
	-- an id is accepted wherever a name is (`thread = chat.thread("main")`), which
	-- is what the window passes: creating a *second* thread named "t1" would
	-- silently send every message into a thread nobody is looking at
	if threads[name] then
		current_id = name
		return name
	end
	if name == "" then
		name = current_id and threads[current_id] and threads[current_id].name or "main"
	end
	for _, id in ipairs(thread_order) do
		if threads[id].name:lower() == name:lower() then
			current_id = id
			return id
		end
	end
	local id = ("t%d"):format(#thread_order + 1)
	while threads[id] do
		id = id .. "x"
	end
	threads[id] = { id = id, name = name, ts = now(), pins = {}, cursors = {}, entries = {} }
	thread_order[#thread_order + 1] = id
	current_id = id
	changed()
	emit("thread", threads[id])
	return id
end

---The selected thread's id (nil when nothing was created yet).
---@return string|nil
function M.current()
	load()
	return current_id
end

---Select a thread by id or name.
---@param id string
---@return table|nil
function M.select(id)
	load()
	if threads[id] then
		current_id = id
		return threads[id]
	end
	for _, tid in ipairs(thread_order) do
		if threads[tid].name:lower() == tostring(id):lower() then
			current_id = tid
			return threads[tid]
		end
	end
	return nil
end

---@return { id: string, name: string, ts: integer, entries: integer }[]
function M.list()
	load()
	local out = {}
	for _, id in ipairs(thread_order) do
		local t = threads[id]
		out[#out + 1] = { id = id, name = t.name, ts = t.ts, entries = #t.entries }
	end
	table.sort(out, function(a, b)
		return a.ts > b.ts
	end)
	return out
end

---@param thread string|nil thread id (default: the selected one)
---@param opts { limit?: integer }|nil
---@return table[] entries
function M.entries(thread, opts)
	local t = M.get(thread)
	if not t then
		return {}
	end
	opts = opts or {}
	local out = {}
	local from = opts.limit and math.max(1, #t.entries - opts.limit + 1) or 1
	for i = from, #t.entries do
		out[#out + 1] = t.entries[i]
	end
	return out
end

----------------------------------------------------------------------
-- Entries
----------------------------------------------------------------------

---@param thread string
---@param entry table
---@return table
local function append(thread, entry)
	local t = threads[thread]
	entry.id = next_id
	entry.ts = entry.ts or now()
	next_id = next_id + 1
	t.entries[#t.entries + 1] = entry
	t.ts = entry.ts
	if #t.entries > M.max_entries * 2 then
		local keep = {}
		for i = #t.entries - M.max_entries + 1, #t.entries do
			keep[#keep + 1] = t.entries[i]
		end
		t.entries = keep
	end
	changed()
	emit("entry", entry, t)
	return entry
end

---Pinned facts travel with every task; they are how a human says "this still holds".
---@param thread string|nil
---@param text string
---@return boolean ok
function M.pin(thread, text)
	local t = M.get(thread)
	text = vim.trim(text or "")
	if not t or text == "" then
		return false
	end
	for _, p in ipairs(t.pins) do
		if p == text then
			return true
		end
	end
	t.pins[#t.pins + 1] = text
	-- pins are state, not conversation: no entry (the UI renders them as a facts
	-- block above the messages, and a "pinned: …" bubble would just be noise)
	changed()
	emit("thread", t)
	return true
end

---@param thread string|nil
---@param text string|nil remove just this fact (nil clears them all)
---@return integer removed
function M.unpin(thread, text)
	local t = M.get(thread)
	if not t then
		return 0
	end
	if not text then
		local n = #t.pins
		t.pins = {}
		changed()
		emit("thread", t)
		return n
	end
	for i, p in ipairs(t.pins) do
		if p == text then
			table.remove(t.pins, i)
			changed()
			emit("thread", t)
			return 1
		end
	end
	return 0
end

---@param thread string|nil
---@return string[]
function M.pins(thread)
	local t = M.get(thread)
	return t and t.pins or {}
end

----------------------------------------------------------------------
-- Mentions and the projection an agent receives
----------------------------------------------------------------------

local function key_of(backend, id)
	return backend .. ":" .. tostring(id)
end

---Every way a user may name a target, lowercased: its alias, label, id, and the
---backend id when that backend has exactly one target.
---@return table<string, { target: table, backend: table, key: string }[]>
function M.names()
	local out = {}
	for _, info in ipairs(backends.list()) do
		local mod = backends.get(info.id)
		if mod and info.available then
			local ok, targets = pcall(mod.targets)
			targets = ok and targets or {}
			for _, t in ipairs(targets) do
				t.backend = t.backend or mod.id
				local key = key_of(mod.id, t.id)
				target_cache[key] = t
				local names = {}
				names[#names + 1] = aliases.get(t, mod.id)
				names[#names + 1] = t.label
				names[#names + 1] = tostring(t.id)
				names[#names + 1] = aliases.default_name(t)
				if #targets == 1 then
					names[#names + 1] = mod.id
					names[#names + 1] = mod.label
				end
				for _, n in ipairs(names) do
					-- only mention-safe names: `@pid 30832` cannot be typed
					if type(n) == "string" and n ~= "" and n:find("^[%w_%-%.]+$") then
						local name = n:lower()
						out[name] = out[name] or {}
						out[name][#out[name] + 1] = { target = t, backend = mod, key = key }
					end
				end
			end
		end
	end
	-- Several agents can share a name (three pi processes in the same directory).
	-- One name reaching several agents is "ambiguous" — useless advice. Give the
	-- extras a stable suffix instead, so `@data_pulse-2` addresses one of them.
	for name, hits in pairs(out) do
		local seen, uniq = {}, {}
		for _, h in ipairs(hits) do
			if not seen[h.key] then
				seen[h.key] = true
				uniq[#uniq + 1] = h
			end
		end
		table.sort(uniq, function(a, b)
			return a.key < b.key
		end)
		out[name] = uniq
		if #uniq > 1 then
			-- `@dup` stays ambiguous (routing to a guess would be worse), but every
			-- agent gets a name of its own: dup-1, dup-2, …
			for i = 1, #uniq do
				local alias = ("%s-%d"):format(name, i)
				if not out[alias] then
					out[alias] = { uniq[i] }
				end
			end
		end
	end
	return out
end

---Resolve one name (with or without the leading `@`).
---@param name string
---@return { target: table, backend: table, key: string }|nil match, string[] candidates
function M.resolve(name)
	local wanted = tostring(name or ""):gsub("^@", ""):lower()
	if wanted == "" then
		return nil, {}
	end
	local map = M.names()
	local hits = map[wanted] or {}
	-- a name stored twice (two instances share a directory) is ambiguous on purpose
	local uniq, seen = {}, {}
	for _, h in ipairs(hits) do
		if not seen[h.key] then
			seen[h.key] = true
			uniq[#uniq + 1] = h
		end
	end
	if #uniq == 1 then
		return uniq[1], {}
	end
	table.sort(uniq, function(a, b)
		return a.key < b.key
	end)
	local candidates = {}
	for i = 1, #uniq do
		candidates[#candidates + 1] = ("%s-%d"):format(wanted, i)
	end
	return nil, candidates
end

---Who can be addressed right now, so the window can show a member list (and the
---input can complete `@` from it). Busy means "has a chat task in flight".
---@return { name: string, key: string, backend: string, label: string, busy: boolean, state: string }[]
function M.roster()
	local by_key = {}
	for name, hits in pairs(M.names()) do
		if #hits == 1 then
			local h = hits[1]
			-- the readable name wins: an alias or label over the raw id, and the
			-- plain name over a "-2" suffix
			local function rank(n)
				local score = #n * 0.01
				if n:find("%-%d+$") then
					score = score + 10
				end
				if n == tostring(h.target.id):lower() then
					score = score + 100
				end
				if n == h.backend.id:lower() then
					score = score + 5
				end
				return score
			end
			local cur = by_key[h.key]
			if cur == nil or rank(name) < rank(cur.name) then
				local rec = state.get(h.key)
				by_key[h.key] = {
					name = name,
					key = h.key,
					backend = h.backend.id,
					label = h.target.label or h.backend.label or h.backend.id,
					busy = running[h.key] ~= nil,
					state = rec and rec.state or "unknown",
				}
			end
		end
	end
	local out = {}
	for _, a in pairs(by_key) do
		out[#out + 1] = a
	end
	table.sort(out, function(a, b)
		return a.name:lower() < b.name:lower()
	end)
	return out
end

---Split `@name` tokens out of a message (a mention only counts at a word start).
---@param text string
---@return string cleaned, { raw: string, match: table|nil, candidates: string[] }[]
function M.parse(text)
	local mentions = {}
	local body = text or ""
	local function take(lead, name)
		local match, candidates = M.resolve(name)
		mentions[#mentions + 1] = { raw = "@" .. name, name = name, match = match, candidates = candidates }
		return lead
	end
	local cleaned = body:gsub("^%s*@([%w][%w_%-%.]*)", function(name)
		return take("", name)
	end)
	cleaned = cleaned:gsub("(%s)@([%w][%w_%-%.]*)", function(space, name)
		return take(space, name)
	end)
	return vim.trim(cleaned), mentions
end

---@param e table
---@return string
local function who(e)
	if e.author == "user" then
		return "me"
	elseif e.author == "agent" then
		return e.name or e.target or "agent"
	end
	return "system"
end

---The text a target gets: pinned facts, then the entries after its cursor it did
---not write itself. This is the whole "shared context" contract.
---@param thread string|nil
---@param key string
---@param upto integer|nil only entries older than this id (the message being dispatched)
---@return string text
function M.context_text(thread, key, upto)
	local t = M.get(thread)
	if not t then
		return ""
	end
	local cursor = t.cursors[key] or 0
	local picked = {}
	for _, e in ipairs(t.entries) do
		if e.id > cursor and e.kind ~= "system" and e.target ~= key and (not upto or e.id < upto) then
			picked[#picked + 1] = e
		end
	end
	if #picked > M.window then
		local tail = {}
		for i = #picked - M.window + 1, #picked do
			tail[#tail + 1] = picked[i]
		end
		picked = tail
	end
	local out = { ('<chat thread="%s">'):format(t.name) }
	if #t.pins > 0 then
		out[#out + 1] = "facts:"
		for _, p in ipairs(t.pins) do
			out[#out + 1] = "- " .. p
		end
	end
	if #picked > 0 then
		out[#out + 1] = "recent:"
		for _, e in ipairs(picked) do
			local text = e.text:gsub("\n", "\n  ")
			out[#out + 1] = ("[#%d] %s: %s"):format(e.id, who(e), text)
		end
	end
	out[#out + 1] = "</chat>"
	return vim.trim(table.concat(out, "\n"))
end

---The structured projection (for callers that render it themselves).
---@param thread string|nil
---@param key string
---@return { pins: string[], entries: table[], text: string }
function M.context(thread, key)
	return { pins = M.pins(thread), entries = M.entries(thread), text = M.context_text(thread, key) }
end

---@param thread string
---@param key string
---@param id integer
local function advance(thread, key, id)
	local t = threads[thread]
	if t then
		t.cursors[key] = math.max(t.cursors[key] or 0, id)
	end
end

---@return table<string, table>
function M.running()
	return running
end

---@return string[]
function M.pending()
	local out = {}
	for key, list in pairs(pending) do
		out[#out + 1] = ("%s (%d)"):format(key, #list)
	end
	return out
end

----------------------------------------------------------------------
-- Dispatch
----------------------------------------------------------------------

---Read an agent's answer back. Backend-specific: rex exposes the block's screen
---as text, tmux can capture a pane. Anything else gets no reply capture.
---@param target table
---@return string|nil text
local function default_capture(target)
	local ok, text = pcall(function()
		if type(target.rex) == "table" and target.rex.block then
			local cmd = { "rex", "block", "call", "format", "-", "-b", tostring(target.rex.block) }
			if target.rex.session then
				vim.list_extend(cmd, { "-s", tostring(target.rex.session) })
			end
			local res = vim.system(cmd, { text = true, stdin = '{"format":"text","trim":true}' }):wait(4000)
			if res.code ~= 0 then
				return nil
			end
			local decoded, data = pcall(vim.json.decode, res.stdout or "")
			return decoded and type(data) == "table" and data.content or nil
		end
		if target.pane then
			local res = vim.system(
				{ "tmux", "capture-pane", "-p", "-t", tostring(target.pane), "-S", "-80" },
				{ text = true }
			)
				:wait(4000)
			if res.code ~= 0 then
				return nil
			end
			return res.stdout
		end
		return nil
	end)
	return ok and text or nil
end

---Trim a captured screen down to the part worth keeping: no trailing blank lines,
---at most `limit` lines. (The prompt line the agent printed before its answer is
---left alone: guessing where the answer starts is worse than one extra line.)
---@param text string|nil
---@param limit integer|nil
---@return string
function M.tidy(text, limit)
	limit = limit or 60
	local lines = vim.split(text or "", "\n", { plain = true })
	local out = {}
	for _, line in ipairs(lines) do
		table.insert(out, (line:gsub("%s+$", "")))
	end
	while #out > 0 and out[1] == "" do
		table.remove(out, 1)
	end
	while #out > 0 and out[#out] == "" do
		out[#out] = nil
	end
	if #out > limit then
		local tail = {}
		for i = #out - limit + 1, #out do
			tail[#tail + 1] = out[i]
		end
		out = tail
	end
	return vim.trim(table.concat(out, "\n"))
end

local finish

---Send one task to one target, or queue it when that target is busy.
---@param thread string
---@param match { target: table, backend: table, key: string }
---@param text string
---@param entry table
local function dispatch(thread, match, text, entry)
	local key = match.key
	-- an agent that exited is still in the registry for a moment; saying so beats
	-- spinning a "running" bubble that will never get an answer
	local probe = match.backend.probe and match.backend.probe(match.target)
	if probe and probe.running == false then
		append(thread, {
			kind = "system",
			author = "system",
			text = ("could not send to %s: the agent is gone (%s)"):format(key, probe.detail or "not running"),
			status = "error",
		})
		return
	end
	if running[key] then
		pending[key] = pending[key] or {}
		pending[key][#pending[key] + 1] = { thread = thread, text = text, entry = entry.id, target = match.target }
		append(thread, {
			kind = "system",
			author = "system",
			text = ("%s is busy; queued"):format(key),
			status = "queued",
		})
		return
	end
	running[key] = { thread = thread, entry = entry.id, target = match.target, backend = match.backend }
	target_cache[key] = match.target
	entry.task = entry.task or {}
	entry.status = "running"
	state.dispatch(match.backend.id, match.target.id, text, { correlation = { plugin = "chat", key = thread } })
	local send = M.send or function(target, payload)
		return match.backend.send(target, payload)
	end
	local ok, err = send(match.target, text)
	if not ok then
		running[key] = nil
		append(thread, {
			kind = "system",
			author = "system",
			text = ("could not send to %s: %s"):format(key, tostring(err or "unknown error")),
			status = "error",
		})
	end
end

---The text stored for a user message: the cleaned one, unless stripping every
---mention would leave nothing (a bare "@claude" is still worth showing).
---@param original string
---@return string
---What the transcript shows: exactly what the human wrote. The mention is
---routing, not decoration, but a chat log that silently deletes `@claude` from
---your own message reads like the message was edited behind your back.
---@param original string
---@return string
local function stored_text(original)
	return vim.trim(original)
end

---The human speaks. `@name` mentions become tasks; the entry itself is the record.
---@param text string
---@param opts { thread?: string, anchor?: table }|nil
---@return table entry
function M.post(text, opts)
	load()
	opts = opts or {}
	local thread = M.thread(opts.thread)
	local cleaned, mentions = M.parse(text)
	local entry = append(thread, {
		kind = "msg",
		author = "user",
		text = stored_text(text),
		anchor = opts.anchor,
	})
	if #mentions == 0 then
		return entry
	end
	for _, m in ipairs(mentions) do
		if not m.match then
			local hint = #m.candidates > 0
					and ("that name reaches several agents — use " .. table.concat(m.candidates, " or "))
				or "no agent answers to that name"
			append(thread, {
				kind = "system",
				author = "system",
				text = ("%s — %s"):format(m.raw, hint),
				status = "error",
			})
		else
			local context = M.context_text(thread, m.match.key, entry.id)
			local payload = context .. "\n\n" .. cleaned
			advance(thread, m.match.key, entry.id)
			dispatch(thread, m.match, payload, entry)
		end
	end
	return entry
end

---An agent's answer (or an error) lands in the log.
---@param thread string|nil
---@param key string
---@param text string
---@param opts { status?: string }|nil
---@return table entry
function M.reply(thread, key, text, opts)
	load()
	opts = opts or {}
	local t = M.get(thread) or M.get()
	local target = target_cache[key]
	local name = key
	if target then
		local mod = backends.get(key:match("^([^:]+):") or "")
		name = aliases.get(target, mod and mod.id) or aliases.default_name(target)
	end
	return append(t.id, {
		kind = "result",
		author = "agent",
		target = key,
		name = name,
		text = M.tidy(text),
		status = opts.status or "done",
	})
end

---Finish a target's running task: capture what it said, log it, start its queue.
---@param key string
---@param status string|nil
---@param text string|nil explicit text (tests, or a backend that pushes its answer)
---@return table|nil entry
function finish(key, status, text)
	local job = running[key]
	if not job then
		return nil
	end
	running[key] = nil
	local body = text
	if body == nil then
		local capture = M.capture or default_capture
		local ok, res = pcall(capture, job.target)
		body = ok and res or nil
	end
	local entry = M.reply(job.thread, key, body or "(no output captured)", { status = status or "done" })
	local queue = pending[key]
	if queue and #queue > 0 then
		local next_job = table.remove(queue, 1)
		if #queue == 0 then
			pending[key] = nil
		end
		local mod = backends.get(key:match("^([^:]+):") or "")
		if mod and next_job then
			dispatch(next_job.thread, { target = next_job.target, backend = mod, key = key }, next_job.text, {
				id = next_job.entry,
			})
		end
	end
	return entry
end

M.finish = finish

---Give up on the tasks in flight (an agent that stopped answering): the running
---table and the queue are cleared so the next mention goes out immediately.
---@param thread string|nil only this thread's tasks (nil = all)
---@return integer count
function M.cancel(thread)
	load()
	if thread then
		local t = M.get(thread)
		thread = t and t.id or thread
	end
	local n = 0
	for key, rec in pairs(running) do
		if not thread or rec.thread == thread then
			running[key] = nil
			pending[key] = nil
			n = n + 1
		end
	end
	if n > 0 then
		local t = M.get(thread or current_id)
		if t then
			append(t.id, {
				kind = "system",
				author = "system",
				text = ("cancelled %d task(s)"):format(n),
				status = "error",
			})
		end
		changed()
	end
	return n
end

---Follow the state layer: a target that finished its turn ends the chat task.
function M.attach()
	state.on("done", function(rec)
		finish(rec.key, "done")
	end)
	state.on("idle", function(rec)
		finish(rec.key, "done")
	end)
	state.on("error", function(rec)
		finish(rec.key, "error")
	end)
end

return M
