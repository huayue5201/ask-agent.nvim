-- lua/ask_agent/status/rex.lua
---@brief Program-status source for agents running inside rex (OSC 7501).
--
-- rex keeps a per-block program status that agents report themselves
-- (`ESC ] 7501 ; state=... `). It is far more precise than anything we can
-- infer from a socket or a hook file: it knows `blocked` (waiting for the user)
-- and `done`, not just "busy".
--
--   rex block call -b <block> program_status   -> {"records":[{...}]}
--
-- Records are a tree; the root record (no id) describes the block itself, the
-- nested ones describe sub-programs. We only care about the best first record.
-- Callers apply it over the backend's own probe result, never instead of it:
-- an agent that does not report simply has no records.
--
-- Polling is only the fallback: `rex events -s SESSION --json` streams
-- terminal.program_status_changed / _removed, so state.lua can react within
-- milliseconds instead of up to one interval later.

local M = {}

local TTL = 1500

local cache = {} -- block id -> { ts, value }
local inflight = {} -- block id -> { fn, ... } callbacks waiting on one rex call

---Drop the cache (called when an event says a record changed).
function M.invalidate()
	cache = {}
end

---Whether rex is usable at all (installed and reachable).
---@return boolean
function M.available()
	return vim.fn.executable("rex") == 1
end

---@param records table[]
---@return table|nil
local function root(records)
	for _, rec in ipairs(records or {}) do
		if rec.id == nil or rec.id == "" then
			return rec
		end
	end
	return (records or {})[1]
end

---@param rec table
---@return table|nil
local function decode(rec)
	if type(rec) ~= "table" or type(rec.state) ~= "string" then
		return nil
	end
	return {
		state = rec.state,
		kind = rec.kind,
		progress = rec.progress,
		msg = rec.msg,
		app = rec.effective_app or rec.app,
		title = rec.title,
	}
end

---Read one block's program status. Results are cached for TTL and in-flight
---requests are shared, so a 2s refresh timer does not spawn rex once per agent.
---The callback always runs on the main loop and may receive nil.
---@param loc { session?: string, block: string }
---@param cb fun(value: table|nil)
function M.query(loc, cb)
	local block = type(loc) == "table" and loc.block or nil
	if not block or not M.available() then
		return vim.schedule(function()
			cb(nil)
		end)
	end
	local hit = cache[block]
	if hit and vim.uv.now() - hit.ts < TTL then
		return cb(hit.value)
	end
	if inflight[block] then
		table.insert(inflight[block], cb)
		return
	end
	local waiters = { cb }
	inflight[block] = waiters
	local cmd = { "rex", "block", "call", "-b", block }
	if loc.session then
		vim.list_extend(cmd, { "-s", loc.session })
	end
	cmd[#cmd + 1] = "program_status"
	pcall(vim.system, cmd, { text = true }, function(res)
		local value
		if res.code == 0 then
			local ok, data = pcall(vim.json.decode, res.stdout or "")
			if ok and type(data) == "table" then
				value = decode(root(data.records))
			end
		end
		vim.schedule(function()
			cache[block] = { ts = vim.uv.now(), value = value }
			inflight[block] = nil
			for _, fn in ipairs(waiters) do
				pcall(fn, value)
			end
		end)
	end)
end

---Parse one NDJSON line of `rex events --json` into `{ type, payload }`, or nil.
---@param line string
---@return table|nil
function M.parse_line(line)
	local ok, data = pcall(vim.json.decode, line)
	if not ok or type(data) ~= "table" or data.type ~= "session_event" then
		return nil
	end
	local ev = (data.payload or {}).event
	if type(ev) ~= "table" or type(ev.type) ~= "string" then
		return nil
	end
	return { type = ev.type, payload = ev.payload or {} }
end

local watches = {}

---Stream this session's events (one `rex events` process per session, restarted on exit).
---The callback runs on the main loop with the parsed event; false when unavailable.
---@param session string
---@param cb fun(event: table)
---@return boolean started
function M.watch(session, cb)
	if watches[session] or not M.available() then
		return false
	end
	local w = { buf = "", failures = 0, err = "" }
	watches[session] = w
	local function feed(chunk)
		w.buf = w.buf .. chunk
		while true do
			local nl = w.buf:find("\n", 1, true)
			if not nl then
				return
			end
			local line = w.buf:sub(1, nl - 1)
			w.buf = w.buf:sub(nl + 1)
			local ev = M.parse_line(line)
			if ev then
				vim.schedule(function()
					if not w.stopped then
						pcall(cb, ev)
					end
				end)
			end
		end
	end
	local function start()
		if w.stopped then
			return
		end
		local started = vim.uv.now()
		w.proc = vim.system({ "rex", "events", "-s", session, "--json" }, {
			text = true,
			stdout = function(err, chunk)
				-- vim.system calls this with err set and chunk=nil when the pipe breaks
				if not err and chunk then
					feed(chunk)
				end
			end,
			stderr = function(_, chunk)
				if chunk then
					w.err = (w.err .. chunk):sub(-400)
				end
			end,
		}, function()
			if w.stopped then
				return
			end
			-- a stream that dies immediately is not going to start working on retry
			w.failures = vim.uv.now() - started < 3000 and w.failures + 1 or 0
			if w.failures >= 3 then
				watches[session] = nil
				local why = vim.trim(w.err)
				if why ~= "" then
					vim.schedule(function()
						vim.notify(("[ask_agent] rex events for %s: %s"):format(session, why), vim.log.levels.DEBUG)
					end)
				end
				return
			end
			w.timer = vim.defer_fn(start, 2000)
		end)
	end
	start()
	return true
end

---Stop streaming a session.
---@param session string
function M.unwatch(session)
	local w = watches[session]
	if not w then
		return
	end
	w.stopped = true
	watches[session] = nil
	if w.timer then
		pcall(w.timer.close, w.timer)
	end
	if w.proc then
		pcall(w.proc.kill, w.proc, "sigterm")
	end
end

return M
