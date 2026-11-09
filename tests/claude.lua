-- tests/claude.lua — the bundled Claude Code backend + the hook contract it relies on
-- Run from the repo root: nvim --headless --clean -l tests/claude.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local cache = vim.fn.tempname() .. "-xdg"
vim.fn.mkdir(vim.fs.joinpath(cache, "ask-agent", "claude"), "p")
vim.env.XDG_CACHE_HOME = cache

local claude = require("ask_agent.backends.claude")
assert(claude.default_state_dir() == vim.fs.joinpath(cache, "ask-agent", "claude"), claude.default_state_dir())

local orig_system = vim.system
vim.system = function(cmd)
	local sub = cmd[2]
	local out = ""
	if sub == "display-message" then
		out = "0\tclaude"
	elseif sub == "list-panes" then
		out = "%7\tclaude\t/tmp/proj\tclaude\t2\n%8\tzsh\t/tmp\tzsh\t2\n"
	end
	return {
		wait = function()
			return { code = 0, stdout = out, stderr = "" }
		end,
	}
end

local be = claude.new()
assert(be.id == "claude" and be.label == "Claude Code", "id/label")
local targets = be.targets()
assert(#targets == 1 and targets[1].pane == "%7", "only claude panes are targets")

local t = targets[1]
local idle = be.probe(t)
assert(idle.running and not idle.busy, "no marker = idle, got busy=" .. tostring(idle.busy))

-- What the hook script does: <state_dir>/<slug(cwd)>.json
local generic = require("ask_agent.backends.generic")
local marker = vim.fs.joinpath(cache, "ask-agent", "claude", generic.slug(t.cwd) .. ".json")
vim.fn.writefile({ '{"busy":true,"detail":"turn running"}' }, marker)
local busy = be.probe(t)
assert(busy.running and busy.busy == true, "hook marker should make the target busy")
assert(busy.detail == "turn running", "hook detail should be surfaced: " .. tostring(busy.detail))

vim.fn.writefile({ '{"busy":false}' }, marker)
assert(not be.probe(t).busy, "idle marker = idle")

-- A stale marker (crashed session) must not look busy forever.
vim.fn.writefile({ '{"busy":true}' }, marker)
local old = os.time() - 7200
vim.uv.fs_utime(marker, old, old)
assert(not be.probe(t).busy, "marker older than ttl = unknown")

-- Options: custom command/label/state dir still build a working backend.
vim.system = function(cmd)
	local out = cmd[2] == "display-message" and "0\topencode" or "%9\topencode\t/tmp\topencode\t2\n"
	return {
		wait = function()
			return { code = 0, stdout = out, stderr = "" }
		end,
	}
end
local custom = claude.new({ id = "oc", label = "opencode", command = "opencode", state_dir = "/tmp/none" })
assert(custom.id == "oc" and #custom.targets() == 1, "custom command should list its panes")
vim.system = orig_system
print("CLAUDE OK")
