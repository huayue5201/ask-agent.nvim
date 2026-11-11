-- lua/ask_agent/backends/pi.lua
---@brief pi backend: writes one line of JSON to the unix socket of a pi instance
---running in a terminal.
--
-- Contract (pi side: extensions/nvim-context.ts):
--   ~/.cache/pi-agent/ask/<pid>.sock   unix socket, receives one JSON line {"text": "..."}
--   ~/.cache/pi-agent/ask/<pid>.json   registry {pid, sock, cwd, ts, embedded, busy}
--     `busy` is rewritten by the extension on agent_start/agent_settled, so nvim can
--     tell "idle" from "processing a task"; messages sent while busy are queued by pi
--     as follow-ups instead of interrupting the current tool chain.
-- `embedded=true` means this pi runs as `pi --mode rpc` (started and owned by an
-- ACP client such as codecompanion): messages sent to it only go back to that
-- client, never to nvim. Such instances are excluded from cwd matching by
-- default (see `avoid` in backends/init.lua).
-- The text is rendered on the nvim side; pi only has to sendUserMessage it into
-- its own session.

local M = { id = "pi", label = "pi" }
local notify = require("ask_agent.notify")

-- The icon is not hardcoded here: pickers and notifications resolve it from the
-- backend id / instance id in ask_agent/icons.lua (pi = π), and it can be
-- overridden via ai.setup({ icons = { pi = ... } }).

local function ask_dir()
	local cache = os.getenv("XDG_CACHE_HOME") or (os.getenv("HOME") .. "/.cache")
	return cache .. "/pi-agent/ask"
end

---Is the pid still alive? uv.kill(pid, 0) only probes, returning true means
---alive; EPERM means the process exists but we may not signal it, which also
---counts as alive.
---@param pid integer|nil
---@return boolean
local function alive(pid)
	if not pid or pid <= 0 then
		return false
	end
	local ok, res, err_name = pcall(vim.uv.kill, pid, 0)
	if ok and res then
		return true
	end
	return ok and err_name == "EPERM"
end

---Read the registry directory once; split entries into live and exited instances (most recent first).
---Dead entries are kept so the picker can show "not running" instead of silently hiding them.
---@return table[] live, table[] dead
local function scan()
	local dir = ask_dir()
	local live, dead = {}, {}
	if vim.fn.isdirectory(dir) == 0 then
		return live, dead
	end
	for _, name in ipairs(vim.fn.readdir(dir) or {}) do
		if name:match("%.json$") then
			local ok, entry = pcall(function()
				return vim.json.decode(table.concat(vim.fn.readfile(dir .. "/" .. name), "\n"))
			end)
			if ok and type(entry) == "table" and entry.sock then
				-- Only live pids are usable (uv.kill avoids a subprocess: ~0.001ms vs
				-- ~1.9ms for vim.fn.system). Note uv.kill does not throw; its
				-- return value is the result: true when alive, nil + "ESRCH" when
				-- dead. When we may not signal the process it is nil + "EPERM"
				-- (also alive). Never use pcall's success to decide liveness --
				-- that was the old bug that kept dead instances in the list.
				local pid_alive = alive(tonumber(entry.pid))
				local embedded = entry.embedded == true
				local t = {
					id = tostring(entry.pid),
					label = ("pid %s%s"):format(entry.pid, embedded and " (acp)" or ""),
					cwd = entry.cwd,
					sock = entry.sock,
					ts = entry.ts or 0,
					embedded = embedded,
					-- When running inside rex, carry {session, block}: the map
					-- picker uses it to draw this instance in the right cell of
					-- the terminal layout (older pi versions do not write it,
					-- so it stays nil)
					rex = type(entry.rex) == "table" and entry.rex or nil,
					-- true while a turn is running: a question sent now is queued
					-- as a follow-up, not answered immediately
					busy = entry.busy == true,
					avoid = embedded
							and "embedded pi (driven by codecompanion/ACP): replies only appear in that chat buffer"
						or nil,
				}
				table.insert(pid_alive and live or dead, t)
			end
		end
	end
	table.sort(live, function(a, b)
		return a.ts > b.ts
	end)
	table.sort(dead, function(a, b)
		return a.ts > b.ts
	end)
	return live, dead
end

---Live pi instances (most recent first). These are the only sendable targets.
---@return table[]
function M.targets()
	local live = scan()
	return live
end

---Registry entries whose process is gone: shown greyed out by the picker, never sent to.
---@return table[]
function M.stale_targets()
	local _, dead = scan()
	return dead
end

---Is the instance still there, and is it free? Re-checked when the picker opens, because
---an instance can exit between listing and choosing.
---@param target table
---@return { running: boolean, busy?: boolean, detail?: string }
function M.probe(target)
	if not alive(tonumber(target.id)) then
		return { running = false, detail = "process exited" }
	end
	if target.sock and vim.uv.fs_stat(target.sock) == nil then
		return { running = false, detail = "socket missing" }
	end
	-- busy is carried by the listing; re-read the registry so a turn that started
	-- (or settled) while the picker was open is reflected
	local busy = target.busy == true
	local ok, entry = pcall(function()
		local path = ask_dir() .. "/" .. tostring(target.id) .. ".json"
		return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
	end)
	if ok and type(entry) == "table" then
		busy = entry.busy == true
	end
	if busy then
		return { running = true, busy = true, detail = "busy" }
	end
	return { running = true }
end

function M.available()
	if #M.targets() > 0 then
		return true
	end
	return false, "no live pi (start `pi` in a terminal; the extension registers its socket automatically)"
end

---@param target table
---@param text string
---@return boolean ok, string? err
function M.send(target, text)
	local ok, chan = pcall(vim.fn.sockconnect, "pipe", target.sock, {
		rpc = false,
		-- Receive the ack asynchronously: warn on write failures (e.g. the
		-- instance just died) without blocking the UI
		on_data = function(_, data)
			local line = data and data[1] or ""
			if line:find('"ok":false', 1, true) then
				vim.schedule(function()
					notify.notify("[pi] send failed: " .. line, vim.log.levels.WARN)
				end)
			end
		end,
	})
	if not ok or chan == 0 then
		return false, ("cannot connect to pi socket: %s (the instance may have exited)"):format(target.sock)
	end
	vim.fn.chansend(chan, vim.json.encode({ text = text }) .. "\n")
	-- keep the channel open long enough for the ack; does not block nvim
	vim.defer_fn(function()
		pcall(vim.fn.chanclose, chan)
	end, 1500)
	return true
end

return M
