-- Headless: nvim --headless --clean -l tests/commands.lua
-- The commands are the public interface, so they all have to exist after setup().
vim.opt.runtimepath:prepend(".")

local ask = require("ask_agent")
ask.setup({
	bridge = false,
	persist = false,
	state_interval = 60000,
	default = "fake",
	extra = {
		{
			id = "fake",
			label = "fake",
			targets = function()
				return {}
			end,
			send = function()
				return true
			end,
		},
	},
})

local want = {
	"AskAgent",
	"AskAgentVisual",
	"AskAgentBatch",
	"AskAgentBatchVisual",
	"AskAgentBatchSend",
	"AskAgentBatchRoute",
	"AskAgentBatchList",
	"AskAgentBatchDelete",
	"AskAgentBatchUndo",
	"AskAgentBatchClear",
	"AskAgentDashboard",
	"AskAgentPi",
	"AskAgentBackend",
	"AskAgentPicker",
	"AskAgentTarget",
	"AskAgentRename",
}
for _, name in ipairs(want) do
	assert(vim.fn.exists(":" .. name) == 2, "missing command :" .. name)
end

-- :AskAgentPicker toggles and :AskAgentPicker! is not a thing (no bang)
assert(ask.picker() == "map", "default picker")
vim.cmd("AskAgentPicker list")
assert(ask.picker() == "list", "picker switches to list")
vim.cmd("AskAgentPicker")
assert(ask.picker() == "map", "no argument toggles back")
vim.cmd("AskAgentPicker nonsense")
assert(ask.picker() == "map", "invalid picker keeps the old one")

print("COMMANDS OK")
