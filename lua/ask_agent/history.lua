-- lua/ask_agent/history.lua
---@brief Every question this plugin sent, with the anchor it carried.
--
-- The journal records task *state*; this records the *question*. That is what makes
-- old work reusable: search past asks, jump back to the exact line, or drop one into
-- the ask window again. Records are written on the send path only, after the backend
-- accepted the text, so the history never claims something was delivered when it was
-- not.
--
-- Deliberately local and opaque: no agent transcript is read or parsed, no answers
-- are stored. A record is `{ text, anchor, backend, agent, ts }` — the same payload
-- the agent received. Answers live in the agent's own session, which stays its job.

local M = {}

---Master switch (`setup({ history = false })`).
M.enabled = true
---Journal path override (tests).
M.path = nil
---How many questions to keep, newest first.
M.keep = 200
---Longest text kept per record (a prompt with a huge paste is truncated, not dropped).
M.max_text = 20000

local entries = nil -- newest first
local seq = 0

---@return integer
local function now_ms()
	local sec, usec = vim.uv.gettimeofday()
	return sec * 1000 + math.floor(usec / 1000)
end

---@return string
local function journal()
	return M.path or (vim.fn.stdpath("cache") .. "/ask-agent/history.json")
end

---@param rec table
---@return table
local function slim(rec)
	return {
		id = rec.id,
		ts = rec.ts,
		text = rec.text,
		backend = rec.backend,
		agent = rec.agent,
		label = rec.label,
		cwd = rec.cwd,
		anchor = rec.anchor,
		correlation = rec.correlation,
	}
end

---@return table
local function prune()
	if M.keep <= 0 then
		entries = {}
		return entries
	end
	local kept = {}
	for i, rec in ipairs(entries) do
		if i > M.keep then
			break
		end
		kept[i] = rec
	end
	entries = kept
	return entries
end

---@return table
local function load()
	if entries then
		return entries
	end
	entries = {}
	local file = journal()
	if vim.uv.fs_stat(file) then
		local ok, lines = pcall(vim.fn.readfile, file)
		if ok and lines and lines[1] then
			local decoded_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
			if decoded_ok and type(decoded) == "table" and type(decoded.entries) == "table" then
				entries = decoded.entries
			end
		end
	end
	prune()
	return entries
end

local function save()
	if not M.enabled then
		return
	end
	prune()
	local out = { version = 1, entries = {} }
	for i, rec in ipairs(entries) do
		out.entries[i] = slim(rec)
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
---@param opts { enabled?: boolean, path?: string, keep?: integer, max_text?: integer }|nil
function M.setup(opts)
	if opts == nil then
		return
	end
	if opts.enabled ~= nil then
		M.enabled = opts.enabled
	end
	if opts.path then
		M.path = opts.path
		entries = nil
	end
	if type(opts.keep) == "number" and opts.keep > 0 then
		M.keep = opts.keep
	end
	if type(opts.max_text) == "number" and opts.max_text > 0 then
		M.max_text = opts.max_text
	end
end

---Record one delivered question. Called from the send path only; failures never
---propagate (history is a side channel, not part of delivery).
---@param rec { text: string, backend?: string, agent?: string|number, label?: string, anchor?: table, correlation?: table }
---@return table|nil entry
function M.add(rec)
	if not M.enabled or type(rec) ~= "table" or type(rec.text) ~= "string" then
		return nil
	end
	local ok, entry = pcall(function()
		seq = seq + 1
		local ts = now_ms()
		local text = rec.text
		if #text > M.max_text then
			text = text:sub(1, M.max_text) .. "\n… (truncated in history)"
		end
		local out = {
			id = ("%d-%d"):format(ts, seq),
			ts = ts,
			text = text,
			backend = rec.backend,
			agent = rec.agent ~= nil and tostring(rec.agent) or nil,
			label = rec.label,
			cwd = (rec.anchor and rec.anchor.cwd) or vim.fn.getcwd(),
			anchor = rec.anchor,
			correlation = rec.correlation,
		}
		load()
		table.insert(entries, 1, out)
		save()
		return out
	end)
	return ok and entry or nil
end

---@param rec table|nil
---@param opts { cwd?: string, query?: string, backend?: string, limit?: integer }|nil
---@return boolean
local function matches(rec, opts)
	if opts.cwd and rec.cwd ~= opts.cwd then
		return false
	end
	if opts.backend and rec.backend ~= opts.backend then
		return false
	end
	if opts.query and opts.query ~= "" then
		local needle = opts.query:lower()
		local hay = table.concat({ rec.text or "", (rec.anchor and rec.anchor.path) or "", rec.label or "" }, "\n")
		if not hay:lower():find(needle, 1, true) then
			return false
		end
	end
	return true
end

---Recorded questions, newest first.
---@param opts { cwd?: string, query?: string, backend?: string, limit?: integer }|nil
---@return table[]
function M.list(opts)
	opts = opts or {}
	local out = {}
	for _, rec in ipairs(load()) do
		if matches(rec, opts) then
			out[#out + 1] = rec
			if opts.limit and #out >= opts.limit then
				break
			end
		end
	end
	return out
end

---Find a record by full id or unique prefix ("1720000000000-3", "1720000").
---@param id string
---@return table|nil
function M.get(id)
	if type(id) ~= "string" or id == "" then
		return nil
	end
	local exact, prefix = nil, {}
	for _, rec in ipairs(load()) do
		if rec.id == id then
			exact = rec
			break
		end
		if rec.id:sub(1, #id) == id then
			prefix[#prefix + 1] = rec
		end
	end
	if exact then
		return exact
	end
	if #prefix == 1 then
		return prefix[1]
	end
	return nil
end

---Delete one record (no arg clears everything).
---@param id string|nil
---@return boolean removed
function M.remove(id)
	load()
	if id == nil then
		entries = {}
		save()
		return true
	end
	local target = M.get(id)
	if not target then
		return false
	end
	for i, rec in ipairs(entries) do
		if rec.id == target.id then
			table.remove(entries, i)
			save()
			return true
		end
	end
	return false
end

---Clear the whole history.
function M.clear()
	load()
	entries = {}
	save()
end

---`#files` a record's anchor points at, for display ("src/a.lua:12" or "<no filename>").
---@param rec table
---@return string
function M.describe(rec)
	local a = rec.anchor or {}
	local where = a.path and ("%s:%d"):format(a.path, a.line or 1) or "<no filename>"
	local bits = { where }
	if a.visual then
		table.insert(bits, ("sel %d-%d"):format(a.visual.start_line or 0, a.visual.end_line or 0))
	end
	-- the dispatching tool (todo2 task, a plugin's key) when there is one
	local c = rec.correlation
	local ckey = c and (c.label or c.key)
	if ckey then
		table.insert(bits, (c.plugin and c.plugin ~= "todo2") and ("%s:%s"):format(c.plugin, ckey) or tostring(ckey))
	end
	local first = (rec.text or ""):gsub("%s+", " "):sub(1, 80)
	return ("%s  %s"):format(table.concat(bits, " · "), first)
end

---Jump to the code a record was asked about. Uses the live buffer when it still
---exists; otherwise opens the file by path (the session may have restarted).
---@param rec table
---@return boolean ok, string|nil err
function M.jump(rec)
	local anchor = rec and rec.anchor
	if not anchor then
		return false, "this record has no anchor"
	end
	local context = require("ask_agent.context")
	local ok, err = context.jump_to(anchor)
	if ok then
		return true
	end
	if not anchor.path or anchor.path == "" then
		return false, err
	end
	-- anchor.path is recorded relative to the anchor's cwd (":~:."), so resolve it
	-- there rather than against whatever directory the plugin is running in now.
	local path = anchor.path
	if not path:match("^/") and not path:match("^~") then
		path = (anchor.cwd or vim.fn.getcwd()) .. "/" .. path
	end
	local file = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
	if vim.fn.filereadable(file) == 0 then
		return false, "the file no longer exists: " .. anchor.path
	end
	vim.cmd.edit(vim.fn.fnameescape(file))
	vim.api.nvim_win_set_cursor(0, { math.max(1, anchor.line or 1), math.max(0, (anchor.col or 1) - 1) })
	vim.cmd("normal! zz")
	return true
end

return M
