-- Headless: nvim --headless --clean -l tests/snapshot.lua
-- Covers turn boundaries: begin/finish, persistence across a "restart", dispatch
-- deduplication, the live (open) range, cancel, and state-driven boundaries.
vim.opt.runtimepath:prepend(".")

local snapshot = require("ask_agent.snapshot")
local git = require("ask_agent.git")

local function sh(cwd, cmd)
	local res = vim.system({ "sh", "-c", cmd }, { cwd = cwd, text = true }):wait()
	assert(res.code == 0, ("cmd failed: %s\n%s"):format(cmd, res.stderr))
end

local repo = vim.fn.tempname()
vim.fn.mkdir(repo, "p")
sh(repo, "git init -q -b main && git config user.email t@t && git config user.name t")
sh(repo, "printf 'a\\n' > f.txt && git add -A && git commit -qm init")

local store = vim.fn.tempname() .. ".json"
snapshot.setup({ enabled = true, path = store, keep = 5, ttl = 3600000 })

-- begin/finish around an agent edit
local rec = assert(snapshot.begin({ cwd = repo, backend = "fake", agent = "1", task = "do\nit", trigger = "dispatch" }))
assert(rec.status == "open" and rec.root == git.root(repo), "record starts open")
assert(rec.task == "do it", "task text is one line")

sh(repo, "printf 'a\\nb\\n' > f.txt && printf 'c\\n' > g.txt")
local closed = assert(snapshot.finish(rec))
assert(closed.status == "closed" and closed.finish and closed.finish ~= closed.start, "finish records a tree")

local from, to, live = snapshot.range(closed)
assert(from == closed.start and to == closed.finish and live == false, "closed range is stored")

local files = assert(git.changed(repo, from, to))
assert(#files == 2, "the turn contains the modification and the new file")

-- idempotent finish: a closed record is never rewritten
local again = snapshot.finish(closed)
assert(again.finish == closed.finish, "finish is idempotent")

-- persistence: reload from disk in a fresh module state
snapshot.setup({ path = store })
local found = assert(snapshot.get(closed.id), "turn survives a reload (journal re-read)")
assert(found.start == closed.start and found.finish == closed.finish, "evidence is intact")
assert(#snapshot.list(repo) == 1, "list filters by repository")
assert(#snapshot.list("/") == 0, "unrelated directory has no turns")

-- cancelled send leaves nothing behind
local doomed = assert(snapshot.begin({ cwd = repo, backend = "fake", agent = "9", trigger = "dispatch" }))
snapshot.cancel(doomed)
assert(snapshot.get(doomed.id) == nil, "cancel drops the record")
assert(#snapshot.list(repo) == 1, "cancel does not disturb other turns")

-- dispatch dedup: a second send to the same agent widens the open turn
local a = assert(snapshot.on_dispatch("fake", "2", "first", { cwd = repo }))
local b = assert(snapshot.on_dispatch("fake", "2", "second", { cwd = repo }))
assert(a.id == b.id, "one open turn per agent")
assert(snapshot.open_for("fake", "2").id == a.id, "open_for finds it")

-- the correlation recorded at dispatch leads back to the turn
local corr = { plugin = "test", key = 7 }
local c = assert(snapshot.on_dispatch("fake", "3", "with correlation", { cwd = repo }, corr))
assert(c.correlation and c.correlation.key == 7, "correlation is stored")
assert(snapshot.for_task(corr).id == c.id, "for_task finds the turn")
assert(snapshot.for_task({ plugin = "test", key = 8 }) == nil, "unknown correlation finds nothing")
snapshot.finish(c)

-- an open turn compares against a fresh snapshot without rewriting the evidence
sh(repo, "printf 'a\\nb\\nc\\n' > f.txt")
local live_from, live_to, is_live = snapshot.range(a)
assert(live_from == a.start and is_live == true and live_to ~= a.start, "live range uses a fresh end tree")
assert(snapshot.get(a.id).finish == nil, "the stored record is not mutated")

-- state-driven boundaries: working opens, done closes (external typing)
local handlers = {}
local fake_state = {
	on = function(event, fn)
		handlers[event] = fn
	end,
}
snapshot.attach(fake_state)
local st = {
	backend = "fake",
	id = "3",
	state = "idle",
	target = { id = "3", cwd = repo, label = "3" },
}
handlers.state(st, "unknown")
assert(snapshot.open_for("fake", "3") == nil, "idle does not open a turn")
st.state = "working"
handlers.state(st, "idle")
local opened = assert(snapshot.open_for("fake", "3"), "working opens a state turn")
assert(opened.trigger == "state", "trigger is recorded")
sh(repo, "printf 'z\\n' > z.txt")
st.state = "done"
handlers.state(st, "working")
assert(snapshot.open_for("fake", "3") == nil, "done closes the turn")
local done = assert(snapshot.get(opened.id))
assert(done.status == "closed" and done.finish_trigger == "state:done", "close reason is recorded")

-- blocked is still mid-turn: it must not close
local blocked = assert(snapshot.begin({ cwd = repo, backend = "fake", agent = "4", trigger = "state" }))
st.id, st.target.id, st.state = "4", "4", "working"
handlers.state(st, "idle")
st.state = "blocked"
handlers.state(st, "working")
assert(snapshot.get(blocked.id).status == "open", "blocked keeps the turn open")

-- keep/ttl pruning: keep only the newest N turns
snapshot.setup({ path = store, keep = 2, ttl = 3600000 })
for i = 1, 4 do
	sh(repo, ("printf '%d\\n' > f.txt"):format(i))
	local r = assert(snapshot.begin({ cwd = repo, backend = "fake", agent = "keep" .. i }))
	snapshot.finish(r)
end
assert(#snapshot.list(repo) <= 3, "keep bounds the journal (open + newest): " .. #snapshot.list(repo))
local newest = snapshot.list(repo)[1]
assert(newest.agent == "keep4", "newest first")

vim.fn.delete(repo, "rf")
vim.fn.delete(store)
print("SNAPSHOT OK")
