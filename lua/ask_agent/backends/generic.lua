-- lua/ask_agent/backends/generic.lua
---@brief Generic backend factory: to hook up opencode / claude code / codex or
---anything else later, all you need is that it already runs inside a tmux pane.
--
-- Adding a new agent (no new file, no changes to the rest of the plugin):
--
--   1  local ai = require("ask_agent")
--   2  local generic = require("ask_agent.backends.generic")
--   3  ai.setup({
--   4    default = "pi",
--   5    extra = {
--   6      generic.tmux({ id = "opencode", label = "opencode",
--   7                      panes = generic.tmux_panes_by_cmd("opencode") }),
--   8      generic.tmux({ id = "claude", label = "claude",
--   9                      panes = generic.tmux_panes_by_cmd("claude") }),
--  10    },
--  11  })
--
-- "Is it busy?" is the one thing tmux cannot tell you cheaply. Two zero-plugin-code ways:
--
--   * the agent's own hooks write a marker file and you read it with `generic.state_file()`:
--       local busy = generic.state_file("~/.cache/ask-agent/claude", { field = "cwd" })
--       generic.tmux({ id = "claude", panes = ..., busy = busy })
--   * obviously fragile: screen scraping with `generic.tmux_panes(match)` + your own `busy`.
--
-- For a backend that is not tmux-based, write `lua/ask_agent/backends/<name>.lua`
-- instead; see the provider contract in `lua/ask_agent/backends/init.lua`.
--
-- Deliberately limited to one transport: "deliver to an already running
-- process". Spawning children, reading stdout, echoing replies and session
-- management are all out of scope here -- that is codecompanion's job (ACP
-- adapters included); do not build it twice.

local M = {}

---Generic backend: type the text plus a carriage return into a tmux pane.
---Uses load-buffer/paste-buffer instead of send-keys so multi-line text is not
---turned into several Enters and shell/quote escaping never gets involved.
---@param opts { id: string, label: string, panes: fun(): table[], keys_after?: string, icon?: string,
---              busy?: fun(target: table): boolean?, string? }
---@return table backend
function M.tmux(opts)
	local id, label = opts.id, opts.label
	local keys_after = opts.keys_after or "Enter"

	local function tmux(args, stdin)
		local ok, res = pcall(function()
			return vim.system({ "tmux", unpack(args) }, { text = true, stdin = stdin }):wait()
		end)
		if not ok then
			return false, tostring(res)
		end
		if res.code ~= 0 then
			return false, (res.stderr or ""):gsub("%s+$", "")
		end
		return true
	end

	local backend = {
		id = id,
		label = label,
		-- defaults to nf-fa-terminal (U+F120)
		icon = opts.icon or require("ask_agent.icons").find(opts.id) or require("ask_agent.icons").get("generic"),
		targets = function()
			local ok, list = pcall(opts.panes)
			return ok and list or {}
		end,
	}

	-- The panes() factory may carry the command pattern it filters on (tmux_panes_by_cmd),
	-- so the picker can tell "pane still runs the agent" from "pane fell back to the shell".
	local pattern = type(opts.panes) == "table" and opts.panes.pattern or nil

	---Live check used by the picker: pane still exists, is not dead, and still runs the agent.
	---@param target table
	---@return { running: boolean, detail?: string }
	function backend.probe(target)
		local ok, res = pcall(function()
			return vim.system({
				"tmux",
				"display-message",
				"-p",
				"-t",
				target.pane,
				"-F",
				"#{pane_dead}\t#{pane_current_command}",
			}, { text = true }):wait()
		end)
		if not ok or res.code ~= 0 then
			return { running = false, detail = "pane gone" }
		end
		local dead, cmd = (res.stdout or ""):match("^(%d)\t?(.*)")
		if not dead then
			return { running = false, detail = "pane not found" }
		end
		if dead == "1" then
			return { running = false, detail = "pane dead" }
		end
		if pattern and cmd and cmd ~= "" and not cmd:find(pattern) then
			return { running = false, detail = ("pane runs %s"):format(cmd) }
		end
		-- Busy/state is opt-in and never fatal: a hook that has not written anything
		-- yet just means "unknown". The hook may return `true, detail` (busy) or a
		-- table with the richer OSC 7501 shape: { state, kind, progress, msg }.
		if type(opts.busy) == "function" then
			local okb, hook, why = pcall(opts.busy, target)
			if okb and type(hook) == "table" and type(hook.state) == "string" then
				return {
					running = true,
					state = hook.state,
					kind = hook.kind,
					progress = hook.progress,
					msg = hook.msg or hook.detail,
					detail = hook.detail,
				}
			end
			if okb and hook == true then
				return { running = true, busy = true, detail = why or "busy" }
			end
		end
		return { running = true, detail = cmd ~= "" and cmd or nil }
	end

	function backend.send(target, text)
		local buffer = ("ai-ask-%s"):format(id)
		local ok, err = tmux({ "load-buffer", "-b", buffer, "-" }, text)
		if not ok then
			return false, ("tmux load-buffer failed: %s"):format(err)
		end
		ok, err = tmux({ "paste-buffer", "-b", buffer, "-d", "-t", target.pane })
		if not ok then
			return false, ("tmux paste-buffer failed: %s"):format(err)
		end
		ok, err = tmux({ "send-keys", "-t", target.pane, keys_after })
		if not ok then
			return false, ("tmux send-keys failed: %s"):format(err)
		end
		return true
	end

	return backend
end

---Helper: list every tmux pane matching a predicate, as a panes() factory.
---More flexible than `tmux_panes_by_cmd` when the agent runs under a wrapper
---(node/python) or you want to match on the pane title instead of the command.
---@param match fun(pane: { id: string, command: string, cwd: string, title: string }): boolean
---@return fun(): table[]
function M.tmux_panes(match)
	return function()
		local ok, res = pcall(function()
			return vim.system({
				"tmux",
				"list-panes",
				"-a",
				"-F",
				"#{pane_id}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_title}",
			}, { text = true }):wait()
		end)
		if not ok or res.code ~= 0 then
			return {}
		end
		local out = {}
		for line in (res.stdout or ""):gmatch("[^\n]+") do
			local pane, command, cwd, title = line:match("^(%S+)\t([^\t]*)\t([^\t]*)\t(.*)$")
			if pane and match({ id = pane, command = command, cwd = cwd, title = title }) then
				table.insert(out, { id = pane, label = pane, pane = pane, cwd = cwd })
			end
		end
		return out
	end
end

---Slug for state-file names: stable, filesystem-safe, and reproducible from a shell hook.
---"/Users/me/proj/a" -> "_Users_me_proj_a"
---@param s string
---@return string
function M.slug(s)
	return (tostring(s):gsub("[^%w%-%._]", "_"))
end

---Read a "this instance is busy" marker written by the agent's own hook.
---
---File layout: `<dir>/<slug(key)>.json`, written by the hook, e.g.
---  echo '{"busy":true}' > ~/.cache/ask-agent/claude/_Users_me_proj.json
---Anything missing/unreadable/without `busy: true` counts as "not busy" (nil), so a
---crashed hook can never block sending. `ttl` (seconds, default 3600) turns stale markers
---into "unknown" so a killed session does not look busy forever.
---
---@param dir string directory (a leading ~ and env vars are expanded)
---@param opts? { field?: "id"|"cwd"|fun(target: table): string, ttl?: integer }
---@return fun(target: table): boolean?, string?
function M.state_file(dir, opts)
	opts = opts or {}
	local field = opts.field or "cwd"
	local ttl = opts.ttl or 3600
	dir = vim.fs.normalize(vim.fn.expand(dir))
	local function key_of(target)
		if type(field) == "function" then
			return field(target)
		end
		return target[field] or target.id or target.pane
	end
	return function(target)
		local key = key_of(target)
		if not key then
			return nil
		end
		local file = ("%s/%s.json"):format(dir, M.slug(key))
		local stat = vim.uv.fs_stat(file)
		if not stat then
			return nil
		end
		if ttl > 0 and os.time() - (stat.mtime.sec or 0) > ttl then
			return nil
		end
		local ok, text = pcall(vim.fn.readfile, file)
		if not ok or type(text) ~= "table" then
			return nil
		end
		local okj, data = pcall(vim.json.decode, table.concat(text, "\n"))
		if not okj or type(data) ~= "table" then
			return nil
		end
		-- `{"state":"blocked","kind":"permission","msg":"run the tests?"}` is the rich
		-- form; `{"busy":true}` the minimal one. Both are written by agent hooks.
		if type(data.state) == "string" then
			return {
				state = data.state,
				kind = data.kind,
				progress = data.progress,
				msg = data.msg,
				detail = data.detail,
			}
		end
		if data.busy == true then
			return true, data.detail or "busy (hook)"
		end
		return nil
	end
end

---Helper: filter tmux panes by command name and return a panes() factory.
---For example tmux_panes_by_cmd("opencode") yields one target per pane currently
---running opencode.
---@param pattern string Lua pattern matched against pane_current_command
---@return fun(): table[] callable table that also carries `pattern` (used by the probe)
function M.tmux_panes_by_cmd(pattern)
	local panes = function()
		local ok, res = pcall(function()
			return vim.system({
				"tmux",
				"list-panes",
				"-a",
				"-F",
				"#{pane_id}\t#{pane_current_command}\t#{pane_current_path}",
			}, { text = true }):wait()
		end)
		if not ok or res.code ~= 0 then
			return {}
		end
		local out = {}
		for line in (res.stdout or ""):gmatch("[^\n]+") do
			local pane, command, path = line:match("^(%S+)\t(%S+)\t(.*)$")
			if pane and command and command:find(pattern) then
				table.insert(out, { id = pane, label = pane, pane = pane, cwd = path })
			end
		end
		return out
	end
	return setmetatable({ pattern = pattern }, {
		__call = function()
			return panes()
		end,
	})
end

return M
