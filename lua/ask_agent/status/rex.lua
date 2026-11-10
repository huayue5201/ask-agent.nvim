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

local M = {}

local TTL = 1500
local cache = {} -- block id -> { ts, value }
local inflight = {} -- block id -> { fn, ... } callbacks waiting on one rex call

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

return M
