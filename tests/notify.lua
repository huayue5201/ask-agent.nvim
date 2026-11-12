-- Headless: nvim --headless --clean -l tests/notify.lua
-- Every agent state must reach the user as a notification, with the copy, level
-- and bell the user configured for it.
vim.opt.runtimepath:prepend(".")
vim.o.belloff = ""

-- ask_agent.state keeps the module it loaded, so stub it before the state layer.
local sent = {}
package.loaded["ask_agent.notify"] = {
	notify = function(msg, level, opts)
		sent[#sent + 1] = { msg = msg, level = level, sound = opts and opts.sound }
	end,
	ring = function() end,
}

local backends = require("ask_agent.backends")
local state = require("ask_agent.state")

state.notify = true
state.persist = false

local probe = { running = true, state = "idle" }
local mod = {
	id = "fake",
	label = "Fake",
	targets = function()
		return { { id = "a", cwd = "/tmp", label = "A" } }
	end,
	probe = function()
		return probe
	end,
	available = function()
		return true
	end,
	send = function()
		return true
	end,
}
backends.register(mod)

---Move the single agent to `st` and return the notification it produced (if any).
---@param st table
---@return table|nil
local function move(st)
	probe = vim.tbl_extend("force", { running = st.running ~= false }, st)
	local before = #sent
	state.refresh()
	return #sent > before and sent[#sent] or nil
end

local key = "fake:a"
state.refresh()
assert(state.get(key).state == "idle", "first sighting is idle")
assert(#sent == 0, "the first sighting is silent")

----------------------------------------------------------------------
-- every state notifies
----------------------------------------------------------------------
local seen = {}
local function check(st, want_state, want_msg, want_level, want_sound)
	local got = move(st)
	assert(got, ("%s notifies"):format(want_state))
	assert(got.msg:find(want_msg, 1, true), ("%s text: %s"):format(want_state, got.msg))
	assert(got.level == want_level, ("%s level"):format(want_state))
	assert(got.sound == want_sound, ("%s bell"):format(want_state))
	assert(state.get(key).state == want_state, ("%s applied"):format(want_state))
	seen[want_state] = true
end

move({ state = "working" })
assert(#sent == 0, "working is silent")
check({ state = "done", msg = "tests pass" }, "done", "[fake] A finished: tests pass", vim.log.levels.INFO, true)
move({ state = "working" })
check({ state = "blocked", kind = "permission" }, "blocked", "needs your permission", vim.log.levels.WARN, true)
move({ state = "working" })
check(
	{ state = "blocked", kind = "question", msg = "which one?" },
	"blocked",
	"is waiting for your answer: which one?",
	vim.log.levels.WARN,
	true
)
move({ state = "working" })
check({ state = "blocked", kind = "auth" }, "blocked", "is waiting for credentials", vim.log.levels.WARN, true)
move({ state = "working" })
check({ state = "error", msg = "boom" }, "error", "[fake] A failed: boom", vim.log.levels.ERROR, true)

-- a blocked agent whose terminal is not on screen, then disappears on us
move({ state = "working" })
state.refresh()
probe = { running = true, state = "blocked", kind = "permission" }
state.refresh()
local before = #sent
probe = { running = false, state = "gone" }
state.refresh()
assert(#sent == before + 1, "an agent that vanishes while blocked notifies")
assert(sent[#sent].msg:find("exited while waiting for you", 1, true), "gone text: " .. sent[#sent].msg)
seen.gone = true

for _, name in ipairs({ "done", "blocked", "error", "gone" }) do
	assert(seen[name], "state reaches the user: " .. name)
end

----------------------------------------------------------------------
-- throttling
----------------------------------------------------------------------
state.configure({ gap = 60000 })
local throttled_before = #sent
probe = { running = true, state = "error", msg = "again" }
state.refresh()
probe = { running = true, state = "working" }
state.refresh()
probe = { running = true, state = "error", msg = "again" }
state.refresh()
assert(#sent == throttled_before, "a repeated error inside the gap is throttled")

state.configure({ gap = 0 })
probe = { running = true, state = "working" }
state.refresh()
probe = { running = true, state = "error", msg = "again" }
state.refresh()
assert(#sent == throttled_before + 1, "gap = 0 disables throttling")

----------------------------------------------------------------------
-- user configuration
----------------------------------------------------------------------
state.configure({
	messages = {
		done = "✅ {name} 完成{msg}",
		error = false,
		question = { text = "❓ {backend}:{name} {kind}{msg}", level = "ERROR", sound = false },
		gone = "○ {name} 走了（{was}）",
		was = { blocked = "在等你", working = "在干活" },
	},
})

probe = { running = true, state = "working" }
state.refresh()
local done = move({ state = "done", msg = "all green" })
assert(done, "a reconfigured done still notifies")
assert(done.msg == "✅ A 完成: all green", "custom text: " .. done.msg)
assert(done.sound == true, "…keeping the default bell")

probe = { running = true, state = "working" }
state.refresh()
local quiet = move({ state = "error", msg = "nope" })
assert(quiet == nil, "error = false silences that state")

probe = { running = true, state = "working" }
state.refresh()
local asked = move({ state = "blocked", kind = "question", msg = "pick" })
assert(asked, "a per-kind override still notifies")
assert(asked.msg == "❓ fake:A question: pick", "per-kind text: " .. asked.msg)
assert(asked.level == vim.log.levels.ERROR, "per-kind level")
assert(asked.sound == false, "per-kind bell off")

probe = { running = true, state = "working" }
state.refresh()
probe = { running = true, state = "blocked", kind = "permission" }
state.refresh()
local left = move({ state = "gone", running = false })
assert(left, "gone still notifies when only its text is replaced")
assert(left.msg == "○ A 走了（在等你）", "translated was: " .. left.msg)

----------------------------------------------------------------------
-- the bell itself
----------------------------------------------------------------------
package.loaded["ask_agent.notify"] = nil
local notify = require("ask_agent.notify")
local bells = 0
local stdout = io.stdout
rawset(io, "stdout", {
	write = function()
		bells = bells + 1
	end,
	flush = function() end,
})

notify.notify("one", vim.log.levels.INFO, { sound = true })
assert(bells == 1, "sound = true rings even when the module default is off")

notify.setup({ sound = true })
notify.notify("two", vim.log.levels.INFO)
assert(bells == 2, "the module default rings")

notify.notify("three", vim.log.levels.INFO, { sound = false })
assert(bells == 2, "sound = false stays quiet even when the default is on")

-- Neovim's own default is belloff=all: honouring it would silence the plugin
-- for everyone who never touched the option, so the bell is written anyway and
-- `respect_belloff` is the opt-in to the old behaviour
vim.o.belloff = "all"
notify.notify("four", vim.log.levels.INFO, { sound = true })
assert(bells == 3, "belloff does not mute the plugin's own bell: " .. bells)
notify.respect_belloff = true
notify.notify("five", vim.log.levels.INFO, { sound = true })
assert(bells == 3, "respect_belloff asks for belloff to win")
notify.respect_belloff = false

-- a real sound instead of the terminal bell (most terminals are silent by default)
local ran
vim.system = function(cmd)
	ran = cmd
	return { wait = function() end }
end
notify.setup({ sound_cmd = "afplay /System/Library/Sounds/Glass.aiff" })
notify.notify("six", vim.log.levels.INFO, { sound = true })
assert(bells == 3, "a sound command replaces the bell: " .. bells)
assert(ran and ran[1] == "sh" and ran[3]:match("afplay"), "sound_cmd runs: " .. vim.inspect(ran))
notify.setup({ sound_cmd = { "afplay", "/x.aiff" } })
notify.notify("seven", vim.log.levels.INFO, { sound = true })
assert(vim.deep_equal(ran, { "afplay", "/x.aiff" }), "a list runs as-is: " .. vim.inspect(ran))
notify.sound_cmd = nil

rawset(io, "stdout", stdout)

print("NOTIFY OK")
