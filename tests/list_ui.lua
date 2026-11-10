-- Headless: nvim --headless --clean -l tests/list_ui.lua
-- The list picker prefers ui-menu (centered + <Tab> round-trip) and can be
-- forced back to vim.ui.select without losing the list.
vim.opt.runtimepath:prepend(".")

local ask = require("ask_agent")
local queue = require("ask_agent.queue")

local target = {
	id = "7",
	label = "agent",
	cwd = vim.fn.getcwd(),
	ts = 1,
	rex = { session = "s", block = "b" },
}
local other = {
	id = "8",
	label = "other",
	cwd = vim.fn.getcwd() .. "/other",
	ts = 2,
	rex = { session = "s", block = "b2" },
}
local sent = {}
ask.setup({
	bridge = false,
	persist = false,
	default = "fake",
	picker = "list",
	extra = {
		{
			id = "fake",
			label = "fake",
			targets = function()
				return { target, other }
			end,
			send = function(_, text)
				sent[#sent + 1] = text
				return true
			end,
		},
	},
})

local seen
package.loaded["ui_menu"] = {
	select = function(items, opts, on_choice)
		seen = { items = items, opts = opts }
		on_choice(items[1])
	end,
}

assert(ask.list_impl() == "auto", "auto is the default")
local _ = queue.add({ buf = vim.api.nvim_get_current_buf(), line = 1, col = 1, path = "x.lua" }, "hello")
assert(ask.batch_send())
assert(seen, "auto picks ui-menu when it is installed")
assert(seen.opts.position == "center", "the list is screen-centered")
assert(type(seen.opts.on_tab) == "function", "<Tab> is handed back to the caller")
assert(sent[1] and sent[1]:match("hello"), "choosing from ui-menu still sends")

-- Forced vim.ui.select path
package.loaded["ui_menu"] = nil
local vim_seen
local real_select = vim.ui.select
vim.ui.select = function(items, opts, on_choice)
	vim_seen = { items = items, opts = opts }
	on_choice(items[1])
end
ask.list_impl("vim_ui")
local _ = queue.add({ buf = vim.api.nvim_get_current_buf(), line = 1, col = 1, path = "y.lua" }, "world")
assert(ask.batch_send())
vim.ui.select = real_select
assert(vim_seen, "vim_ui bypasses ui-menu")
assert(sent[2] and sent[2]:match("world"), "vim.ui.select path still sends")

print("LIST_UI OK")
