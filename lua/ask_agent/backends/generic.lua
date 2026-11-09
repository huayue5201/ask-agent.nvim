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
---@param opts { id: string, label: string, panes: fun(): table[], keys_after?: string, icon?: string }
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
