-- lua/ask_agent/backends/pi.lua
---@brief pi backend: writes one line of JSON to the unix socket of a pi instance
---running in a terminal.
--
-- Contract (pi side: extensions/nvim-context.ts):
--   ~/.cache/pi-agent/ask/<pid>.sock   unix socket, receives one JSON line {"text": "..."}
--   ~/.cache/pi-agent/ask/<pid>.json   registry {pid, sock, cwd, ts, embedded}
-- `embedded=true` means this pi runs as `pi --mode rpc` (started and owned by an
-- ACP client such as codecompanion): messages sent to it only go back to that
-- client, never to nvim. Such instances are excluded from cwd matching by
-- default (see `avoid` in backends/init.lua).
-- The text is rendered on the nvim side; pi only has to sendUserMessage it into
-- its own session.

local M = { id = "pi", label = "pi" }

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

---Scan the registry directory and return live pi instances (most recent first).
---@return table[]
function M.targets()
	local dir = ask_dir()
	local out = {}
	if vim.fn.isdirectory(dir) == 0 then
		return out
	end
	for _, name in ipairs(vim.fn.readdir(dir) or {}) do
		if name:match("%.json$") then
			local ok, entry = pcall(function()
				return vim.json.decode(table.concat(vim.fn.readfile(dir .. "/" .. name), "\n"))
			end)
			if ok and type(entry) == "table" and entry.sock then
				-- Only accept live pids (uv.kill avoids a subprocess: ~0.001ms vs
				-- ~1.9ms for vim.fn.system). Note uv.kill does not throw; its
				-- return value is the result: true when alive, nil + "ESRCH" when
				-- dead. When we may not signal the process it is nil + "EPERM"
				-- (also alive). Never use pcall's success to decide liveness --
				-- that was the old bug that kept dead instances in the list.
				if alive(tonumber(entry.pid)) then
					local embedded = entry.embedded == true
					table.insert(out, {
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
						avoid = embedded
								and "embedded pi (driven by codecompanion/ACP): replies only appear in that chat buffer"
							or nil,
					})
				end
			end
		end
	end
	table.sort(out, function(a, b)
		return a.ts > b.ts
	end)
	return out
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
					vim.notify("[pi] send failed: " .. line, vim.log.levels.WARN)
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
