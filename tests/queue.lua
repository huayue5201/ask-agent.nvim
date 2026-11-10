-- tests/queue.lua
-- Run from the repo root: nvim --headless --clean -l tests/queue.lua
--
-- Covers: per-entry routing, subset sending (`batch_send({ ids })`), the unrouted
-- fallback to the target picker, and the "route points at a dead instance" path
-- (the entry must stay queued instead of being dropped).

vim.opt.rtp:prepend(vim.fn.getcwd())

local ask = require("ask_agent")
local queue = require("ask_agent.queue")

local sent = {}
local function instance(id)
	return { id = id, label = id, cwd = vim.fn.getcwd(), ts = 1 }
end
local targets = { instance("a"), instance("b") }

ask.setup({
	bridge = false,
	persist = false, -- the journal belongs to the user, not to this test
	default = "fake",
	extra = {
		{
			id = "fake",
			label = "fake",
			targets = function()
				return targets
			end,
			send = function(t, text)
				sent[#sent + 1] = { id = t.id, text = text }
				return true
			end,
		},
	},
})

local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
local cwd = vim.fn.getcwd()
for i = 1, 3 do
	local entry = queue.add({ buf = buf, line = i, path = "f.lua", cwd = cwd }, "q" .. i)
	if i < 3 then
		queue.route(entry.id, {
			backend = "fake",
			id = i == 1 and "a" or "b",
			ts = 1,
			name = i == 1 and "alpha" or "beta",
		})
	end
end
assert(queue.count() == 3, "three entries queued")
assert(queue.list()[1].route.name == "alpha", "route is stored on the entry")

-- subset: only #2, routed to b
assert(ask.batch_send({ ids = "2" }))
assert(#sent == 1 and sent[1].id == "b" and sent[1].text:match("q2"), "only #2 reached b")
assert(queue.count() == 2, "sent entry left the queue")

-- a malformed spec is rejected without touching the queue
assert(not ask.batch_send({ ids = "x" }))
assert(queue.count() == 2, "invalid selection changes nothing")

-- entries renumber after a removal: q3 is #2 now; unrouted, so it goes to the only target
targets = { instance("a") }
assert(ask.batch_send({ ids = "2" }))
assert(sent[2].id == "a" and sent[2].text:match("q3"), "unrouted entry used the picker")
assert(queue.count() == 1, "only the unrouted entry was sent")

-- routed to a dead instance: kept, nothing sent
targets = { instance("a"), instance("b") }
queue.route(queue.list()[1].id, { backend = "fake", id = "gone", name = "ghost" })
assert(ask.batch_send())
assert(#sent == 2 and queue.count() == 1, "dead route keeps the entry queued")

-- clearing the route makes it sendable again
assert(ask.batch_route(nil, { clear = true }))
assert(queue.list()[1].route == nil, "route cleared")
targets = { instance("a") }
assert(ask.batch_send())
assert(#sent == 3 and queue.count() == 0, "everything sent")

print("QUEUE OK")
