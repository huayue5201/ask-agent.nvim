-- tests/backends.lua — reference for extending ask-agent.nvim
-- Run from the repo root: nvim --headless --clean -l tests/backends.lua
-- Covers: the generic tmux factory (with a stubbed tmux), hook-written busy markers,
-- pane discovery helpers, and how little a hand-written backend actually needs.
vim.opt.runtimepath:prepend(vim.fn.getcwd()) -- run from the repo root
local g = require("ask_agent.backends.generic")

-- 1. state_file: reads <dir>/<slug(cwd)>.json, skips invalid / ttl-expired markers
local dir = vim.fn.tempname() .. "-states"
vim.fn.mkdir(dir, "p")
local target = { id = "1", cwd = "/Users/me/proj", pane = "%1" }
local busy = g.state_file(dir, { field = "cwd", ttl = 3600 })
assert(busy(target) == nil, "missing marker = unknown")
local f = dir .. "/" .. g.slug(target.cwd) .. ".json"
vim.fn.writefile({ '{"busy":true,"detail":"running turn"}' }, f)
local b, why = busy(target)
assert(b == true and why == "running turn", "marker should report busy: " .. tostring(b) .. " " .. tostring(why))
vim.fn.writefile({ '{"busy":false}' }, f)
assert(busy(target) == nil, "busy=false = not busy")
vim.fn.writefile({ "not json" }, f)
assert(busy(target) == nil, "broken marker must not block sending")
vim.fn.writefile({ '{"busy":true}' }, f)
local old = os.time() - 7200
vim.uv.fs_utime(f, old, old)
assert(busy(target) == nil, "expired marker (ttl) = unknown")
-- field = function
local by_id = g.state_file(dir, {
	field = function(t)
		return t.pane
	end,
})
vim.fn.writefile({ '{"busy":true}' }, dir .. "/" .. g.slug("%1") .. ".json")
assert(by_id(target) == true, "field callable should be used as key")

-- 2. tmux factory: busy hook is merged into probe; tmux itself is stubbed
local orig_system = vim.system
vim.system = function(cmd, o)
	local sub = cmd[2]
	local out = ""
	if sub == "display-message" then
		out = "0\tclaude"
	elseif sub == "list-panes" then
		out = "%1\tclaude\t/Users/me/proj\tclaude: proj\t2\n%2\tnode\t/tmp\tother\t2\n"
	end
	return {
		wait = function()
			return { code = 0, stdout = out, stderr = "" }
		end,
	}
end
local be = g.tmux({ id = "claude", label = "Claude", panes = g.tmux_panes_by_cmd("claude"), busy = busy })
be.id, be.label = "claude", "Claude"
local t2 = { id = "1", cwd = "/Users/me/proj", pane = "%1" }
assert(#be.targets() == 1 and be.targets()[1].pane == "%1", "pattern filter should keep the claude pane")
vim.fn.writefile({ '{"busy":true}' }, dir .. "/" .. g.slug(t2.cwd) .. ".json")
local st = be.probe(t2)
assert(st.running and st.busy == true, "probe should surface the hook marker")
vim.fn.writefile({ '{"busy":false}' }, dir .. "/" .. g.slug(t2.cwd) .. ".json")
local st2 = be.probe(t2)
assert(st2.running and not st2.busy, "probe: idle when the marker says so")

-- 3. tmux_panes(match): match on title, not just command from the pane list
local panes = g.tmux_panes(function(p)
	return p.title:find("proj") ~= nil
end)()
assert(#panes == 1 and panes[1].pane == "%1", "tmux_panes should filter by predicate")
assert(#g.tmux_panes_by_cmd("claude")() == 1, "tmux_panes_by_cmd fixture sanity")

-- 4. a 12-line hand-written backend is enough: registered, probed, picked
vim.system = orig_system
local sent = {}
local custom = {
	id = "custom",
	label = "custom",
	icon = "",
	targets = function()
		return { { id = "x", label = "x", cwd = vim.fn.getcwd() } }
	end,
	probe = function()
		return { running = true }
	end,
	send = function(t, text)
		sent[#sent + 1] = text
		return true
	end,
}
require("ask_agent.backends").register(custom)
local b = require("ask_agent.backends")
local cands = b.candidates(custom, vim.fn.getcwd())
assert(#cands == 1 and cands[1].tier == 1, "custom backend should produce a cwd-tier candidate")
local okb = b.status(custom)
assert(okb == true, "custom backend should be usable")
custom.send(cands[1].target, "hello")
assert(sent[1] == "hello", "custom send should receive the text")
print("EXT OK")
