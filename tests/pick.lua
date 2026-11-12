-- Headless: nvim --headless --clean -l tests/pick.lua
-- ask.send({ pick = true }) is the seam other plugins use (todo2's K): a sole
-- same-project candidate must go straight out, anything ambiguous must ask.
vim.opt.runtimepath:prepend(".")

local ask = require("ask_agent")

local sent = {}
local targets = {}
local function backend(id, list)
	return {
		id = id,
		label = id,
		targets = function()
			return list
		end,
		available = function()
			return true
		end,
		send = function(t, text)
			sent[#sent + 1] = { id = t.id, text = text }
			return true
		end,
	}
end

local cwd = vim.fn.getcwd()
targets.two = {
	{ id = "a", label = "alpha", cwd = cwd, ts = 1 },
	{ id = "b", label = "beta", cwd = cwd, ts = 2 },
}

ask.setup({
	bridge = false,
	persist = false,
	state_interval = 999999,
	default = "two",
	picker = "list",
	extra = { backend("two", targets.two) },
})
ask.list_impl("vim_ui")

-- 1) ambiguous: the picker has to appear, and nothing is sent before a choice
local asked = 0
local real_select = vim.ui.select
local wanted
vim.ui.select = function(items, opts, on_choice)
	asked = asked + 1
	assert(#items == 2, "both candidates are offered: " .. #items)
	-- the list is ordered by activity, so pick by identity, not by index
	wanted = items[2].target.id
	on_choice(items[2])
end

local reported = {}
local ok = ask.send("hello", {
	pick = true,
	on_sent = function(done, err)
		reported[#reported + 1] = { done, err }
	end,
})
assert(ok, "send accepted the request")
assert(asked == 1, "one picker: " .. asked)
assert(#sent == 1 and sent[1].id == wanted, "the chosen instance got the text: " .. vim.inspect(sent))
assert(reported[1] and reported[1][1] == true, "on_sent reports success")

-- 2) cancelling the picker sends nothing and reports why
asked = 0
vim.ui.select = function(_, _, on_choice)
	asked = asked + 1
	on_choice(nil)
end
reported = {}
ask.send("second", {
	pick = true,
	on_sent = function(done, err)
		reported[#reported + 1] = { done, err }
	end,
})
assert(asked == 1, "the picker was cancelled once")
assert(#sent == 1, "a cancelled picker sends nothing: " .. #sent)
assert(reported[1] and reported[1][1] == false and reported[1][2] == "no target chosen", "cancel is reported")

-- 3) one candidate in this project: no prompt, straight out
asked = 0
vim.ui.select = function()
	asked = asked + 1
end
local sole = { { id = "solo", label = "solo", cwd = cwd, ts = 1 } }
ask.register(backend("solo", sole))
ask.use("solo")
ask.send("third", { pick = true })
assert(asked == 0, "a sole same-project candidate is not a question: " .. asked)
assert(#sent == 2 and sent[2].id == "solo", "it went out: " .. vim.inspect(sent))

-- 4) an explicit target skips the picker entirely
asked = 0
vim.ui.select = function()
	asked = asked + 1
end
ask.use("two")
ask.send("fourth", { pick = true, target = "a" })
assert(asked == 0, "an explicit target is not a question")
assert(sent[3].id == "a", "it went to the named instance")

vim.ui.select = real_select
print("OK")
