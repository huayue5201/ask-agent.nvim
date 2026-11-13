-- Headless: nvim --headless --clean -l tests/anchor.lua
-- An anchor taken in a diff is not an anchor to a project file: a plugin buffer
-- has no path at all, and a snapshot is a copy of the tree at that revision.
vim.opt.runtimepath:prepend(".")

local context = require("ask_agent.context")
local message = require("ask_agent.message")

local function eq(actual, expected, what)
	if actual ~= expected then
		error(("%s: expected %q, got %q"):format(what, tostring(expected), tostring(actual)), 2)
	end
end

local project = vim.fn.tempname() .. "-project"
vim.fn.mkdir(project .. "/src", "p")
vim.fn.writefile({ "one", "two", "three" }, project .. "/src/a.lua")

-- 1. a plugin buffer (`codediff://…`, `fugitive://…`) travels as a name only
vim.cmd("enew")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "patched" })
vim.api.nvim_buf_set_name(0, "codediff://" .. project .. "/src/a.lua")
local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].modified = false
local virtual = context.capture()
eq(virtual.virtual, "codediff", "scheme is recorded")
eq(virtual.path, nil, "a plugin buffer has no path")
eq(virtual.snapshot, nil, "and is not a snapshot")
assert(
	context.describe(virtual):find("codediff://" .. project .. "/src/a.lua", 1, true) == 1,
	"describe names the buffer: " .. context.describe(virtual)
)

local ok, err = context.open(virtual)
eq(ok, false, "open refuses a plugin buffer")
assert(err:find("plugin buffer (codediff://)", 1, true), "and says why: " .. tostring(err))

local text = message.render(virtual, "why did this change?")
assert(text:find("<nvim-context codediff://", 1, true), "the agent is given the buffer name:\n" .. text)
assert(not text:find("codediff://codediff://", 1, true), "the name is not decorated twice")

-- 2. a file inside an extracted tree is a snapshot: readable, but not the file
local tree = vim.fn.tempname() .. "-ask-agent-tree"
vim.fn.mkdir(tree .. "/src", "p")
vim.fn.writefile({ "old one", "old two" }, tree .. "/src/a.lua")
vim.cmd("edit! " .. vim.fn.fnameescape(tree .. "/src/a.lua"))
local snap = context.capture()
eq(snap.snapshot, "src/a.lua", "the path inside the tree is recorded")
assert(
	snap.path == vim.fn.resolve(tree) .. "/src/a.lua",
	"the copy is still the path the agent reads: " .. tostring(snap.path)
)

local snap_text = message.render(snap, "is this what you meant?")
assert(snap_text:find("a diff snapshot of src/a.lua", 1, true), "the agent learns it is a snapshot:\n" .. snap_text)
assert(snap_text:find("don't edit it", 1, true), "and is told not to edit it")

-- the copy is gone (babysitter cleaned /tmp): the jump goes to the project file
vim.api.nvim_buf_delete(vim.api.nvim_get_current_buf(), { force = true })
vim.cmd("cd " .. vim.fn.fnameescape(project))
local ok_jump, err_jump = context.open(snap)
eq(ok_jump, true, "a snapshot jump finds the project file: " .. tostring(err_jump))
eq(vim.api.nvim_buf_get_name(0), vim.fn.resolve(project) .. "/src/a.lua", "and opens that one, not the copy")
eq(vim.api.nvim_win_get_cursor(0)[1], 1, "at the recorded line")

-- 3. the snapshot's file does not exist in the project (added then reverted)
local gone = vim.deepcopy(snap)
gone.snapshot = "src/nope.lua"
gone.buf = -1
local ok_gone, err_gone = context.open(gone)
eq(ok_gone, false, "a missing project file is reported, not opened")
assert(err_gone:find("no such file", 1, true), "with a reason: " .. tostring(err_gone))

-- 4. an unsaved buffer carries its own source: the file on disk is a different file
vim.cmd("cd " .. vim.fn.fnameescape(project))
vim.cmd("edit! " .. vim.fn.fnameescape(project .. "/src/a.lua"))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one", "two CHANGED", "three" })
vim.api.nvim_win_set_cursor(0, { 2, 0 })
local dirty = context.capture()
eq(dirty.modified, true, "the buffer is unsaved")
assert(dirty.context, "an unsaved buffer brings its text")
eq(dirty.context.start_line, 1, "the snippet starts at the top of a short file")
eq(dirty.context.end_line, 3, "and ends at the bottom")
local dirty_text = message.render(dirty, "is this right?")
assert(dirty_text:find("context (lines 1-3):", 1, true), "the agent sees the range:\n" .. dirty_text)
assert(dirty_text:find("two CHANGED", 1, true), "and the text itself, not what is on disk")

-- a saved file needs no copy: `path:line` is enough, the agent reads it
vim.bo.modified = false
local clean = context.capture()
eq(clean.context, nil, "a saved file does not inline itself")
assert(not message.render(clean, "q"):find("context (lines", 1, true), "and the message stays short")

-- 5. a bounded snippet: lines around the cursor, not the whole buffer
vim.bo.modified = true
local many = {}
for i = 1, 200 do
	many[i] = "line " .. i
end
vim.api.nvim_buf_set_lines(0, 0, -1, false, many)
vim.api.nvim_win_set_cursor(0, { 100, 0 })
context.setup({ lines = 5 })
local wide = context.capture()
eq(wide.context.start_line, 95, "the snippet starts `lines` above the cursor")
eq(wide.context.end_line, 105, "and ends `lines` below it")
context.setup({ lines = 20 })

-- 6. a selection has a ceiling, and the agent is told it was cut
local long = {}
for i = 1, 400 do
	long[i] = string.rep("x", 10) -- short enough that the line ceiling hits first
end
local clipped = context.clip_selection(long)
assert(clipped.clipped, "an oversized selection is clipped")
eq(#clipped.lines, context.max_selection, "to max_selection lines")
eq(clipped.lines[1], long[1], "keeping the start")
local small = context.clip_selection({ "a", "b" })
eq(small.clipped, nil, "a small selection is left alone")
eq(#small.lines, 2, "and kept whole")

-- 7. a repository gives the anchor its root, its branch and a root-relative path
vim.fn.system({ "git", "-C", project, "init", "-q", "-b", "main" })
vim.fn.system({ "git", "-C", project, "add", "-A" })
vim.fn.system({
	"git",
	"-C",
	project,
	"-c",
	"user.email=t@t",
	"-c",
	"user.name=t",
	"commit",
	"-qm",
	"init",
})
require("ask_agent.git").reset()
vim.cmd("edit! " .. vim.fn.fnameescape(project .. "/src/a.lua"))
local repo = context.capture()
eq(repo.root, vim.fn.resolve(project), "the repository root is recorded")
eq(repo.branch, "main", "and the branch")
eq(repo.rel, "src/a.lua", "and the path relative to the root")
local repo_text = message.render(repo, "q")
assert(
	repo_text:find("src/a.lua:3 · branch main", 1, true),
	"the header uses the root-relative path and the branch:\n" .. repo_text
)
assert(repo_text:find("root: " .. vim.fn.resolve(project), 1, true), "and the root is spelled out")

-- 8. diagnostics on the cursor line travel with the question
local ns = vim.api.nvim_create_namespace("anchor-test")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.diagnostic.set(ns, 0, {
	{ lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = "undefined variable", source = "test-ls" },
})
local with_diag = context.capture()
assert(with_diag.diagnostics and #with_diag.diagnostics == 1, "the cursor-line diagnostic is kept")
eq(with_diag.diagnostics[1].severity, "error", "with its severity")
local diag_text = message.render(with_diag, "q")
assert(diag_text:find("test-ls:1: error: undefined variable", 1, true), "and reaches the agent:\n" .. diag_text)
vim.diagnostic.reset(ns, 0)

-- 9. the journal keeps the coordinate, not the source
local lean = context.lean(vim.tbl_extend(
	"force",
	with_diag,
	{ context = { start_line = 1, end_line = 2, lines = {
		"a",
		"b",
	} } }
))
eq(lean.context, nil, "lean drops the inlined source")
eq(lean.diagnostics, nil, "and the diagnostics")
eq(lean.line, with_diag.line, "but keeps the line")
eq(lean.path, with_diag.path, "the path")
eq(lean.root, with_diag.root, "and the repository identity")

print("OK")
