-- Headless: nvim --headless --clean -l tests/results.lua
-- Covers the answer path: opt-in switch, "questions only" default, attaching an
-- answer to the task the agent was given, and the file mailbox hooks write into.
vim.opt.runtimepath:prepend(".")

local history = require("ask_agent.history")
local results = require("ask_agent.results")

local store = vim.fn.tempname() .. ".json"
history.setup({ path = store, keep = 5, max_text = 200 })
history.clear()

-- the mailbox is redirected so the test never touches the user's cache
local mail = vim.fn.tempname()
results.dir = function()
	return mail
end

assert(results.record({ task_id = "t1", text = "x" }) == false, "results are off by default")
local ok, err = results.record({ task_id = "t1", text = "x" })
assert(ok == false and err:find("disabled", 1, true), "off by default says so: " .. tostring(err))

results.enabled = true
history.answers = true
local q = assert(history.add({ id = "t1", text = "why is it slow?" }))

-- the answer lands on the record the task id points at
assert(results.record({ task_id = "t1", text = "because N+1 queries" }))
assert(history.get("t1").answer == "because N+1 queries", "answer lands on the record")
assert(history.get("t1").id == q.id, "same record")

-- nothing is guessed when neither an id nor a matching cwd is given
local ok2, err2 = results.record({ text = "orphan" })
assert(ok2 == false and err2:find("no task", 1, true), "unmatched answer is refused: " .. tostring(err2))

-- mailbox: a delivered file is consumed, an undeliverable one is kept for inspection
vim.fn.mkdir(mail, "p")
vim.fn.writefile({ vim.json.encode({ task_id = "t1", text = "from a hook" }) }, mail .. "/a.json")
vim.fn.writefile({ vim.json.encode({ cwd = "/nowhere", text = "stray" }) }, mail .. "/b.json")
vim.fn.writefile({ "{not json" }, mail .. "/c.json")
local imported, failed = results.import()
assert(imported == 1 and failed == 2, ("imported %d, failed %d"):format(imported, failed))
assert(history.get("t1").answer == "from a hook", "mail replaces the answer")
assert(vim.fn.filereadable(mail .. "/a.json") == 0, "delivered mail is consumed")
assert(vim.fn.filereadable(mail .. "/b.json") == 1, "undeliverable mail is kept")
assert(vim.fn.filereadable(mail .. "/c.json") == 1, "unreadable mail is kept")
-- stale mail is dropped, not imported forever
local stale = mail .. "/d.json"
vim.fn.writefile({ vim.json.encode({ task_id = "t1", text = "written last year" }) }, stale)
vim.uv.fs_utime(stale, os.time() - results.mail_ttl - 60, os.time() - results.mail_ttl - 60)
local imported2 = results.import()
assert(imported2 == 0 and vim.fn.filereadable(stale) == 0, "stale mail is deleted")

-- show() refuses tasks it cannot render instead of opening an empty float
local ok3, err3 = results.show({ text = "no id here" })
assert(ok3 == false and err3:find("no id", 1, true), "a task without an id is refused: " .. tostring(err3))
local ok4, err4 = results.show("never-sent")
assert(ok4 == false and err4:find("gone", 1, true), "a pruned record is reported: " .. tostring(err4))

-- resolve() is what the dashboard hands over: a state task or a bare id
local id, rec = results.resolve({ task_id = "t1" })
assert(id == "t1" and rec == history.get("t1"), "task table resolves")
local id2 = results.resolve("t1")
assert(id2 == "t1", "a bare id resolves")
assert(results.resolve({}) == nil, "a task without an id resolves to nothing")

-- the documented path agents use: one bridge action, no transcript parsing
local bridge = require("ask_agent.bridge")
local function call(req)
	local b64 = vim.base64.encode(vim.json.encode(req))
	return vim.json.decode(bridge.handle(b64))
end
local bridged = call({ action = "result", task_id = "t1", text = "via the bridge" })
assert(bridged.ok == true, "the bridge accepts a result: " .. vim.inspect(bridged))
assert(history.get("t1").answer == "via the bridge", "a bridged answer lands on the record")

-- and with results off it refuses instead of silently storing
results.enabled = false
local refused = call({ action = "result", task_id = "t1", text = "nope" })
assert(refused.ok == false and refused.error:find("disabled", 1, true), "disabled results are refused")
assert(history.get("t1").answer == "via the bridge", "a refused answer does not overwrite")
results.enabled = true

vim.fn.delete(mail, "rf")
vim.fn.delete(store)
print("RESULTS OK")
