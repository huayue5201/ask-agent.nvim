-- lua/ask_agent/backends/deck.lua
---@brief deck backend: talks to a running StudyDeck instance over HTTP.
--
-- StudyDeck is a desktop app that owns its window, so a send is one HTTP request.
-- Unlike a terminal agent it *does* report its own turn lifecycle, and this backend
-- uses it: the SSE stream is parsed, the answer is handed back to the results module,
-- the turn id is remembered so it can be cancelled, and `GET /api/turns` covers
-- turns started in the app UI (or before this nvim started).
--
-- Where the app is: `<data-dir>/port`, a handshake the app writes at startup:
--
--   {"port": 61705, "pid": 66125, "api": 2,
--    "caps": ["turns","events","cancel","sessions",...], "token": "…"}
--
--   macOS  ~/Library/Application Support/dev.studydeck.app/port
--   XDG    $XDG_DATA_HOME/dev.studydeck.app/port
--
-- `caps` and `api` exist so this backend can degrade instead of guessing: an app
-- without `turns` gets the local (in-memory) lifecycle only, an app without `token`
-- gets no Authorization header. `token` is the bearer credential the app requires on
-- /api/* (written 0600 next to the DB, also handed to the SPA through the page).
--
-- Probe stays cheap: the poller runs every couple of seconds and the map/render path
-- calls it too, so it reads the handshake file and local state, and refreshes the
-- remote turn list in the background at most once every REMOTE_TTL.

local M = { id = "deck", label = "deck" }

---State per target id:
---  { state = "working" | "done" | "error" | "idle", msg?, ts?, task_id?, turn?, session?, answer? }
---@type table<string, table>
local inflight = {}
M._inflight = inflight -- tests drive transitions without a server

---How `vim.system` is reached; tests replace this to simulate curl.
---@type fun(args: string[], opts: table, cb: fun(res: table)): any
M._spawn = nil

---Turns the app knows about but this nvim did not start (cheap, cached snapshot).
local remote = { at = 0, fetching = false, turns = {} }
---cwd -> session id, learned from our own turns, so the remote list can be filtered.
local sessions = {}
---Remote refresh interval: longer than the state poll (2s) on purpose.
local REMOTE_TTL = 5000

local function now_ms()
	return math.floor(vim.uv.now())
end

local function spawn(args, opts, cb)
	local fn = M._spawn or vim.system
	return fn(args, opts, cb)
end

---@return string
function M.dir()
	if vim.fn.has("mac") == 1 then
		return vim.fs.joinpath(vim.env.HOME or "~", "Library/Application Support/dev.studydeck.app")
	end
	local base = vim.env.XDG_DATA_HOME
	if not base or base == "" then
		base = (vim.env.HOME or "~") .. "/.local/share"
	end
	return vim.fs.joinpath(base, "dev.studydeck.app")
end

---Read the handshake. No subprocess and no network here on purpose: callers render on
---every poll, and a backend that shells out while a test stubs vim.system breaks
---unrelated tests.
---@return table|nil
function M.handshake()
	local fd = io.open(M.dir() .. "/port", "r")
	if not fd then
		return nil
	end
	local raw = fd:read("*a") or ""
	fd:close()
	local ok, decoded = pcall(vim.json.decode, raw)
	if not ok or type(decoded) ~= "table" then
		return nil
	end
	local port = tonumber(decoded.port)
	if not port then
		return nil
	end
	local caps = {}
	for _, cap in ipairs(type(decoded.caps) == "table" and decoded.caps or {}) do
		caps[cap] = true
	end
	return {
		port = port,
		pid = tonumber(decoded.pid),
		api = tonumber(decoded.api) or 1,
		caps = caps,
		token = type(decoded.token) == "string" and decoded.token or nil,
	}
end

---Kept for callers written against the first version of this file.
---@return table|nil
function M.handle()
	return M.handshake()
end

---Is that pid still alive? uv.kill(pid, 0) only probes; EPERM still means it exists.
---@param pid integer|nil
---@return boolean
local function alive(pid)
	if not pid then
		return true -- an older app wrote no pid; trust the file
	end
	local ok, res = pcall(vim.uv.kill, pid, 0)
	return ok and res == 0
end

---The port the running app bound, or nil when it is not running (no file / process gone).
---@return integer|nil
function M.port()
	local hs = M.handshake()
	if not hs or not alive(hs.pid) then
		return nil
	end
	return hs.port
end

---Does the running app advertise a capability? A missing handshake speaks "old build".
---@param name string
---@return boolean
function M.supports(name)
	local hs = M.handshake()
	return hs ~= nil and hs.caps[name] == true
end

---@return boolean available, string? reason
function M.available()
	local hs = M.handshake()
	if not hs then
		return false, "StudyDeck 没在运行"
	end
	if not alive(hs.pid) then
		return false, "StudyDeck 的握手文件还在，但进程已经退出"
	end
	return true
end

---@return table[]
function M.targets()
	local hs = M.handshake()
	if not hs or not alive(hs.pid) then
		return {}
	end
	return { { id = "deck", label = "deck", cwd = vim.fn.getcwd(), port = hs.port } }
end

---Authorization header arguments for a handshake, or nothing for an old build.
---@param hs table
---@return string[]
local function auth_args(hs)
	if hs and hs.token and hs.token ~= "" then
		return { "-H", "Authorization: Bearer " .. hs.token }
	end
	return {}
end

---Best human-readable failure: a JSON `error` body, else curl's stderr.
---@param res table
---@return string
local function err_text(res)
	local out = (res and res.stdout or ""):gsub("%s+$", "")
	if out ~= "" then
		local ok, obj = pcall(vim.json.decode, out)
		if ok and type(obj) == "table" and type(obj.error) == "string" and obj.error ~= "" then
			return obj.error
		end
	end
	local why = ((res and res.stderr) or ""):gsub("%s+", " "):gsub("^%s+", ""):sub(1, 300)
	if why ~= "" then
		return why
	end
	return ("curl 退出码 " .. tostring(res and res.code))
end

---One async request. `cb(res|nil, spawn_err?)` always runs on the main loop.
---  - `--fail-with-body` turns HTTP 4xx/5xx into a non-zero exit while keeping the JSON
---    body: without it every rejected request (401 stale token, 409 session busy) looked
---    like a finished turn; with it the app's own message reaches the user.
---  - `--max-time` guards a hung socket; a turn has no *short* timeout.
---@param hs table handshake (port, token)
---@param method string
---@param path string
---@param opts { body?: string, timeout?: integer, cb: fun(res: table|nil, err: string|nil) }|nil
---@return boolean started
local function request(hs, method, path, opts)
	opts = opts or {}
	local cb = opts.cb or function() end
	local args = {
		"curl",
		"-sS",
		"--fail-with-body",
		"-N",
		"--max-time",
		tostring(opts.timeout or 10),
		"-X",
		method,
		("http://127.0.0.1:%d%s"):format(hs.port, path),
	}
	vim.list_extend(args, auth_args(hs))

	local tmp
	if opts.body ~= nil then
		tmp = vim.fn.tempname()
		if vim.fn.writefile({ opts.body }, tmp) ~= 0 then
			vim.schedule(function()
				cb(nil, "写临时文件失败")
			end)
			return false
		end
		vim.list_extend(args, { "-H", "Content-Type: application/json", "--data-binary", "@" .. tmp })
	end

	local ok, proc = pcall(spawn, args, { text = true }, function(res)
		if tmp then
			pcall(vim.fn.delete, tmp)
		end
		vim.schedule(function()
			cb(res)
		end)
	end)
	if not ok then
		if tmp then
			pcall(vim.fn.delete, tmp)
		end
		vim.schedule(function()
			cb(nil, tostring(proc))
		end)
		return false
	end
	return proc ~= nil
end

---Fold an SSE body into what this backend cares about. The app writes `data: <json>`
---per event, with `id:` sequence lines; deltas carry text, `error`/`cancelled` are
---terminal failures, `turn_started` carries the ids used for cancel and replay.
---@param body string|nil
---@return table { turn?, session?, text, error?, cancelled?, ended, usage? }
local function fold_events(body)
	local out = { text = "", ended = false }
	for chunk in tostring(body or ""):gmatch("[^\r\n]+[\r\n]+[^\r\n]*") do
		-- chunks are separated by a blank line; accept both \n\n and \r\n\r\n
		local data = {}
		for line in (chunk .. "\n"):gmatch("([^\n]*)\n") do
			local value = line:match("^data:%s?(.*)$")
			if value then
				data[#data + 1] = value
			end
		end
		if #data > 0 then
			local ok, ev = pcall(vim.json.decode, table.concat(data, "\n"))
			if ok and type(ev) == "table" then
				local kind = ev.type
				if kind == "turn_started" then
					out.turn = ev.turn_id or out.turn
					out.session = ev.session_id or out.session
				elseif kind == "delta" then
					out.text = out.text .. (ev.text or "")
				elseif kind == "error" then
					out.error = ev.message or "agent 报错"
				elseif kind == "cancelled" then
					out.cancelled = true
					out.error = nil
				elseif kind == "done" then
					out.usage = ev.usage
				elseif kind == "end" then
					out.ended = true
				end
			end
		end
	end
	return out
end

---Record the outcome for the task that produced it (if `results = true`, the text is
---kept with the question; the task itself always leaves `running`).
---@param rec table
---@param status string "done" | "error"
local function settle_task(rec, status)
	local task_id = rec.task_id
	if not task_id then
		return
	end
	if status == "done" and rec.answer and rec.answer ~= "" then
		pcall(function()
			require("ask_agent.results").record({ task_id = task_id, text = rec.answer, ts = os.time() * 1000 })
		end)
	end
	pcall(function()
		require("ask_agent.state").complete_task(task_id, status)
	end)
end

---Finish a send: local state first (probe reads it), then the task bookkeeping.
---@param rec table
---@param state string
---@param msg string|nil
---@param task_status string|nil "done" | "error"; nil leaves the task alone
local function finish(rec, state, msg, task_status)
	rec.state = state
	rec.msg = msg
	rec.ts = os.time()
	if task_status then
		settle_task(rec, task_status)
	end
end

---Deliver already-rendered text. Returns immediately; the outcome lands in probe().
---@param target table
---@param text string
---@param opts { task_id?: string }|nil
---@return boolean ok, string? err
function M.send(target, text, opts)
	local hs = M.handshake()
	local port = (target and target.port) or (hs and hs.port)
	if not port then
		return false, "StudyDeck 没在运行"
	end
	local id = (target and target.id) or "deck"
	local cwd = (target and target.cwd) or vim.fn.getcwd()
	local origin = hs or { port = port }

	-- The app runs one turn per session (and a session is picked by cwd), so a second
	-- send would be rejected there anyway: refuse here, before the round trip.
	local prev = inflight[id]
	if prev and prev.state == "working" then
		return false, "上一轮还在运行（先 :AskAgentCancel 或等它结束）"
	end

	-- A new table identity per send: a late callback from a superseded send can still
	-- settle its own task, but it cannot overwrite the state of the current one.
	local rec = {
		state = "working",
		ts = os.time(),
		task_id = opts and opts.task_id,
		cwd = cwd,
	}
	inflight[id] = rec

	local body = vim.json.encode({ text = text, cwd = cwd })
	request(origin, "POST", "/api/ask", {
		body = body,
		timeout = 1800,
		cb = function(res, spawn_err)
			if not res then
				finish(rec, "error", spawn_err or "无法启动 curl", "error")
				return
			end
			if res.code ~= 0 then
				finish(rec, "error", err_text(res), "error")
				return
			end
			local folded = fold_events(res.stdout)
			rec.turn = folded.turn or rec.turn
			rec.session = folded.session or rec.session
			rec.answer = folded.text
			rec.usage = folded.usage
			if rec.session and rec.cwd then
				sessions[rec.cwd] = rec.session
			end
			if folded.error then
				finish(rec, "error", folded.error, "error")
			elseif folded.cancelled then
				-- the user asked for it: not a failure, just an ending without an answer
				finish(rec, "idle", "已取消", "done")
			elseif not folded.ended then
				finish(rec, "error", "连接中断：没收到 end 事件", "error")
			else
				finish(rec, "done", nil, "done")
			end
		end,
	})

	return true
end

---Which of the app's running turns belongs to this target's session?
---@param target table
---@return table|nil
local function remote_turn(target)
	local cwd = target and target.cwd
	local sid = cwd and sessions[cwd]
	for _, turn in ipairs(remote.turns) do
		if turn.state == "running" and (not sid or turn.session_id == sid) then
			return turn
		end
	end
	return nil
end

---Refresh the cached `GET /api/turns?active=1` in the background (cheap + at most REMOTE_TTL).
---@param hs table
local function refresh_remote(hs)
	if remote.fetching or now_ms() - remote.at < REMOTE_TTL then
		return
	end
	remote.fetching = true
	request(hs, "GET", "/api/turns?active=1", {
		timeout = 3,
		cb = function(res)
			remote.fetching = false
			remote.at = now_ms()
			if not res or res.code ~= 0 then
				remote.turns = {}
				return
			end
			local ok, obj = pcall(vim.json.decode, res.stdout or "")
			if ok and type(obj) == "table" and type(obj.turns) == "table" then
				remote.turns = obj.turns
			else
				remote.turns = {}
			end
		end,
	})
end

---Ask the app to stop a running turn. Resolution order: the turn this nvim started,
---then whatever `GET /api/turns` reports for this target's session.
---@param target table
---@param cb fun(ok: boolean, err: string|nil)|nil
---@return boolean started, string? err
function M.cancel(target, cb)
	cb = cb or function() end
	local hs = M.handshake()
	if not hs then
		return false, "StudyDeck 没在运行"
	end
	local id = (target and target.id) or "deck"
	local rec = inflight[id]

	local function post(turn_id)
		request(hs, "POST", "/api/turns/" .. turn_id .. "/cancel", {
			timeout = 5,
			cb = function(res, spawn_err)
				if not res then
					cb(false, spawn_err or "无法启动 curl")
				elseif res.code ~= 0 then
					cb(false, err_text(res))
				else
					cb(true)
				end
			end,
		})
	end

	if rec and rec.turn then
		post(rec.turn)
		return true
	end
	if not M.supports("turns") then
		return false, "这个 StudyDeck 版本不支持取消"
	end
	request(hs, "GET", "/api/turns?active=1", {
		timeout = 3,
		cb = function(res)
			if not res then
				cb(false, "无法启动 curl")
				return
			end
			if res.code ~= 0 then
				cb(false, err_text(res))
				return
			end
			local ok, obj = pcall(vim.json.decode, res.stdout or "")
			local turns = ok and type(obj) == "table" and type(obj.turns) == "table" and obj.turns or {}
			local found = nil
			for _, turn in ipairs(turns) do
				if turn.state == "running" then
					found = found or turn
					local sid = (target and target.cwd) and sessions[target.cwd]
					if not sid or turn.session_id == sid then
						found = turn
						break
					end
				end
			end
			if not found then
				cb(false, "没有正在运行的轮次")
				return
			end
			post(found.id)
		end,
	})
	return true
end

---Live state for pickers, the dashboard and the state layer.
---Done/error are reported explicitly (the state layer does not have to infer them),
---and a turn the app itself is running shows up as working as well.
---@param target table
---@return table
function M.probe(target)
	local id = (target and target.id) or "deck"
	local rec = inflight[id]
	if rec then
		if rec.state == "working" then
			return { running = true, state = "working", explicit = true }
		end
		if rec.state == "idle" and rec.msg then
			-- report the reason once, then let the remote snapshot take over again
			local msg = rec.msg
			rec.msg = nil
			return { running = true, state = "idle", msg = msg, explicit = true }
		end
		if rec.state == "error" then
			-- report once, then fall back to idle so a single failure does not stick
			local msg = rec.msg
			rec.state = "idle"
			rec.msg = nil
			return { running = true, state = "error", msg = msg, explicit = true }
		end
	end
	local hs = M.handshake()
	if hs and not alive(hs.pid) then
		return { running = false }
	end
	-- A turn the app itself is running outranks our own last outcome: the dashboard
	-- should say working even when this nvim's previous turn is still unread.
	if hs and hs.caps.turns then
		refresh_remote(hs)
		if remote_turn(target) then
			return { running = true, state = "working", explicit = true }
		end
	end
	if rec and rec.state == "done" then
		return { running = true, state = "done", explicit = true }
	end
	return { running = true, state = "idle", explicit = true }
end

return M
