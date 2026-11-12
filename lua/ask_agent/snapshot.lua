-- lua/ask_agent/snapshot.lua
---@brief Turn boundaries as git trees: "this interval is what the agent changed".
--
-- A record is `{ start, finish }`, two tree oids (see git.lua) plus the provenance
-- that makes them believable: which agent, which task, what triggered the boundary
-- (dispatch / state / manual) and when. The oids are evidence: anyone can run
-- `git diff <start> <finish>` and get the same answer, even weeks later.
--
-- Two kinds of boundaries, strongest first:
--   dispatch  we handed the text to the agent → the most precise start we can get
--   state     the agent reported working→done itself (rex OSC 7501, hook marker)
--   manual    `:AskAgentSnapshot` brackets something we cannot observe
--
-- An open record is closed when the agent reports done/idle/error/gone, or lazily
-- when it is reviewed (a fresh tree is compared without mutating the record, so the
-- stored evidence stays what we actually observed).
--
-- Failure policy: snapshots are a best-effort side channel. No repository, a broken
-- index copy, a git that hangs — all of it degrades to "no review", never to a failed
-- send. Every entry point is safe to call from the send path.

local git = require("ask_agent.git")

local M = {}

---Master switch (`setup({ snapshots = false })`).
M.enabled = true
---Journal path override (tests).
M.path = nil
---How many turns to keep (newest first, across repositories).
M.keep = 50
---Drop turns older than this (7 days).
M.ttl = 7 * 24 * 3600 * 1000
---Also open/close turns from the agent's own state changes (not only from our sends).
---This is what makes turns "typed directly into pi" visible.
M.trigger_state = true

local turns = nil -- newest first
local seq = 0

---@return integer
local function now_ms()
	local sec, usec = vim.uv.gettimeofday()
	return sec * 1000 + math.floor(usec / 1000)
end

---@return string
local function journal()
	return M.path or (vim.fn.stdpath("cache") .. "/ask-agent/snapshots.json")
end

---@param rec table
---@return table
local function slim(rec)
	return {
		id = rec.id,
		ts = rec.ts,
		cwd = rec.cwd,
		root = rec.root,
		agent = rec.agent,
		backend = rec.backend,
		task = rec.task,
		trigger = rec.trigger,
		correlation = rec.correlation,
		start = rec.start,
		finish = rec.finish,
		closed = rec.closed,
		status = rec.status,
	}
end

---@return table
local function prune()
	local cutoff = now_ms() - M.ttl
	local kept, seen = {}, {}
	for _, rec in ipairs(turns) do
		if #kept >= M.keep then
			break
		end
		local newest_per_root = rec.root and not seen[rec.root]
		if (rec.status == "open" or rec.ts >= cutoff or newest_per_root) and rec.start then
			kept[#kept + 1] = rec
			if rec.root then
				seen[rec.root] = true
			end
		end
	end
	turns = kept
end

---@return table
local function load()
	if turns then
		return turns
	end
	turns = {}
	local file = journal()
	if vim.uv.fs_stat(file) then
		local ok, lines = pcall(vim.fn.readfile, file)
		if ok and lines and lines[1] then
			local decoded_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
			if decoded_ok and type(decoded) == "table" and type(decoded.turns) == "table" then
				turns = decoded.turns
			end
		end
	end
	prune()
	return turns
end

local function save()
	if not M.enabled then
		return
	end
	prune()
	local out = { version = 1, turns = {} }
	for i, rec in ipairs(turns) do
		out.turns[i] = slim(rec)
	end
	local ok, encoded = pcall(vim.json.encode, out)
	if not ok then
		return
	end
	local file = journal()
	pcall(vim.fn.mkdir, vim.fn.fnamemodify(file, ":h"), "p")
	pcall(vim.fn.writefile, { encoded }, file)
end

---Configure (called from ask_agent.setup).
---@param opts { enabled?: boolean, path?: string, keep?: integer, ttl?: integer, trigger_state?: boolean }|nil
function M.setup(opts)
	if opts == nil then
		return
	end
	if opts.enabled ~= nil then
		M.enabled = opts.enabled
	end
	if opts.path then
		M.path = opts.path
		turns = nil
	end
	if type(opts.keep) == "number" and opts.keep > 0 then
		M.keep = opts.keep
	end
	if type(opts.ttl) == "number" and opts.ttl > 0 then
		M.ttl = opts.ttl
	end
	if opts.trigger_state ~= nil then
		M.trigger_state = opts.trigger_state
	end
end

---One-line task text (the journal only needs the gist).
---@param text string|nil
---@return string|nil
local function one_line(text)
	if type(text) ~= "string" then
		return nil
	end
	return (text:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1"):sub(1, 120))
end

---Start a turn: snapshot the worktree now.
---@param opts { cwd?: string, backend?: string, agent?: string, task?: string|nil, trigger?: string|nil }|nil
---@return table|nil record, string|nil err
function M.begin(opts)
	if not M.enabled then
		return nil, "snapshots are disabled"
	end
	opts = opts or {}
	local cwd = opts.cwd or vim.fn.getcwd()
	local root = git.root(cwd)
	if not root then
		return nil, "not a git repository"
	end
	local tree, err = git.snapshot(cwd)
	if not tree then
		return nil, err
	end
	seq = seq + 1
	local rec = {
		id = ("%d-%d"):format(now_ms(), seq),
		ts = now_ms(),
		cwd = cwd,
		root = root,
		backend = opts.backend,
		agent = opts.agent,
		task = one_line(opts.task),
		correlation = opts.correlation,
		trigger = opts.trigger or "manual",
		start = tree,
		status = "open",
	}
	load()
	table.insert(turns, 1, rec)
	save()
	return rec
end

---Close a turn with a second snapshot. Idempotent; a record with no changes stays
---closed with `finish == start` (reviewed as "no changes").
---@param rec table|string record or its id
---@param opts { trigger?: string }|nil
---@return table|nil record
function M.finish(rec, opts)
	local record = type(rec) == "string" and M.get(rec) or rec
	if not record or record.status ~= "open" then
		return record
	end
	local tree = git.snapshot(record.cwd)
	if not tree then
		return record -- keep it open: the next attempt may succeed
	end
	record.finish = tree
	record.closed = now_ms()
	record.status = "closed"
	record.finish_trigger = opts and opts.trigger
	save()
	return record
end

---Forget a turn we opened for a send that never happened.
---@param rec table|nil
function M.cancel(rec)
	if not rec then
		return
	end
	for i, r in ipairs(load()) do
		if r == rec or r.id == rec.id then
			table.remove(turns, i)
			save()
			return
		end
	end
end

---The open turn of one agent instance, if any.
---@param backend string|nil
---@param agent string|nil
---@return table|nil
function M.open_for(backend, agent)
	for _, rec in ipairs(load()) do
		if rec.status == "open" and rec.backend == backend and tostring(rec.agent) == tostring(agent) then
			return rec
		end
	end
	return nil
end

---The turn one task belongs to (the correlation recorded at dispatch time).
---@param correlation table|nil
---@return table|nil
function M.for_task(correlation)
	if type(correlation) ~= "table" then
		return nil
	end
	for _, rec in ipairs(load()) do
		local c = rec.correlation
		if type(c) == "table" and tostring(c.key) == tostring(correlation.key) and c.plugin == correlation.plugin then
			return rec
		end
	end
	return nil
end

---Newest turn for a directory (its repository root must match).
---@param cwd string|nil
---@param opts { open?: boolean }|nil only consider open / closed records
---@return table|nil
function M.last(cwd, opts)
	local root = git.root(cwd or vim.fn.getcwd())
	if not root then
		return nil
	end
	for _, rec in ipairs(load()) do
		local wanted = not opts or not opts.open or (opts.open and rec.status == "open")
		if wanted and rec.root == root then
			return rec
		end
	end
	return nil
end

---A turn by id, or its unique suffix.
---@param id string
---@return table|nil
function M.get(id)
	for _, rec in ipairs(load()) do
		if rec.id == id then
			return rec
		end
	end
	for _, rec in ipairs(load()) do
		if rec.id:sub(-#id) == id then
			return rec
		end
	end
	return nil
end

---Every turn, newest first (`cwd` filters to that repository).
---@param cwd string|nil
---@return table[]
function M.list(cwd)
	if not cwd then
		return vim.deepcopy(load())
	end
	local root = git.root(cwd)
	local out = {}
	for _, rec in ipairs(load()) do
		if rec.root == root then
			out[#out + 1] = vim.deepcopy(rec)
		end
	end
	return out
end

---The two points to compare. For an open turn the second point is a fresh snapshot,
---not stored: the interval keeps growing until the agent reports done, and the
---evidence we do have is never rewritten.
---@param rec table
---@return string|nil from, string|nil to, boolean live
function M.range(rec)
	if rec.finish then
		return rec.start, rec.finish, false
	end
	local tree = git.snapshot(rec.cwd)
	if not tree then
		return nil, nil, false
	end
	return rec.start, tree, true
end

---Called from the send path: open a turn for the instance we just handed text to.
---Text we send to an agent that already has an open turn only widens that turn.
---@param backend string
---@param agent string
---@param text string
---@param anchor table|nil
---@return table|nil
function M.on_dispatch(backend, agent, text, anchor, correlation)
	if not M.enabled then
		return nil
	end
	local open = M.open_for(backend, agent)
	if open then
		return open
	end
	local ok, rec = pcall(M.begin, {
		cwd = (anchor and anchor.cwd) or vim.fn.getcwd(),
		backend = backend,
		agent = agent,
		task = text,
		correlation = correlation,
		trigger = "dispatch",
	})
	return ok and rec or nil
end

---Subscribe to the state layer: close turns when an agent finishes, optionally open
---them when an agent starts working without us sending anything.
---@param state table ask_agent.state
function M.attach(state)
	state.on("state", function(rec, prev)
		if not M.enabled then
			return
		end
		local target = rec.target
		local cwd = target and target.cwd
		if not cwd then
			return
		end
		local state_now, state_before = rec.state, prev
		if state_now == "working" and state_before ~= "working" and M.trigger_state then
			if not M.open_for(rec.backend, rec.id) then
				pcall(M.begin, { cwd = cwd, backend = rec.backend, agent = rec.id, trigger = "state" })
			end
			return
		end
		local finished = state_now == "done" or state_now == "idle" or state_now == "error" or state_now == "gone"
		if finished then
			local open = M.open_for(rec.backend, rec.id)
			if open then
				pcall(M.finish, open, { trigger = "state:" .. state_now })
			end
		end
	end)
end

return M
