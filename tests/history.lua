-- Headless: nvim --headless --clean -l tests/history.lua
-- Covers the question ledger: recording, order, filters, prefix lookup, pruning,
-- persistence, deletion and jumping back to the code an old question was asked about.
vim.opt.runtimepath:prepend(".")

local history = require("ask_agent.history")

local store = vim.fn.tempname() .. ".json"
history.setup({ path = store, keep = 5, max_text = 100 })
history.clear()

local repo = vim.fn.tempname()
vim.fn.mkdir(repo, "p")
vim.fn.writefile({ "local x = 1", "local y = 2" }, repo .. "/a.lua")

local function anchor(path, line)
	-- no live buffer on purpose: this is what a record from an earlier session looks like
	return { cwd = repo, path = path, line = line, bufname = repo .. "/" .. path }
end

-- old → new insertion order is reversed for display
local a =
	history.add({ text = "explain this", backend = "pi", agent = "1", label = "pi #1", anchor = anchor("a.lua", 1) })
local b = history.add({
	text = "rename that",
	backend = "claude",
	agent = "2",
	label = "claude",
	anchor = anchor("a.lua", 2),
	correlation = { plugin = "todo2", key = "t42" },
})
assert(a and b, "records are returned")
assert(a.id and b.id, "records get ids")
assert(b.ts >= a.ts, "timestamps progress")
assert(history.describe(b):find("t42", 1, true), "describe names the dispatching task: " .. history.describe(b))
assert(not history.describe(a):find("todo2", 1, true), "plain records stay clean")

local all = history.list()
assert(#all == 2, "both recorded")
assert(all[1].id == b.id and all[2].id == a.id, "newest first")

-- filters
assert(#history.list({ query = "rename that" }) == 1, "query matches text")
assert(#history.list({ query = "a.lua" }) == 2, "query matches the anchor path")
assert(#history.list({ query = "nothing here" }) == 0, "query misses")
assert(#history.list({ backend = "claude" }) == 1, "backend filter")
assert(#history.list({ cwd = repo }) == 2, "cwd filter")
assert(#history.list({ cwd = "/" }) == 0, "other cwd is empty")
assert(#history.list({ limit = 1 }) == 1, "limit")

-- id lookup: full, unique prefix, unknown
assert(history.get(a.id).id == a.id, "full id")
assert(history.get(b.id).id == b.id, "full id resolves")
-- Two records created in the same millisecond share a prefix; an ambiguous prefix
-- must not silently pick one.
local common = 0
while common < math.min(#a.id, #b.id) and a.id:sub(common + 1, common + 1) == b.id:sub(common + 1, common + 1) do
	common = common + 1
end
if common > 0 then
	assert(history.get(a.id:sub(1, common)) == nil, "ambiguous prefix does not pick a record")
end
assert(history.get("9999999999999") == nil, "unknown id")

-- oversized text is truncated, not dropped
local huge = assert(history.add({ text = ("x"):rep(500), anchor = anchor("a.lua", 1) }))
assert(#huge.text < 200 and huge.text:find("truncated", 1, true), "max_text truncates")

-- persistence: a fresh load sees the same records
history.setup({ path = store })
local reloaded = history.list()
assert(reloaded[1].id == huge.id and #reloaded == 3, "records survive a reload")

-- pruning keeps the newest `keep`
history.keep = 2
for i = 1, 4 do
	history.add({ text = "prune " .. i, anchor = anchor("a.lua", i) })
end
local kept = history.list()
assert(#kept == 2, "keep bounds the journal: " .. #kept)
assert(kept[1].text == "prune 4", "newest survives")

-- deletion by id and prefix
assert(history.remove(kept[1].id))
assert(history.get(kept[1].id) == nil, "deleted record is gone")
history.remove(nil)
assert(#history.list() == 0, "remove(nil) clears")

-- jump: reopening the file by path works even when the recorded buffer is gone
local rec = assert(history.add({ text = "where", anchor = anchor("a.lua", 2) }))
assert(history.jump(rec), "jump opens the file")
local function real(path)
	return (vim.uv.fs_realpath(path) or path)
end
assert(real(vim.api.nvim_buf_get_name(0)) == real(repo .. "/a.lua"), "jumped to the file")
assert(vim.api.nvim_win_get_cursor(0)[1] == 2, "jumped to the line")

-- a unique prefix resolves when only one record can match it
history.remove(nil)
local solo = assert(history.add({ text = "solo", anchor = anchor("a.lua", 1) }))
assert(history.get(solo.id:sub(1, #solo.id - 1)).id == solo.id, "unique prefix resolves")

-- a missing file is a clean failure
local gone = assert(history.add({ text = "gone", anchor = anchor("nope.lua", 1) }))
local ok, err = history.jump(gone)
assert(ok == false and type(err) == "string", "missing file reports an error")

-- ids: the send path generates the id before the send and hands it to the agent,
-- so `add` must accept it; answers need an explicit opt-in (questions only by default)
history.remove(nil)
local explicit = assert(history.add({ id = "task-42", text = "q" }))
assert(explicit.id == "task-42" and history.get("task-42") == explicit, "explicit id is used")
assert(history.set_answer("task-42", "the answer") == nil, "answers are off until enabled")
history.answers = true
assert(history.set_answer("task-42", "the answer").answer == "the answer", "answer attaches")
assert(history.get("task-42").answer_ts, "answer is stamped")
local big = assert(history.set_answer("task-42", string.rep("x", 500)))
assert(#big.answer < 200 and big.answer:find("truncated", 1, true), "answers are capped like questions")
assert(history.set_answer("missing", "x") == nil, "unknown task is a no-op")
assert(history.new_id() ~= history.new_id(), "generated ids are unique")
-- and answers survive a reload of the file
history.setup({ path = store, keep = 5, max_text = 100 })
assert(history.get("task-42").answer_ts, "the answer is on disk")
history.answers = false

vim.cmd("silent! %bwipeout!")
vim.fn.delete(repo, "rf")
vim.fn.delete(store)
print("HISTORY OK")
