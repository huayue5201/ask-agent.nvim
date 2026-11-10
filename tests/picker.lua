-- Headless: nvim --headless --clean -l tests/picker.lua
-- The map is the primary picker: even a single locatable candidate goes through
-- it, and <Tab>/on_switch leads to the list with every candidate.
vim.opt.runtimepath:prepend(".")

local ask = require("ask_agent")
local queue = require("ask_agent.queue")
local layouts = require("ask_agent.layouts")

layout_id = "fake-layout"
layouts.register({
	id = "fake-layout",
	label = "fake",
	available = function()
		return true
	end,
	window = function()
		return { window_id = "w" }, {}
	end,
	panes = function()
		return { { id = "p", rect = { 0, 0, 1, 1 }, kind = "tiled" } }
	end,
	match = function()
		return "p"
	end,
})

local sent = {}
local target = { id = "42", label = "single", cwd = vim.fn.getcwd(), ts = 1, rex = { session = "s", block = "b" } }
ask.setup({
	bridge = false,
	persist = false,
	default = "fake",
	picker = "map",
	layout = "fake-layout",
	extra = {
		{
			id = "fake",
			label = "fake",
			targets = function()
				return { target }
			end,
			send = function(_, text)
				sent[#sent + 1] = text
				return true
			end,
		},
	},
})

local map = require("ask_agent.map")
local real = map.select
map.select = function(opts)
	map.select = real
	real_opts = opts
	-- choose the only cell, exactly like <CR> in the map
	opts.on_choose(opts.items[1])
end
map.stack = function(windows)
	return windows[1].panes
end

local entry = queue.add({ buf = vim.api.nvim_get_current_buf(), line = 1, col = 1, path = "x.lua" }, "hello")
assert(ask.batch_send({ ids = tostring(entry.id) }))
assert(real_opts, "the map opened for a sole candidate")
assert(#real_opts.items == 1 and real_opts.items[1].pane_id == "p", "the candidate is placed in its pane")
assert(type(real_opts.on_switch) == "function", "Tab switches to the cross-window list")
print("DEBUG", sent[1])
assert(sent[1] and sent[1]:match("hello"), "selecting the cell sent the question")

print("PICKER OK")
