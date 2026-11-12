-- Headless: nvim --headless --clean -l tests/prompts.lua
-- Covers the prompt library: global/project layering, upsert, deletion, root
-- discovery for non-git projects, and placeholder rendering against a real anchor.
vim.opt.runtimepath:prepend(".")

local prompts = require("ask_agent.prompts")

local base = vim.fn.tempname()
vim.fn.mkdir(base .. "/repo/.ask-agent", "p")
vim.fn.mkdir(base .. "/plain/.ask-agent", "p")
vim.fn.mkdir(base .. "/nothing/deeper", "p")
prompts.global_path = base .. "/global.json"

-- start with an empty world
vim.fn.delete(prompts.global_path)

-- save global → written to the global file
assert(prompts.save("explain", "Explain {{selection}} in {{file}}", { desc = "explain code" }))
assert(vim.fn.filereadable(prompts.global_path) == 1, "global file created")

-- save project → written under the project root
local repo = base .. "/repo"
vim.fn.writefile({ "{}" }, repo .. "/.git-placeholder")
assert(prompts.save("review", "Review {{file}} for bugs", { project = true, cwd = repo }))
assert(vim.fn.filereadable(repo .. "/.ask-agent/prompts.json") == 1, "project file created")

-- root discovery: a `.ask-agent` directory makes a non-git tree a project
assert(prompts.root(base .. "/plain/.ask-agent") == base .. "/plain", "root via .ask-agent")
assert(prompts.root(base .. "/nothing/deeper") == nil, "no project marker, no root")
assert(prompts.project_path(repo) == repo .. "/.ask-agent/prompts.json", "project path")

-- merge: global first, project appended; project overrides by name
local all = prompts.all(repo)
assert(#all == 2, "two prompts visible")
assert(all[1].name == "explain" and all[1].source == "global", "global first")
assert(all[2].name == "review" and all[2].source == "project", "project second")

assert(prompts.save("explain", "Explain eli5", { project = true, cwd = repo }), "project override")
local merged = prompts.get("explain", repo)
assert(merged.text == "Explain eli5" and merged.source == "project", "project wins")
assert(#prompts.all(repo) == 2, "override does not duplicate")
assert(prompts.get("EXPLAIN", repo).name == "explain", "name lookup ignores case")

-- updating in place keeps its position, not a new entry
assert(prompts.save("explain", "Explain v2", { project = true, cwd = repo }))
assert(#prompts.all(repo) == 2, "update in place")

-- delete the project copy: the global one becomes visible again
assert(prompts.remove("explain", { cwd = repo }))
local back = prompts.get("explain", repo)
assert(back.text == "Explain {{selection}} in {{file}}" and back.source == "global", "global reappears")
assert(prompts.remove("explain", { cwd = repo }), "global can be removed too")
assert(prompts.get("explain") == nil, "gone")

-- saves reject empty input instead of writing junk
local ok, err = prompts.save("", "text")
assert(ok == false and err:find("name", 1, true), "empty name rejected")
ok, err = prompts.save("x", "  ")
assert(ok == false and err:find("text", 1, true), "empty text rejected")

-- rendering against a real anchor/buffer
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local a = 1", "local b = 2" })
vim.diagnostic.set(vim.api.nvim_create_namespace("t"), buf, {
	{ lnum = 0, col = 0, message = "unused", severity = vim.diagnostic.severity.WARN },
})
local anchor = {
	buf = buf,
	bufname = "fake.lua",
	path = "src/fake.lua",
	line = 7,
	col = 3,
	filetype = "lua",
	cwd = repo,
	modified = true,
	visual = { lines = { "local a = 1", "local b = 2" } },
}
local rendered = prompts.render(require("ask_agent.prompts").get("review", repo).text, anchor)
assert(rendered == "Review src/fake.lua for bugs", "file placeholder: " .. rendered)

local full = prompts.render(
	"{{file}}:{{line}}:{{col}} {{filetype}} in {{cwd}} [{{selection}}] diag={{diagnostics}} {{modified}}",
	anchor
)
assert(full:find("src/fake.lua:7:3 lua in " .. repo, 1, true), "location placeholders: " .. full)
assert(full:find("[local a = 1\nlocal b = 2]", 1, true), "selection placeholder")
assert(full:find("diag=1", 1, true), "diagnostics count")
assert(full:find("unsaved", 1, true), "modified marker")

-- unknown placeholders stay visible; empty values collapse cleanly
assert(prompts.render("{{nope}}", anchor) == "{{nope}}", "unknown kept")
assert(prompts.render("x{{selection}}y", {}) == "xy", "missing value is empty")
assert(prompts.render("{{cwd}}", nil) == vim.fn.getcwd(), "render without anchor")

vim.fn.delete(base, "rf")
print("PROMPTS OK")
