-- Headless: nvim --headless --clean -l tests/dashboard_layout.lua
-- The panel is a table: a rail, group headings and columns. Layout is easy to
-- break and hard to review by eye, so each width tier is pinned to a snapshot.
vim.opt.runtimepath:prepend(".")

local backends = require("ask_agent.backends")
local state = require("ask_agent.state")
local queue = require("ask_agent.queue")
local dashboard = require("ask_agent.dashboard")
local aliases = require("ask_agent.aliases")

aliases.setup({ file = "/tmp/ask-agent-layout-aliases.json" })
vim.fn.delete("/tmp/ask-agent-layout-aliases.json")
state.notify = false
state.persist = false

local targets = {
	{ id = "a", cwd = "/tmp/layout-a", label = "reviewer" },
	{ id = "b", cwd = "/tmp/layout-b", label = "worker" },
	{ id = "c", cwd = "/tmp/layout-c", label = "explorer" },
	{ id = "d", cwd = "/tmp/layout-d", label = "archivist" },
	{ id = "e", cwd = "/tmp/layout-e", label = "ghost" },
}
backends.register({
	id = "fake",
	label = "Fake",
	targets = function()
		return targets
	end,
	probe = function(t)
		if t.id == "a" then
			return { running = true, state = "blocked", kind = "permission" }
		end
		if t.id == "b" then
			return { running = true, state = "working", msg = "busy" }
		end
		if t.id == "e" then
			return { running = false, state = "gone" }
		end
		return { running = true, state = "idle", msg = "idle" }
	end,
	available = function()
		return true
	end,
	send = function()
		return true
	end,
})

local buf = vim.api.nvim_get_current_buf()
local function anchor(path, line)
	return { buf = buf, path = path, line = line, cwd = "/tmp" }
end

state.dispatch("fake", "a", "port the parser to the new AST", { anchor = anchor("parser.lua", 41) })
state.dispatch("fake", "b", "run the test suite", { anchor = anchor("tests/run.lua", 22) })
queue.add({ buf = buf, line = 1, col = 1, path = "x.lua" }, "explain the rex protocol")
queue.route(1, { backend = "fake", id = "b", name = "worker" })
state.dispatch("fake", "d", "update the docs for the new flag", { anchor = anchor("doc/api.txt", 120) })
state.refresh()
-- a finished turn keeps its row, but stops shouting
local d = state.get("fake:d")
d.tasks[1].status, d.tasks[1].finish = "done", d.tasks[1].ts + 65000

local function render(width)
	if vim.api.nvim_win_is_valid(0) and vim.bo[vim.api.nvim_get_current_buf()].filetype == "ask-agent-dashboard" then
		pcall(vim.api.nvim_win_close, 0, true)
	end
	dashboard.open(nil, { width = width })
	vim.wait(20)
	return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

local expected = {
	[62] = {
		"NEEDS YOU  1",
		"▌ ▾ ⚠ reviewer (1)              perm                       0s",
		"▌ │ └─ ⠋ port the parser to the n… sent     parser.lua:41  0s",
		"",
		"WORKING  1",
		"▌ ▾ ⠋ worker (2)                busy                       0s",
		"▌ │ ├─ ⠋ run the test suite        sent     run.lua:22     0s",
		"▌ │ └─ ◐ explain the rex protocol  queued     x.lua:1",
		"",
		"IDLE & DONE  2",
		"▌ · ● explorer                  idle                       0s",
		"▌ ▾ ● archivist (1)             idle                       0s",
		"▌ │ └─ ✓ update the docs for the … done     api.txt:120    1m",
	},
	[40] = {
		"▾ ⚠ reviewer (1)         perm        0s",
		"│ └─ ⠋ port the parser to … sent     0s",
		"▾ ⠋ worker (2)           busy        0s",
		"│ ├─ ⠋ run the test suite   sent     0s",
		"│ └─ ◐ explain the rex pro… queued",
		"· ● explorer             idle        0s",
		"▾ ● archivist (1)        idle        0s",
		"│ └─ ✓ update the docs for… done     1m",
	},
	[26] = {
		"▾ ⚠ revie… perm        0s",
		"│ └─ ⠋ port … sent     0s",
		"▾ ⠋ worke… busy        0s",
		"│ ├─ ⠋ run t… sent     0s",
		"│ └─ ◐ expla… queued",
		"· ● explo… idle        0s",
		"▾ ● archi… idle        0s",
		"│ └─ ✓ updat… done     1m",
	},
}

if os.getenv("DUMP") then
	for _, width in ipairs({ 62, 40, 26 }) do
		print(("  [%d] = {"):format(width))
		for _, l in ipairs(render(width)) do
			print(("    %q,"):format(l))
		end
		print("  },")
	end
	os.exit(0)
end

for _, width in ipairs({ 62, 40, 26 }) do
	local lines = render(width)
	local want = expected[width]
	assert(#lines == #want, ("width %d: %d rows, snapshot has %d"):format(width, #lines, #want))
	for i, line in ipairs(lines) do
		assert(line == want[i], ("width %d row %d:\n  got  %q\n  want %q"):format(width, i, line, want[i]))
		assert(vim.fn.strdisplaywidth(line) <= width, "row wider than the sidebar: " .. line)
	end
end

local ghost = state.get("fake:e")
assert(ghost and ghost.gone, "the fixture's dead agent is known to the state layer")
assert(not table.concat(render(62), "\n"):find("ghost", 1, true), "a stopped agent leaves the panel")

print("DASHBOARD LAYOUT OK")
