-- Headless: nvim --headless --clean -l tests/chat_ui.lua
-- The window is a projection: posting updates it, mentions and pins are visible.
vim.opt.runtimepath:prepend(".")

local backends = require("ask_agent.backends")
local state = require("ask_agent.state")
local chat = require("ask_agent.chat")
local ui = require("ask_agent.chat_ui")

state.notify = false
state.persist = false
chat.persist = false

local sent = {}
backends.register({
	id = "group",
	label = "Group",
	targets = function()
		return { { id = "c1", cwd = "/repo", label = "claude" } }
	end,
	probe = function()
		return { running = true, state = "working" }
	end,
	send = function(_, text)
		sent[#sent + 1] = text
		return true
	end,
})

local win = ui.open({ thread = "ui", width = 44 })
local buf = vim.api.nvim_win_get_buf(win)
assert(vim.bo[buf].filetype == "ask-agent-chat", "filetype is set")
assert(vim.api.nvim_win_get_width(win) == 44, "requested width")

chat.post("hello there", { thread = "ui" })
vim.wait(220)
local function text()
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end
assert(text():find("me", 1, true), "the user bubble is rendered")
assert(text():find("hello there", 1, true), "the message is rendered")

chat.pin("ui", "the mapping is J")
vim.wait(220)
assert(text():find("facts", 1, true), "pins have a section")
assert(text():find("the mapping is J", 1, true), "the pinned fact is visible")

chat.post("@claude look at the tests", { thread = "ui" })
vim.wait(220)
assert(#sent == 1, "the mention was routed")
assert(sent[1]:find("the mapping is J", 1, true), "the agent's prompt carries the pin")
assert(text():find("look at the tests", 1, true), "the question is in the log")

chat.capture = function()
	return "the tests are fine"
end
chat.finish("group:c1", "done")
vim.wait(220)
assert(text():find("claude", 1, true), "the agent's answer is a bubble of its own")
assert(text():find("the tests are fine", 1, true), "the answer is visible")

-- long lines are wrapped to the window (never wider than the panel)
chat.post(string.rep("包装测试", 60), { thread = "ui" })
vim.wait(220)
local widest = 0
for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
	widest = math.max(widest, vim.fn.strdisplaywidth(l))
end
assert(widest <= 44, "wrapped to the panel, got " .. widest)

-- keys are wired: <CR>/i compose, gp pins, q closes
local keys = {}
for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
	keys[m.lhs] = true
end
assert(keys["<CR>"] and keys["i"] and keys["a"] and keys["gp"] and keys["gu"] and keys["q"], "keymaps")
assert(keys["gr"], "repaint key")

ui.close()
assert(not vim.api.nvim_win_is_valid(win), "closes")

print("CHATUI OK")
