-- Headless: nvim --headless --clean -l tests/aliases.lua
-- Names survive a restart as directory slots, not as pids.
vim.opt.runtimepath:prepend(".")

local aliases = require("ask_agent.aliases")
local file = "/tmp/ask-agent-aliases-test.json"
vim.fn.delete(file)
aliases.setup({ file = file })

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")

local a = { id = "1", ts = 100, cwd = dir, backend = "pi" }
local b = { id = "2", ts = 200, cwd = dir, backend = "pi" }
local c = { id = "3", ts = 300, cwd = dir, backend = "pi" }

assert(aliases.get(a, "pi") == nil, "no name yet")
assert(aliases.default_name({ id = "9", label = "pid 123", cwd = dir }) == vim.fn.fnamemodify(dir, ":t"))
assert(aliases.default_name({ label = "pid 9", cwd = "/" }) == "pid 9", "no directory, keep the label")
assert(aliases.default_name({ title = "reviewer", cwd = "/tmp" }) == "reviewer", "a title is the best default")

assert(aliases.set(a, "pi", "api"), "write")
assert(aliases.get(a, "pi") == "api", "exact name")
assert(aliases.get(b, "pi") == "api", "one slot is inherited by the next process")

assert(aliases.set(b, "pi", "worker"), "second name")
assert(aliases.get(a, "pi") == "api", "slot one keeps its name")
assert(aliases.get(b, "pi") == "worker ·2", "the second slot is numbered")
assert(aliases.get(c, "pi") == nil, "with several slots an unbound process inherits nothing")

assert(aliases.set(c, "pi", "review"), "third name")
assert(aliases.get(c, "pi") == "review ·3", "free slot is claimed")

assert(aliases.clear(b, "pi"), "clear")
assert(aliases.get(b, "pi") == nil, "cleared")
assert(aliases.get(a, "pi") == "api", "other slots untouched")
assert(aliases.get(c, "pi") == "review ·3", "other slots untouched")

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
