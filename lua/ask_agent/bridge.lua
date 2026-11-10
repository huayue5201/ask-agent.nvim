-- lua/ask_agent/bridge.lua
---@brief Bridge that lets an external coding agent (pi) read the "live nvim" context.
--
-- Why it exists: pi runs in another tmux pane, so a plain `read` only sees the
-- on-disk snapshot. It cannot see unsaved buffers, the cursor, the visual
-- selection, LSP diagnostics or the quickfix list. This module opens an RPC
-- socket and registers it under the registry directory so the agent can pull
-- that state back out of nvim.
--
-- Registry directory defaults to `vim.fn.stdpath("cache") .. "/pi-ctx"`. Keep
-- that default: an existing pi extension reads it. Override it with
-- `require("ask_agent.bridge").setup({ dir = "/some/dir" })`, which must be
-- called before `M.attach()`.
--
-- External usage (one-shot call, no long-lived client needed):
--   nvim --server <sock> --remote-expr \
--     'v:lua.require("ask_agent.bridge").handle("<base64(json)>")'
-- Requests: {"action":"state"} | {"action":"buffer","path":...,"from":..,"to":..}
--      | {"action":"diagnostics"} | {"action":"quickfix"} | {"action":"list"}
--      | {"action":"agents","state":..} | {"action":"ask","text":..,"backend":..,"target":..}
--      | {"action":"reply","key":..,"text":..} | {"action":"task","key":..}
--      | {"action":"result","key":..,"wait_ms":..} | {"action":"status"}
--      | {"action":"project","root":..,"full":..,"wait_ms":..}
-- The `project` action is not built in: register a handler with
-- `require("ask_agent.bridge").extend("project", fn)`; `fn` receives the request
-- table and returns a response table.
-- Returns a JSON string ({"ok":false,"error":...} on failure, never throws).
--
-- Code content always comes from the in-memory buffer (including unsaved
-- changes); the on-disk file is only used as a fallback when no buffer matches.

local M = {}

---@type table<string, fun(req: table): table>
local extra_handlers = {}

local DIR = vim.fn.stdpath("cache") .. "/pi-ctx"
local PID = vim.fn.getpid()
local SOCK = string.format("%s/%d.sock", DIR, PID)
local REG = string.format("%s/%d.json", DIR, PID)

local attached = false
local last_reg = 0

---Override bridge options. Currently only `dir` (registry directory).
---Call before `M.attach()`.
---@param opts { dir?: string }|nil
function M.setup(opts)
	opts = opts or {}
	if type(opts.dir) == "string" and opts.dir ~= "" then
		DIR = opts.dir:gsub("/+$", "")
		SOCK = string.format("%s/%d.sock", DIR, PID)
		REG = string.format("%s/%d.json", DIR, PID)
	end
end

---Where the registration files/sockets live.
---@return string
function M.dir()
	return DIR
end

local function now_ms()
	return math.floor(vim.uv.now())
end

local function buf_path(buf)
	local name = vim.api.nvim_buf_get_name(buf)
	if name == "" then
		return nil
	end
	if name:sub(1, 7) == "term://" or name:sub(1, 7) == "oil://" then
		return name
	end
	return vim.fn.fnamemodify(name, ":p")
end

---Shrink an absolute path relative to the cwd so the agent can use it directly.
local function rel(path)
	if not path then
		return nil
	end
	local cwd = vim.fn.getcwd() .. "/"
	if path:sub(1, #cwd) == cwd then
		return path:sub(#cwd + 1)
	end
	return path
end

---Recently used listed buffers (lastused descending), as a hint about what
---the user was just looking at.
local function recent(limit)
	local out = {}
	for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
		if info.name ~= "" and info.name:sub(1, 7) ~= "term://" then
			table.insert(out, { path = rel(info.name), lastused = info.lastused })
		end
	end
	table.sort(out, function(a, b)
		return a.lastused > b.lastused
	end)
	while #out > (limit or 10) do
		table.remove(out)
	end
	return out
end

---The visual selection (only while actually in a visual mode).
local function visual()
	local mode = vim.fn.mode()
	if not (mode == "v" or mode == "V" or mode == "\22") then
		return nil
	end
	local s, e = vim.fn.getpos("v"), vim.fn.getpos(".")
	local sline, eline = s[2], e[2]
	local kind = mode == "V" and "line" or (mode == "\22" and "block" or "char")
	if sline == 0 or eline == 0 then
		return nil
	end
	if sline > eline then
		sline, eline = eline, sline
	end
	local lines = vim.api.nvim_buf_get_lines(0, sline - 1, eline, false)
	return { kind = kind, start_line = sline, end_line = eline, lines = lines }
end

---Per-tab working directories (tab_workspace uses :tcd to give each tab its own
---cwd, so the agent needs to know which projects are actually open).
local function tabs()
	local out = {}
	local cur = vim.fn.tabpagenr()
	for idx in ipairs(vim.fn.gettabinfo()) do
		local file
		local okw, win = pcall(vim.api.nvim_tabpage_get_win, idx)
		if okw then
			local okb, buf = pcall(vim.api.nvim_win_get_buf, win)
			if okb then
				file = rel(buf_path(buf))
			end
		end
		local okc, cwd = pcall(vim.fn.getcwd, -1, idx)
		table.insert(out, { index = idx, active = idx == cur, cwd = okc and cwd or nil, file = file })
	end
	return out
end

local function state()
	local buf = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local qf = vim.fn.getqflist({ size = 1, title = 1 })
	local diags = 0
	for _, d in pairs(vim.diagnostic.get()) do
		if d.bufnr and vim.api.nvim_buf_is_valid(d.bufnr) then
			diags = diags + 1
		end
	end
	return {
		ok = true,
		action = "state",
		pid = PID,
		sock = SOCK,
		cwd = vim.fn.getcwd(),
		bufnr = buf,
		path = rel(buf_path(buf)),
		filetype = vim.bo[buf].filetype,
		modified = vim.bo[buf].modified,
		mode = vim.fn.mode(),
		cursor = { line = cursor[1], col = cursor[2] + 1 },
		total_lines = vim.api.nvim_buf_line_count(buf),
		visual = visual(),
		diagnostic_count = diags,
		quickfix = { size = qf.size, title = qf.title },
		tabs = tabs(),
		buffers = recent(10),
	}
end

---Which buffer does the request path refer to? Returns nil when nothing
---matches (the caller then falls back to disk).
local function find_buf(path)
	local want = vim.fn.fnamemodify(vim.fn.getcwd() .. "/" .. path, ":p")
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		local p = buf_path(buf)
		if p and (p == want or vim.fn.fnamemodify(p, ":p") == want) then
			return buf
		end
	end
	return nil
end

local function buffer(req)
	local path = req.path
	local buf
	if path and path ~= "" then
		buf = find_buf(path)
	else
		buf = vim.api.nvim_get_current_buf()
		path = rel(buf_path(buf))
	end

	local lines
	local from = req.from or 1
	local to = req.to
	local disk = false
	local source = vim.api.nvim_buf_is_valid(buf or -1) and buf_path(buf) or nil

	if buf and vim.api.nvim_buf_is_valid(buf) then
		local total = vim.api.nvim_buf_line_count(buf)
		to = math.min(to or total, total)
		lines = vim.api.nvim_buf_get_lines(buf, from - 1, to, false)
		path = rel(buf_path(buf)) or path
		if vim.bo[buf].modified then
			disk = true -- unsaved changes: content differs from disk
		end
	else
		local abs = vim.fn.fnamemodify(vim.fn.getcwd() .. "/" .. (path or ""), ":p")
		if vim.fn.filereadable(abs) == 0 then
			return { ok = false, error = "file not found: " .. tostring(path) }
		end
		local all = vim.fn.readfile(abs)
		to = math.min(to or #all, #all)
		lines = {}
		for i = from, to do
			lines[#lines + 1] = all[i]
		end
		source = abs
	end

	local cap = req.max_lines or 2000
	local truncated = false
	if #lines > cap then
		lines = { unpack(lines, 1, cap) }
		to = from + cap - 1
		truncated = true
	end

	return {
		ok = true,
		action = "buffer",
		path = path,
		abs_path = source,
		from = from,
		to = to,
		total_lines = buf and vim.api.nvim_buf_line_count(buf) or nil,
		modified = disk,
		filetype = buf and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype or nil,
		lines = lines,
		truncated = truncated,
	}
end

local severity_name = { "ERROR", "WARN", "INFO", "HINT" }

local function diagnostics(req)
	local by_file, order = {}, {}
	local want = req.path and find_buf(req.path) or nil
	for _, d in ipairs(vim.diagnostic.get(want)) do
		local buf = d.bufnr
		local name = rel(buf_path(buf)) or "<unnamed>"
		if not by_file[name] then
			by_file[name] = {}
			order[#order + 1] = name
		end
		table.insert(by_file[name], {
			line = d.lnum + 1,
			col = (d.col or 0) + 1,
			severity = severity_name[d.severity] or "?",
			message = d.message,
			source = d.source,
		})
	end
	if #order == 0 then
		return { ok = true, action = "diagnostics", files = {}, clean = true }
	end
	local files = {}
	for _, name in ipairs(order) do
		table.insert(files, { path = name, items = by_file[name] })
	end
	return { ok = true, action = "diagnostics", files = files }
end

local function quickfix()
	local qf = vim.fn.getqflist({ items = 1, title = 1 })
	local items = {}
	for _, it in ipairs(qf.items or {}) do
		local path = it.bufnr and it.bufnr > 0 and buf_path(it.bufnr) or nil
		table.insert(items, {
			path = rel(path) or nil,
			line = it.lnum,
			col = it.col,
			text = it.text,
		})
		if #items >= 200 then
			break
		end
	end
	return { ok = true, action = "quickfix", title = qf.title, size = #items, items = items }
end

---Scan the registry directory and list every live nvim instance (ignores the
---request; used by the agent's /nvim-pin command).
function M.list()
	local out = {}
	local ok, names = pcall(vim.fn.readdir, DIR)
	if not ok then
		return { ok = true, action = "list", instances = {} }
	end
	for _, name in ipairs(names or {}) do
		if name:match("%.json$") then
			local txt = table.concat(vim.fn.readfile(DIR .. "/" .. name), "\n")
			local ok2, entry = pcall(vim.json.decode, txt)
			if ok2 and type(entry) == "table" then
				entry.self = (tostring(entry.pid) == tostring(PID))
				table.insert(out, entry)
			end
		end
	end
	table.sort(out, function(a, b)
		return (a.ts or 0) > (b.ts or 0)
	end)
	return { ok = true, action = "list", instances = out }
end

---Every agent this instance tracks, as the sidebar sees it (action: "agents").
---@param req table|nil
---@return table
local function agents(req)
	local st = require("ask_agent.state")
	local filter = type(req) == "table" and req.state and { state = req.state } or nil
	local out = {}
	for _, rec in ipairs(st.all(filter)) do
		local task = st.task(rec.key)
		out[#out + 1] = {
			key = rec.key,
			name = st.name(rec),
			backend = rec.backend,
			id = rec.id,
			state = rec.state,
			kind = rec.kind,
			progress = rec.progress,
			msg = rec.msg,
			source = rec.source,
			unread = rec.unread and true or nil,
			gone = rec.gone and true or nil,
			since = rec.since,
			task = task and { text = task.text, status = task.status, reply = task.reply, ts = task.ts } or nil,
		}
	end
	return { ok = true, action = "agents", agents = out }
end

---Hand text to an agent (action: "ask"): {text, backend?, target?, correlation?}.
---@param req table
---@return table
local function ask(req)
	if type(req.text) ~= "string" or req.text == "" then
		return { ok = false, error = "ask requires a non-empty text" }
	end
	local ok, err = require("ask_agent").send(req.text, {
		backend = req.backend,
		target = req.target,
		correlation = req.correlation,
	})
	if not ok then
		return { ok = false, error = tostring(err) }
	end
	return { ok = true, action = "ask" }
end

---Answer a blocked agent (action: "reply"): {key, text}.
---@param req table
---@return table
local function reply(req)
	if type(req.key) ~= "string" or type(req.text) ~= "string" or req.text == "" then
		return { ok = false, error = "reply requires key and text" }
	end
	local ok, err = require("ask_agent").reply(req.key, req.text)
	if not ok then
		return { ok = false, error = tostring(err) }
	end
	return { ok = true, action = "reply" }
end

---The newest task handed to an agent (action: "task"): {key}.
---@param req table
---@return table
local function task(req)
	if type(req.key) ~= "string" then
		return { ok = false, error = "task requires key" }
	end
	local st = require("ask_agent.state")
	local rec = st.get(req.key)
	if not rec then
		return { ok = false, error = "unknown agent " .. req.key }
	end
	local t = st.task(req.key)
	if not t then
		return { ok = true, action = "task", task = vim.NIL }
	end
	return {
		ok = true,
		action = "task",
		task = {
			text = t.text,
			ts = t.ts,
			status = t.status,
			reply = t.reply,
			correlation = t.correlation,
			anchor = t.anchor,
			output = t.output,
		},
	}
end

---Output of an agent's newest turn (action: "result"): {key, wait_ms?}.
---Waits up to wait_ms (default 2000) for the terminal capture.
---@param req table
---@return table
local function result(req)
	if type(req.key) ~= "string" then
		return { ok = false, error = "result requires key" }
	end
	local st = require("ask_agent.state")
	local done, payload, failure = false, nil, nil
	st.result(req.key, function(t, err)
		done, payload, failure = true, t, err
	end)
	vim.wait(math.max(0, tonumber(req.wait_ms) or 2000), function()
		return done
	end, 20)
	if not done then
		return { ok = false, error = "capture timed out" }
	end
	if not payload then
		return { ok = false, error = tostring(failure or "no output") }
	end
	return {
		ok = true,
		action = "result",
		key = req.key,
		text = payload.text,
		output = payload.output,
		status = payload.status,
	}
end

---Counts and the statusline chunk (action: "status").
---@return table
local function status()
	local st = require("ask_agent.state")
	return { ok = true, action = "status", counts = st.counts(), statusline = st.statusline() }
end

local handlers = {
	task = task,
	result = result,
	status = function()
		return status()
	end,
	state = function()
		return state()
	end,
	agents = agents,
	ask = ask,
	reply = reply,
	buffer = buffer,
	diagnostics = diagnostics,
	quickfix = function()
		return quickfix()
	end,
	list = function()
		return M.list()
	end,
}

---Register an extra action handler. `fn` receives the request table and must
---return a response table.
---@param action string
---@param fn fun(req: table): table
function M.extend(action, fn)
	assert(type(action) == "string" and action ~= "", "action must be a non-empty string")
	assert(type(fn) == "function", "handler must be a function")
	extra_handlers[action] = fn
end

---Names of every action this bridge can currently handle. `project` is part of
---the documented contract but stays unregistered until `M.extend("project", fn)`
---is called, so it is always listed here.
---@return string[]
function M.handlers()
	local out, seen = {}, {}
	local function add(action)
		if not seen[action] then
			seen[action] = true
			out[#out + 1] = action
		end
	end
	for action in pairs(handlers) do
		add(action)
	end
	for action in pairs(extra_handlers) do
		add(action)
	end
	add("project")
	table.sort(out)
	return out
end

---Write the instance registry file (the agent uses it to find the socket and
---to tell which project this instance is working on).
function M.registry()
	vim.fn.mkdir(DIR, "p")
	local buf = vim.api.nvim_get_current_buf()
	local entry = {
		pid = PID,
		sock = SOCK,
		cwd = vim.fn.getcwd(),
		name = vim.v.servername ~= "" and vim.v.servername or nil,
		file = rel(buf_path(buf)),
		ts = os.time(),
	}
	local f = io.open(REG, "w")
	if not f then
		return
	end
	f:write(vim.json.encode(entry))
	f:close()
	last_reg = now_ms()
end

---Entry point: start the socket, register the instance and keep it fresh.
---Called once from the plugin's setup.
function M.attach()
	if attached then
		return
	end
	vim.fn.mkdir(DIR, "p")
	local ok, addr = pcall(vim.fn.serverstart, SOCK)
	if not ok then
		-- a socket file left behind by an unclean exit: remove it and retry once
		pcall(os.remove, SOCK)
		ok, addr = pcall(vim.fn.serverstart, SOCK)
	end
	if not ok then
		vim.notify("[ask_agent.bridge] serverstart failed: " .. tostring(addr), vim.log.levels.WARN)
		return
	end
	attached = true
	pcall(M.registry)

	local grp = vim.api.nvim_create_augroup("PiCtxBridge", { clear = true })
	local function touch()
		if now_ms() - last_reg < 2000 then
			return
		end
		pcall(M.registry)
	end
	vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "DirChanged" }, {
		group = grp,
		callback = function()
			last_reg = 0 -- these events carry a lot of state; do not throttle
			pcall(M.registry)
		end,
	})
	vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, { group = grp, callback = touch })
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = grp,
		callback = function()
			pcall(os.remove, REG)
			pcall(os.remove, SOCK)
		end,
	})
end

---RPC entry point: takes a base64(json) request and returns a JSON string.
---Never throws.
function M.handle(b64)
	local ok, res = pcall(function()
		local req = vim.json.decode(vim.base64.decode(b64 or ""))
		local action = req.action
		if action == "project" and not extra_handlers.project then
			return {
				ok = false,
				error = "project action not registered " .. "(use require('ask_agent.bridge').extend('project', fn))",
			}
		end
		local h = extra_handlers[action] or handlers[action]
		if not h then
			return { ok = false, error = "unknown action: " .. tostring(action) }
		end
		return h(req)
	end)
	if not ok then
		return vim.json.encode({ ok = false, error = tostring(res) })
	end
	return vim.json.encode(res)
end

return M
