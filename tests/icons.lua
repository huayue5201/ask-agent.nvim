-- Icon registry: one table for agent icons and every UI glyph (headless).
-- Run: nvim --headless --clean -l tests/icons.lua
vim.opt.runtimepath:prepend(".")

local icons = require("ask_agent.icons")

local fails = 0
local function check(name, cond, extra)
	if cond then
		print("PASS " .. name)
	else
		fails = fails + 1
		print("FAIL " .. name .. (extra and (" — " .. tostring(extra)) or ""))
	end
end

-- defaults
check("agent icon", icons.find("claude") ~= nil)
check("unknown agent -> fallback", icons.get("nope") == icons.fallback)
check("state glyph", icons.ui("state", "blocked") == "⚠", icons.ui("state", "blocked"))
check("task glyph", icons.ui("task", "done") == "✓")
check("tree glyph", icons.ui("tree", "collapsed") == "▸")
check("header", icons.header() ~= "")
check("spinner wraps", icons.spin(10) == icons.frames()[1])
check("spinner frame", icons.spin(1) == icons.frames()[2])

-- overrides: flat string = agent icon, `ui` group = UI glyphs
icons.setup({
	claude = "C",
	mine = "M",
	ui = {
		header = "H",
		state = { done = "D" },
		task = { queued = "Q" },
		tree = { leaf = "*" },
		spinner = { "1", "2" },
	},
})

check("agent override", icons.find("claude") == "C")
check("new agent key", icons.get("mine") == "M")
check("state override", icons.ui("state", "done") == "D")
check("state siblings kept", icons.ui("state", "blocked") == "⚠")
check("task override", icons.ui("task", "queued") == "Q")
check("task siblings kept", icons.ui("task", "done") == "✓")
check("tree override", icons.ui("tree", "leaf") == "*")
check("header override", icons.header() == "H")
check("spinner replaced", #icons.frames() == 2 and icons.spin(0) == "1" and icons.spin(1) == "2")

-- all() is a copy: mutating it must not change the registry
local snapshot = icons.all()
snapshot.ui.state.done = "X"
snapshot.claude = "X"
check("all() is a copy", icons.ui("state", "done") == "D" and icons.find("claude") == "C")
check("all() carries ui", snapshot.ui.header == "H")

if fails == 0 then
	print("ICONS OK")
	vim.cmd("qa!")
else
	print(fails .. " FAILED")
	vim.cmd("cq!")
end
