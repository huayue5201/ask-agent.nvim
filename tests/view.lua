-- Headless: nvim --headless --clean -l tests/view.lua
-- Viewer floats: provider registry, float lifetime, key model, builtin providers.
vim.opt.runtimepath:prepend(".")

local view = require("ask_agent.view")

-- registry: highest priority that can() wins
view.register({
	id = "low",
	priority = 1,
	can = function()
		return true
	end,
	cmd = function()
		return { cmd = { "true" } }
	end,
})
view.register({
	id = "high",
	priority = 50,
	can = function(t)
		return t.special == true
	end,
	cmd = function(t, opts)
		return { cmd = { "sh", "-c", "printf 'viewer %s'", t.id }, note = opts.readonly and "ro" or nil }
	end,
})
assert(view.find({ id = 1 }).id == "low", "fallback provider")
assert(view.find({ id = 1, special = true }).id == "high", "priority wins")
assert(view.find({}) and view.find({}).id == "low", "providers see any target")

-- no provider at all
local plain = { id = "x" }
view.register({
	id = "low",
	priority = 1,
	can = function()
		return false
	end,
	cmd = function()
		return { cmd = { "true" } }
	end,
})
local ok, err = view.open(plain)
assert(not ok and err:match("no view provider"), "unknown target: " .. tostring(err))

-- a real float: terminal buffer, closes on q, closing does not kill anything else
view.register({
	id = "test",
	priority = 100,
	can = function(t)
		return t.id == "float"
	end,
	cmd = function()
		return { cmd = { "sh", "-c", "printf 'hello from the agent'; sleep 5" }, width = 40, height = 10 }
	end,
})
local before = #vim.api.nvim_list_wins()
ok, err = view.open({ id = "float", label = "worker" })
assert(ok, "float opened: " .. tostring(err))
assert(#vim.api.nvim_list_wins() == before + 1, "one float window")
assert(vim.bo.filetype == "terminal", "terminal buffer in the float")
assert(vim.api.nvim_win_get_config(0).relative == "editor", "float is a floating window")
assert(vim.fn.maparg("q", "n", false, true).buffer == 1, "q closes the viewer")
assert(vim.fn.maparg("i", "n", false, true).buffer == 1, "i starts typing")
vim.wait(120)
local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
assert(text:match("hello from the agent"), "the command's output lands in the float: " .. text)
vim.api.nvim_feedkeys("q", "x", false)
vim.wait(80)
assert(#vim.api.nvim_list_wins() == before, "q closed the float")
assert(vim.fn.jobwait({}, 0), "no job leak check")

-- read-only: no insert keymap, and the provider sees readonly
local seen
view.register({
	id = "ro",
	priority = 100,
	can = function(t)
		return t.id == "ro"
	end,
	readonly_only = true,
	cmd = function(_, opts)
		seen = opts.readonly
		return { cmd = { "sh", "-c", "sleep 5" } }
	end,
})
ok = view.open({ id = "ro", label = "rex thing" })
assert(ok, "read-only float opens")
assert(seen == true, "readonly_only forces the readonly flag")
assert(vim.fn.maparg("i", "n", false, true).buffer ~= 1, "read-only viewer has no insert key")
view.close()
vim.wait(30)
assert(#vim.api.nvim_list_wins() == before, "view.close() closes the float")

-- the process ending closes the float by itself
view.register({
	id = "short",
	priority = 100,
	can = function(t)
		return t.id == "short"
	end,
	cmd = function()
		return { cmd = { "sh", "-c", "printf x" } }
	end,
})
ok = view.open({ id = "short" })
assert(ok, "short-lived viewer opens")
vim.wait(300)
assert(#vim.api.nvim_list_wins() == before, "TermClose closes the float")

-- tmux provider: attach to the pane's session, read-only with -r, no nested TMUX
local systems = {}
local real_system = vim.system
vim.system = function(cmd, _, cb)
	systems[#systems + 1] = cmd
	local function out()
		if cmd[2] == "display-message" then
			return { code = 0, stdout = "$7\n" }
		end
		return { code = 0, stdout = "" }
	end
	if cb then
		cb(out())
		return { pid = 1 }
	end
	return { pid = 1, wait = out }
end
local tmux = require("ask_agent.views.tmux")
local tmux_provider
for _, p in ipairs(view.list()) do
	if p.id == "tmux" then
		tmux_provider = p
	end
end
assert(tmux_provider and tmux_provider.can({ pane = "%3" }), "tmux handles pane targets")
local spec = tmux_provider.cmd({ pane = "%3" }, { readonly = true })
assert(
	vim.deep_equal(spec.cmd, { "tmux", "attach-session", "-r", "-t", "$7" }),
	"tmux readonly argv: " .. vim.inspect(spec.cmd)
)
assert(spec.env.TMUX == vim.NIL, "TMUX is dropped for the nested client")
local rw = tmux_provider.cmd({ pane = "$7" }, {})
assert(vim.deep_equal(rw.cmd, { "tmux", "attach-session", "-t", "$7" }), "tmux writable argv: " .. vim.inspect(rw.cmd))

-- herdr provider: agent attach, no --takeover unless the target asks for it
local herdr = require("ask_agent.views.herdr")
local herdr_provider
for _, p in ipairs(view.list()) do
	if p.id == "herdr" then
		herdr_provider = p
	end
end
assert(herdr_provider and herdr_provider.can({ herdr = { agent = "claude-1" } }), "herdr handles agent targets")
local hspec = herdr_provider.cmd({ herdr = { agent = "claude-1" } }, {})
assert(vim.deep_equal(hspec.cmd, { "herdr", "agent", "attach", "claude-1" }), "herdr argv: " .. vim.inspect(hspec.cmd))
local takeover = herdr_provider.cmd({ herdr = { id = "w", takeover = true } }, {})
assert(vim.deep_equal(takeover.cmd, { "herdr", "agent", "attach", "w", "--takeover" }), "takeover argv")
vim.system = real_system

-- rex provider: read-only by contract, needs a session, sizes the float to the block
local rex = require("ask_agent.views.rex")
local rex_provider
for _, p in ipairs(view.list()) do
	if p.id == "rex" then
		rex_provider = p
	end
end
assert(rex_provider and rex_provider.readonly_only, "rex viewer is read-only")
assert(rex_provider.can({ rex = { block = "b", session = "s" } }), "rex handles block targets")
local rok, rerr = rex_provider.cmd({ rex = { block = "b" } }, {})
assert(not rok and rerr:match("no session"), "rex needs a session: " .. tostring(rerr))

assert(view.describe():match("rex"), "describe lists providers: " .. view.describe())

print("VIEW OK")
