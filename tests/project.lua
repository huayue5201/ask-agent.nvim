-- tests/project.lua — what a question says about the project it is asked in
-- Run from the repo root: nvim --headless --clean -l tests/project.lua
-- Covers: the digest cache / TTL / opt-out, the missing-plugin path, and how the digest and the
-- structured anchor reach a backend (structured for pi, rendered text for everyone else).
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local project = require("ask_agent.project")
local message = require("ask_agent.message")
local context = require("ask_agent.context")
local state = require("ask_agent.state")
local backends = require("ask_agent.backends")

state.persist = false
state.notify = false
require("ask_agent.history").enabled = false
require("ask_agent.snapshot").enabled = false

local root = "/tmp/ask-agent-project-root"
project.reset()

-- 1. no project-overview.nvim installed: no digest, no error
package.loaded.project_overview = nil
assert(project.available() == false, "no plugin = not available")
assert(project.digest(root) == nil, "and no digest")

-- 2. a stub overview answers, once per root
local calls = 0
package.loaded.project_overview = {
	bridge = function(req)
		calls = calls + 1
		return { ok = true, root = req.root, digest = "PROJ " .. req.root, tokens = 42, origin = "fresh" }
	end,
}
assert(project.available() == true, "stub counts as available")
assert(project.digest(root) == "PROJ " .. root, "digest comes from the overview")
assert(calls == 1, "one bridge call")
assert(project.digest(root) == "PROJ " .. root, "second call")
assert(calls == 1, "served from the cache, not the plugin")

-- 3. a broken overview never takes the question down with it
package.loaded.project_overview = {
	bridge = function()
		error("boom")
	end,
}
project.reset()
assert(project.digest(root) == nil, "an erroring overview yields nil")

-- 4. opt-out
package.loaded.project_overview = {
	bridge = function(req)
		return { ok = true, digest = "PROJ " .. req.root }
	end,
}
project.setup({ enabled = false })
project.reset()
assert(project.digest(root) == nil, "enabled=false turns the digest off")
project.setup({ enabled = true })

-- 5. render: digest sits before the anchor, and question() still shows the words
local anchor = { cwd = root, root = root, path = "src/a.lua", line = 7, filetype = "lua" }
local text = message.render(anchor, "what lives here?")
assert(text:find("^what lives here%?\n"), "the question comes first: " .. text)
assert(text:find("<project-overview>\nPROJ " .. root .. "\n</project-overview>", 1, true), "digest block: " .. text)
assert(text:find("<nvim-context src/a.lua:7>", 1, true), "then the anchor: " .. text)
assert(message.question(text) == "what lives here?", "question() strips the whole block")

-- 6. the digest is fetched at send time, not at capture time
project.reset()
calls = 0
package.loaded.project_overview = {
	bridge = function(req)
		calls = calls + 1
		return { ok = true, digest = "PROJ " .. req.root }
	end,
}
local clean = { cwd = root, root = root, path = "b.lua", line = 1 }
message.render(clean, "q")
assert(calls == 1, "render fetches it")

-- 7. lean() keeps the coordinate and drops what only the agent needs
local fat = {
	cwd = root,
	root = root,
	path = "a.lua",
	line = 3,
	digest = "PROJ x",
	context = { start_line = 1, end_line = 3, lines = { "a", "b", "c" } },
	diagnostics = { { line = 3, severity = "error", source = "lua_ls", message = "boom" } },
	visual = { start_line = 1, end_line = 2, lines = { "a", "b" } },
}
local thin = context.lean(fat)
assert(thin.digest == nil, "digest is not journal material")
assert(thin.context == nil and thin.diagnostics == nil, "nor is the source or the diagnostics")
assert(thin.visual and thin.visual.lines == nil, "nor the selected text")
assert(thin.path == "a.lua" and thin.line == 3, "but the coordinate survives")
assert(fat.digest == "PROJ x", "the original is untouched")

-- 8. a backend that understands the anchor gets the clean question + the fields
local got = {}
backends.register({
	id = "probe",
	label = "Probe",
	anchor_payload = true,
	available = function()
		return true
	end,
	targets = function()
		return { { id = "p1", cwd = root, label = "Probe" } }
	end,
	send = function(_, text, opts)
		got.text, got.opts = text, opts
		return true
	end,
})
local ask = require("ask_agent")
local full = vim.deepcopy(fat)
assert(ask.send("why?", { backend = "probe", target = "p1", anchor = full }), "send goes out")
assert(got.text == "why?", "the backend gets the question alone: " .. vim.inspect(got.text))
assert(type(got.opts.anchor) == "table" and got.opts.anchor.path == "a.lua", "plus the structured anchor")
assert(got.opts.anchor.context and got.opts.anchor.context.lines ~= nil, "unleaned: the agent needs it")
assert(got.opts.task_id, "and the task id, as before")

-- 9. a text-only backend gets the rendered message instead
local textonly = {
	id = "plain",
	label = "Plain",
	available = function()
		return true
	end,
	targets = function()
		return { { id = "t1", cwd = root, label = "Plain" } }
	end,
	send = function(_, text)
		got.text = text
		return true
	end,
}
backends.register(textonly)
local rendered = message.render(fat, "why?")
assert(ask.send(rendered, { backend = "plain", target = "t1", anchor = fat }), "plain send goes out")
assert(got.text == rendered, "text-only backends are untouched")
assert(got.text:find("<nvim-context", 1, true) ~= nil, "and still carry the block")

print("PROJECT OK")
os.exit(0)
