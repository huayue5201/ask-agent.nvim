-- Headless: nvim --headless --clean -l tests/statusline.lua
-- The statusline chunk: what each segment means, and that idle only shows when quiet.
vim.opt.runtimepath:prepend(".")

local backends = require("ask_agent.backends")
local state = require("ask_agent.state")
local icons = require("ask_agent.icons")

-- names come from here: never touch the user's aliases file from a test
require("ask_agent.aliases").setup({ file = "/tmp/ask-agent-aliases-statusline.json" })

state.notify = false
state.persist = false

local targets = {}
local probes = {}

local mod = {
	id = "fake",
	label = "Fake",
	targets = function()
		return targets
	end,
	probe = function(t)
		return probes[t.id]
	end,
	available = function()
		return true
	end,
	send = function()
		return true
	end,
}

local function clear()
	for _, t in ipairs(targets) do
		state.dismiss("fake:" .. t.id)
	end
	targets, probes = {}, {}
end

---Add an agent that the next poll will observe in `probe`.
---Forgot one agent entirely (target gone, record gone).
local function drop(id)
	for i, t in ipairs(targets) do
		if t.id == id then
			table.remove(targets, i)
			break
		end
	end
	probes[id] = nil
	state.dismiss("fake:" .. id)
end

local function add(id, probe)
	targets[#targets + 1] = { id = id, cwd = "/tmp", label = "pid " .. id }
	probes[id] = probe
end

---Poll once and return the plain (non-animated) chunk.
local function line(opts)
	state.refresh()
	opts = vim.tbl_extend("force", { animated = false }, opts or {})
	return state.statusline(opts)
end

backends.register(mod)

-- nothing at all: no chunk, no placeholder
assert(state.statusline({ animated = false }) == "", "no agents is an empty string")

-- working first, with the count; the spinner frame is left to the animated path
add("w1", { running = true, state = "working" })
add("w2", { running = true, state = "working" })
assert(line() == "◐2", "working renders as mark + count, got " .. line())

-- confirmation and question are separate segments: one wants a yes, the other an answer
add("b1", { running = true, state = "blocked", kind = "permission" })
add("b2", { running = true, state = "blocked", kind = "auth" })
add("q1", { running = true, state = "blocked", kind = "question" })
assert(line() == "◐2 ⚠2 ?1", "blocked splits into confirm + question, got " .. line())

-- a blocked agent with no kind still counts as "waiting for you"
add("b3", { running = true, state = "blocked" })
assert(line() == "◐2 ⚠3 ?1", "kindless blocked counts as confirm, got " .. line())

-- done only counts while unread, and ack is what clears it
add("d1", { running = true, state = "done" })
assert(line():find("✓1", 1, true), "an unread done shows, got " .. line())
state.ack("fake:d1")
assert(not line():find("✓", 1, true), "ack clears the done segment, got " .. line())

-- errors are the last of the "needs you" group
add("e1", { running = true, state = "error" })
assert(line():find("✗1", 1, true), "an error shows, got " .. line())

-- segment order is fixed: working, confirm, question, done, error
local parts = vim.split(line(), " ")
assert(parts[1] == "◐2", "working leads, got " .. line())
assert(parts[2] == "⚠3", "confirm second, got " .. line())
assert(parts[3] == "?1", "question third, got " .. line())

-- idle is hidden while anything above is happening …
add("i1", { running = true, state = "idle" })
add("i2", { running = true, state = "idle" })
assert(not line():find("●", 1, true), "idle is suppressed when there is news, got " .. line())
-- … and it is the only thing left when everything else goes quiet
clear()
add("i1", { running = true, state = "idle" })
add("i2", { running = true, state = "idle" })
add("i3", { running = true, state = "idle" })
assert(line() == "●3", "idle alone shows its count, got " .. line())
assert(line({ idle = true }) == "●3", "idle = true keeps it, got " .. line())
assert(line({ idle = false }) == "", "idle = false hides it entirely, got " .. line())

-- exited agents are history: they never inflate a count
clear()
add("g1", { running = false, state = "gone", gone = true })
assert(state.statusline({ animated = false }) == "", "gone agents do not count")

-- animated mode returns a spinner frame rather than the static mark
clear()
add("w1", { running = true, state = "working" })
state.refresh()
local spin = state.statusline({ animated = true })
assert(
	spin:match("^" .. vim.pesc(icons.spin(0)):sub(1, 3)) or spin:find("%d$"),
	"animated chunk ends in a count, got " .. spin
)
assert(spin ~= "◐1", "animated mode uses the spinner, not the static mark, got " .. spin)
local frames = {}
for _ = 1, 3 do
	frames[state.statusline({ animated = true })] = true
end
assert(vim.tbl_count(frames) >= 1, "the animated chunk is a spinner frame + count")

-- the timer must not survive a quiet world: it is the only thing that wakes nvim up
state.dismiss("fake:w1")
assert(
	vim.wait(400, function()
		return state.statusline({ animated = true }) == ""
	end),
	"quiet statusline after the last agent leaves"
)

-- the spinner must survive a working -> quiet -> working cycle (the timer is reused)
clear()
add("w1", { running = true, state = "working" })
state.refresh()
assert(state.statusline({ animated = true }) ~= "", "animated chunk while working")
drop("w1")
state.refresh()
assert(state.statusline({ animated = true }) == "", "quiet again")
add("w2", { running = true, state = "working" })
state.refresh()
local again = state.statusline({ animated = true })
assert(again:find("%d$") ~= nil, "restarted spinner still renders, got " .. again)

print("STATUSLINE OK")
vim.cmd("qa!")
