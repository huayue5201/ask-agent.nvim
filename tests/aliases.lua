-- Headless: nvim --headless --clean -l tests/aliases.lua
-- Names survive a restart as directory slots, not as pids.
vim.opt.runtimepath:prepend(".")

local aliases = require("ask_agent.aliases")
local file = "/tmp/ask-agent-aliases-test.json"
vim.fn.delete(file)
aliases.setup({ file = file })

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")

-- Ids are pids (that is how a slot knows whether its owner is still around),
-- so the owner is this very process and the "other" one is a pid nobody uses.
local live = tostring(vim.uv.os_getpid())
local dead = "999999"

local a = { id = live, ts = 100, cwd = dir, backend = "pi" }
local b = { id = dead, ts = 200, cwd = dir, backend = "pi" }
local c = { id = "999998", ts = 300, cwd = dir, backend = "pi" }

assert(aliases.get(a, "pi") == nil, "no name yet")
assert(aliases.default_name({ id = "9", label = "pid 123", cwd = dir }) == vim.fn.fnamemodify(dir, ":t"))
assert(aliases.default_name({ label = "pid 9", cwd = "/" }) == "pid 9", "no directory, keep the label")
assert(aliases.default_name({ title = "reviewer", cwd = "/tmp" }) == "reviewer", "a title is the best default")
assert(
	aliases.default_name({ title = "my  agent\nname", cwd = "/tmp" }) == "my agent name",
	"a title is folded to one line"
)
local long = aliases.default_name({ title = string.rep("x", 80), cwd = "/tmp" })
assert(
	vim.fn.strdisplaywidth(long) <= 32 and long:sub(-3) == "\u{2026}",
	"a runaway title is shortened, not pasted whole"
)

assert(aliases.set(a, "pi", "api"), "write")
assert(aliases.set(a, "pi", "  api\nworker  "), "write a messy name")
assert(aliases.get(a, "pi") == "api worker", "stored names are folded to one line")
assert(aliases.set(a, "pi", "api"), "rewrite a clean name")
assert(aliases.get(a, "pi") == "api", "exact name")
assert(aliases.get(b, "pi") == nil, "a live owner's name is not handed to a second instance")

-- a restart does inherit it: the slot's owner is gone, the next pid takes the name
local other = "/tmp/ask-agent-aliases-restart.json"
aliases.setup({ file = other })
vim.fn.delete(other)
local gone = { id = dead, ts = 400, cwd = dir, backend = "pi" }
assert(aliases.set(gone, "pi", "gone"), "name a process that is no longer there")
local restarted = { id = "999997", ts = 401, cwd = dir, backend = "pi" }
assert(aliases.get(restarted, "pi") == "gone", "a dead owner's name is inherited by the next process")
aliases.setup({ file = file })
vim.fn.delete(other)

assert(aliases.set(b, "pi", "worker"), "second name")
assert(aliases.get(a, "pi") == "api", "slot one keeps its name")
assert(aliases.get(b, "pi") == "worker", "different names need no slot number")
assert(aliases.get(c, "pi") == nil, "with several slots an unbound process inherits nothing")

assert(aliases.set(c, "pi", "review"), "third name")
assert(aliases.get(c, "pi") == "review", "free slot is claimed")

-- the bug this guards: one rename used to rename every instance in the directory
aliases.setup({ file = "/tmp/ask-agent-aliases-two.json" })
vim.fn.delete("/tmp/ask-agent-aliases-two.json")
local one = { id = live, ts = 501, cwd = dir, backend = "pi" }
local two = { id = "999996", ts = 502, cwd = dir, backend = "pi" }
assert(aliases.get(one, "pi") == nil and aliases.get(two, "pi") == nil, "two unnamed agents")
assert(aliases.set(one, "pi", "only one"), "rename one of them")
assert(aliases.get(one, "pi") == "only one", "the renamed one")
assert(aliases.get(two, "pi") == nil, "the other keeps its own (default) name")
aliases.setup({ file = file })
assert(aliases.get(a, "pi") == "api", "back on the main store")

assert(aliases.clear(b, "pi"), "clear")
assert(aliases.get(b, "pi") == nil, "cleared")
assert(aliases.get(a, "pi") == "api", "other slots untouched")
assert(aliases.get(c, "pi") == "review", "other slots untouched")

-- two slots with the same name are numbered, so the list stays readable
assert(aliases.set(b, "pi", "api"), "same name twice")
assert(aliases.get(a, "pi") == "api ·1", "the first duplicate is numbered")
assert(aliases.get(b, "pi") == "api ·2", "the second duplicate is numbered")
assert(aliases.set(b, "pi", "worker"), "back to a distinct name")
assert(aliases.get(a, "pi") == "api", "a unique name carries no number")

-- same directory, different backend: no cross-talk
local tmux = { id = "1", ts = 100, cwd = dir, backend = "tmux" }
assert(aliases.get(tmux, "tmux") == nil, "backend is part of the identity")

-- the store survives a reload, and the old flat format is still readable
aliases.setup({ file = file })
assert(aliases.get(a, "pi") == "api", "persisted")
local legacy = "/tmp/ask-agent-aliases-legacy.json"
vim.fn.writefile({ vim.json.encode({ ["42"] = { name = "old name", ts = "7", cwd = dir } }) }, legacy)
aliases.setup({ file = legacy })
assert(aliases.get({ id = "42", ts = "7", cwd = dir }, "pi") == "old name", "v1 file")
vim.fn.delete(file)
vim.fn.delete(legacy)
vim.fn.delete(dir, "rf")

print("ALIASES OK")
