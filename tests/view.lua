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
assert(vim.fn.maparg("<C-q>", "t", false, true).buffer == 1, "<C-q> leaves terminal mode and closes")
assert(vim.fn.maparg("i", "n", false, true).buffer == 1, "i starts typing")
vim.wait(120)
local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
assert(text:match("hello from the agent"), "the command's output lands in the float: " .. text)
-- a writable viewer opens in terminal mode (type right away, like :terminal)
vim.wait(60)
-- headless has no UI, so the terminal mode reports as "nt"; a real UI reports "t"
assert(
	vim.api.nvim_get_mode().mode:match("t"),
	"writable viewer starts in terminal mode: " .. vim.api.nvim_get_mode().mode
)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-q>", true, false, true), "x", false)
vim.wait(80)
assert(#vim.api.nvim_list_wins() == before, "<C-q> closed the float")
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

-- a grid larger than the screen: crop (never wrap) and say so in the footer
view.register({
	id = "big",
	priority = 100,
	can = function(t)
		return t.id == "big"
	end,
	cmd = function()
		return { cmd = { "sh", "-c", "sleep 5" }, width = 200, height = 40 }
	end,
})
ok = view.open({ id = "big", label = "wide agent" })
assert(ok, "clipped viewer opens")
local cfg = vim.api.nvim_win_get_config(0)
local function chunk_text(chunks)
	local out = {}
	for _, c in ipairs(chunks or {}) do
		out[#out + 1] = c[1]
	end
	return table.concat(out)
end
local title = chunk_text(cfg.title)
local footer = chunk_text(cfg.footer)
assert(vim.wo[0].wrap == false, "a clipped grid is cropped, not wrapped")
assert(title:match("wide agent"), "the title names the agent: " .. title)
assert(footer:match("<C%-q> close"), "the footer lists the close key: " .. footer)
assert(footer:match("clipped 200"), "the footer reports the crop: " .. footer)
view.close()
vim.wait(30)
assert(#vim.api.nvim_list_wins() == before, "closing the clipped viewer")

-- one viewer per agent: opening again focuses the existing float
local count
ok = view.open({ id = "big", label = "wide agent" }, { key = "dup" })
count = #vim.api.nvim_list_wins()
assert(ok, "re-opening focuses instead of failing")
ok = view.open({ id = "big", label = "wide agent" }, { key = "dup" })
assert(ok, "re-opening focuses instead of failing")
vim.wait(30)
assert(#vim.api.nvim_list_wins() == count, "no duplicate float for the same agent")
view.close()
vim.wait(30)
assert(#vim.api.nvim_list_wins() == before, "the duplicate check left one float behind?")

-- the float follows the agent's lifecycle: gone means closed
local backends = require("ask_agent.backends")
local alive = true
backends.register({
	id = "fakeview",
	label = "fake",
	targets = function()
		return { { id = "a1", label = "tiny agent", cwd = "/tmp", backend = "fakeview" } }
	end,
	send = function()
		return true
	end,
	probe = function()
		return { running = alive, state = "idle" }
	end,
})
local state = require("ask_agent.state")
state.notify = false
state.refresh()
view.register({
	id = "tiny",
	priority = 100,
	can = function(t)
		return t.id == "a1"
	end,
	cmd = function()
		return { cmd = { "sh", "-c", "sleep 5" } }
	end,
})
ok = view.open({ id = "a1", backend = "fakeview", label = "tiny agent" })
assert(ok, "a viewer for a tracked agent opens")
alive = false
state.refresh()
vim.wait(300)
assert(#vim.api.nvim_list_wins() == before, "a viewer closes when its agent is gone")

-- tmux provider: attach to the pane's session, read-only with -r, no nested TMUX
local systems = {}
local real_system = vim.system
vim.system = function(cmd, _, cb)
	systems[#systems + 1] = cmd
	local function out()
		if cmd[2] == "display-message" then
			local fmt = cmd[#cmd]
			if fmt == "#{window_width}x#{window_height}" then
				return { code = 0, stdout = "80x24\n" }
			elseif fmt == "#{status}" then
				return { code = 0, stdout = "on\n" }
			end
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
	vim.deep_equal(spec.cmd, { "tmux", "attach-session", "-f", "ignore-size", "-r", "-t", "$7" }),
	"tmux readonly argv: " .. vim.inspect(spec.cmd)
)
-- jobstart turns vim.NIL into the string "v:null", so a fresh client must get a
-- copy of the environment with the keys actually absent
assert(spec.env.TMUX == nil, "TMUX is dropped for the nested client: " .. tostring(spec.env.TMUX))
assert(spec.env.TMUX_PANE == nil, "TMUX_PANE is dropped for the nested client")
assert(type(spec.env.PATH) == "string", "the rest of the environment survives")
-- the float matches the client grid: window rows + one status row
assert(
	spec.width == 80 and spec.height == 25,
	"tmux window size: " .. tostring(spec.width) .. "x" .. tostring(spec.height)
)
local rw = tmux_provider.cmd({ pane = "$7" }, {})
assert(
	vim.deep_equal(rw.cmd, { "tmux", "attach-session", "-f", "ignore-size", "-t", "$7" }),
	"tmux writable argv: " .. vim.inspect(rw.cmd)
)

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

-- rex provider: a writable mirror (keys are forwarded), needs a session, sizes
-- the float to the block
local rex = require("ask_agent.views.rex")
local rex_provider
for _, p in ipairs(view.list()) do
	if p.id == "rex" then
		rex_provider = p
	end
end
assert(rex_provider and not rex_provider.readonly_only, "rex viewer forwards keys")
assert(rex_provider.can({ rex = { block = "b", session = "s" } }), "rex handles block targets")
local rspec = rex_provider.cmd({ rex = { block = "b", session = "s" } }, {})
assert(rspec and rspec.cmd[#rspec.cmd] == "s", "rex argv carries the session: " .. vim.inspect(rspec and rspec.cmd))
local rro = rex_provider.cmd({ rex = { block = "b", session = "s" } }, { readonly = true })
assert(rro and rro.cmd[#rro.cmd] == "--readonly", "readonly reaches the helper")

-- the size lookup must carry the session: without it `block call` cannot resolve
-- the block from outside the session and the float falls back to a guessed grid
local rex_cmds = {}
vim.system = function(cmd, _, cb)
	rex_cmds[#rex_cmds + 1] = cmd
	local out = { code = 0, stdout = "" }
	if cmd[#cmd] == "size" then
		out.stdout = '{"columns":120,"rows":40}\n'
	end
	if cb then
		cb(out)
		return { pid = 1 }
	end
	return {
		pid = 1,
		wait = function()
			return out
		end,
	}
end
local sized = rex_provider.cmd({ rex = { block = "b", session = "s" } }, {})
vim.system = real_system
local size_cmd
for _, c in ipairs(rex_cmds) do
	if c[#c] == "size" then
		size_cmd = c
	end
end
assert(
	size_cmd and vim.deep_equal(size_cmd, { "rex", "block", "call", "-b", "b", "-s", "s", "size" }),
	"size query carries the session: " .. vim.inspect(size_cmd)
)
assert(sized.width == 120 and sized.height == 40, "the float follows the block grid: " .. vim.inspect(sized))
local rok, rerr = rex_provider.cmd({ rex = { block = "b" } }, {})
assert(not rok and rerr:match("no session"), "rex needs a session: " .. tostring(rerr))

assert(view.describe():match("rex"), "describe lists providers: " .. view.describe())

print("VIEW OK")
