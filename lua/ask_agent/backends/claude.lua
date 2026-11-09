-- lua/ask_agent/backends/claude.lua
---@brief Claude Code backend: tmux panes found by command name, busy state read
---from the marker files its hooks write.
--
-- Claude Code runs as a normal TUI in a tmux pane, so delivery is the generic
-- paste+enter path. The one thing tmux cannot answer is "is it thinking?", and
-- Claude Code has no place to ask -- hooks do. Install the companion script and
-- these hooks (see README, "Busy / idle"), then:
--
--   require("ask_agent").setup({ extra = { require("ask_agent.backends.claude").new() } })
--
-- Everything else (picker, status dots, queueing notice, batch sends) is core.

local generic = require("ask_agent.backends.generic")

local M = {}

---Default marker directory: $XDG_CACHE_HOME/ask-agent/claude (~/.cache/ask-agent/claude).
---@return string
function M.default_state_dir()
	local base = vim.env.XDG_CACHE_HOME
	if not base or base == "" then
		base = vim.fs.joinpath(vim.env.HOME or "~", ".cache")
	end
	return vim.fs.joinpath(base, "ask-agent", "claude")
end

---Build the backend.
---@param opts? { id?: string, label?: string, command?: string, command_pattern?: string,
---               state_dir?: string, field?: "id"|"cwd"|fun(target: table): string,
---               ttl?: integer, keys_after?: string }
---@return table backend
function M.new(opts)
	opts = opts or {}
	local panes = opts.command_pattern and generic.tmux_panes(opts.command_pattern)
		or generic.tmux_panes_by_cmd(opts.command or "claude")
	return generic.tmux({
		id = opts.id or "claude",
		label = opts.label or "Claude Code",
		panes = panes,
		keys_after = opts.keys_after,
		-- Hooks write {"busy": true} keyed by cwd; missing markers simply mean "unknown",
		-- so a machine without the hooks installed still works (everything shows as idle).
		busy = generic.state_file(opts.state_dir or M.default_state_dir(), {
			field = opts.field or "cwd",
			ttl = opts.ttl,
		}),
	})
end

return M
