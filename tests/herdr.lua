-- tests/herdr.lua — the herdr backend and its jump adapter, with herdr stubbed
-- Run from the repo root: nvim --headless --clean -l tests/herdr.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local calls = {}
local reply = nil

local function agents_json(list)
	return vim.json.encode({ id = "cli:agent:list", result = { type = "agent_list", agents = list } })
end

local function agent(name, status, extra)
	local a = {
		agent = "pi",
		agent_status = status,
		cwd = "/tmp/proj",
		foreground_cwd = "/tmp/proj",
		name = name,
		pane_id = "w1:p" .. #name,
		terminal_title_stripped = "π - proj",
		workspace_id = "w1",
		tab_id = "w1:t1",
	}
	return vim.tbl_extend("force", a, extra or {})
end

-- Stub the CLI: record argv, answer with whatever the test queued.
local real_system, real_exec = vim.system, vim.fn.executable
vim.fn.executable = function(name)
	return name == "herdr" and 1 or 0
end
vim.system = function(cmd, _, cb)
	calls[#calls + 1] = cmd
	local res = { code = 0, stdout = reply(cmd) or "", stderr = "" }
	if cb then
		cb(res)
		return {}
	end
	return {
		wait = function()
			return res
		end,
	}
end

reply = function()
	return agents_json({ agent("alpha", "working"), agent("beta", "blocked") })
end

local herdr = require("ask_agent.backends.herdr")

-- 1. targets: one per live agent, carrying the herdr sub-table the viewer and
--    the jump adapter look for
local targets = herdr.targets()
assert(#targets == 2, "two agents: " .. #targets)
assert(targets[1].id == "alpha" and targets[1].label == "alpha", "target id/label")
assert(targets[1].cwd == "/tmp/proj", "target cwd")
assert(targets[1].herdr.agent == "alpha", "herdr spec (agent)")
assert(targets[1].herdr.pane == "w1:p5", "herdr spec (pane): " .. tostring(targets[1].herdr.pane))
assert(targets[1].kind == "pi", "which agent it is")
assert(calls[1][1] == "herdr" and calls[1][2] == "agent" and calls[1][3] == "list", "list argv")
assert(vim.deep_equal(calls[1], { "herdr", "agent", "list" }), "exact list argv: " .. vim.inspect(calls[1]))

-- 2. one list per TTL: targets() and probe() share the pass
local n = #calls
herdr.targets()
herdr.probe(targets[1])
assert(#calls == n, "cached list, no extra CLI call")

-- 3. probe: herdr's vocabulary is ours, and blocked says why
local by_id = {}
for _, t in ipairs(targets) do
	by_id[t.id] = t
end
assert(herdr.probe(by_id.alpha).state == "working", "working")
assert(herdr.probe(by_id.alpha).busy == true, "working is busy")
local blocked = herdr.probe(by_id.beta)
assert(blocked.state == "blocked", "blocked")
assert(
	type(blocked.detail) == "string" and blocked.detail:find("approval", 1, true),
	"blocked should say why: " .. tostring(blocked.detail)
)

-- 4. done / idle / unknown pass through; unknown means "no opinion"
herdr.invalidate()
reply = function()
	return agents_json({
		agent("alpha", "done"),
		agent("beta", "idle"),
		agent("gamma", "unknown"),
		agent("delta", "garbage"),
	})
end
assert(herdr.probe({ herdr = { agent = "alpha" } }).state == "done", "done")
assert(herdr.probe({ herdr = { agent = "beta" } }).state == "idle", "idle")
local unknown = herdr.probe({ herdr = { agent = "gamma" } })
assert(unknown.running and unknown.state == nil, "unknown = running, no state")
assert(herdr.probe({ herdr = { agent = "delta" } }).state == nil, "unrecognised state is unknown")

-- 5. send: one prompt, and an agent_blocked answer is turned into something a
--    human can act on
herdr.invalidate()
reply = function()
	return agents_json({ agent("alpha", "idle") })
end
local ok, err = herdr.send({ herdr = { agent = "alpha" } }, "fix the tests")
assert(ok, "send succeeds: " .. tostring(err))
local last = calls[#calls]
assert(
	vim.deep_equal(last, { "herdr", "agent", "prompt", "alpha", "fix the tests" }),
	"prompt argv: " .. vim.inspect(last)
)
herdr.invalidate()
reply = function(cmd)
	if cmd[3] == "prompt" then
		return ""
	end
	return agents_json({ agent("alpha", "idle") })
end
vimsys_error = { code = 1, stdout = "", stderr = '{"error":{"code":"agent_blocked"}}' }
local broke = false
local saved = vim.system
vim.system = function(cmd, _, cb)
	calls[#calls + 1] = cmd
	local res = cmd[3] == "prompt" and vimsys_error or { code = 0, stdout = reply(cmd), stderr = "" }
	if cb then
		cb(res)
		return {}
	end
	return {
		wait = function()
			return res
		end,
	}
end
local sent, why = herdr.send({ herdr = { agent = "alpha" } }, "hello")
assert(not sent, "blocked send must fail")
assert(why and why:find("blocked", 1, true), "blocked send message: " .. tostring(why))
broke = true
vim.system = saved

-- 6. available() and the optional filter
assert(herdr.available(), "herdr is on PATH")
local keep = function(a)
	return a.name ~= "beta"
end
herdr.filter = keep
herdr.invalidate()
reply = function()
	return agents_json({ agent("alpha", "idle"), agent("beta", "idle") })
end
local picked = herdr.targets()
assert(#picked == 1 and picked[1].id == "alpha", "filter drops agents")
herdr.filter = nil

vim.fn.executable = function()
	return 0
end
local ready, reason = herdr.available()
assert(ready == false and reason:find("not installed", 1, true), "missing herdr: " .. tostring(reason))
assert(#herdr.targets() == 0, "no targets without herdr")
vim.fn.executable = real_exec

-- 7. jump adapter: herdr wins over tmux, and focuses by agent name
local jump = require("ask_agent.jump")
calls = {}
vim.system = function(cmd, _, cb)
	calls[#calls + 1] = cmd
	local res = { code = 0, stdout = "", stderr = "" }
	if cb then
		cb(res)
		return {}
	end
	return {
		wait = function()
			return res
		end,
	}
end
local adapter = jump.find({ herdr = { agent = "alpha" }, pane = "%1" })
assert(adapter and adapter.id == "herdr", "herdr adapter for a herdr target")
jump.focus({ herdr = { agent = "alpha" }, pane = "%1" })
vim.wait(50)
assert(vim.deep_equal(calls[1], { "herdr", "agent", "focus", "alpha" }), "focus argv: " .. vim.inspect(calls[1]))
local pane_only = jump.find({ herdr = { pane = "w1:p9" } })
assert(pane_only and pane_only.id == "herdr", "a pane id alone is enough")
assert(jump.find({ pane = "%2" }).id == "tmux", "plain tmux pane still goes to tmux")

vim.system = real_system
print("OK")
