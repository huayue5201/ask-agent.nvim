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
eq(context.describe(virtual), "codediff://" .. project .. "/src/a.lua", "describe names the buffer")

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

print("OK")
