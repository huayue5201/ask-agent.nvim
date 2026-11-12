-- Headless: nvim --headless --clean -l tests/review.lua
-- Covers the review adapters: patch text, the dependency-free builtin viewer, the HEAD
-- fallback when no turn exists, unsaved buffers folded into the end side of a tree
-- viewer, and clear errors outside a repository.
vim.opt.runtimepath:prepend(".")

local git = require("ask_agent.git")
local review = require("ask_agent.review")
local snapshot = require("ask_agent.snapshot")
local notify = require("ask_agent.notify")

local notes = {}
notify.notify = function(msg)
	notes[#notes + 1] = msg
end
snapshot.notify = false

local function sh(cwd, cmd)
	local res = vim.system({ "sh", "-c", cmd }, { cwd = cwd, text = true }):wait()
	assert(res.code == 0, ("cmd failed: %s\n%s"):format(cmd, res.stderr))
end

local repo = vim.fn.tempname()
vim.fn.mkdir(repo, "p")
sh(repo, "git init -q -b main && git config user.email t@t && git config user.name t")
sh(repo, "printf 'one\\ntwo\\n' > f.txt && git add -A && git commit -qm init")

snapshot.setup({ path = vim.fn.tempname(), enabled = true })

-- A turn with a change, reviewed as plain text (what any viewer would show)
local rec = assert(snapshot.begin({ cwd = repo, backend = "fake", agent = "1", trigger = "manual" }))
sh(repo, "printf 'one\\nTWO\\n' > f.txt && printf 'new\\n' > new.txt")
snapshot.finish(rec)

local text = assert(review.text(rec))
assert(text:find("-two", 1, true) and text:find("+TWO", 1, true), "patch shows the edit")
assert(text:find("new.txt", 1, true), "patch shows the new file")

-- Builtin viewer: a read-only diff buffer plus a quickfix list of changed files
vim.fn.setqflist({})
local ok = review.open({ id = rec.id, cwd = repo, backend = "builtin" })
assert(ok, "builtin viewer opens")
local buf = vim.api.nvim_get_current_buf()
assert(vim.bo[buf].filetype == "diff", "buffer is a diff")
assert(vim.bo[buf].modifiable == false, "diff buffer is read-only")
local qf = vim.fn.getqflist()
assert(#qf == 2, "quickfix lists both changed files: " .. #qf)
local names = {}
for _, item in ipairs(qf) do
	names[item.text] = true
end
assert(names["M f.txt"] and names["A new.txt"], "quickfix carries status + path")

-- A task can be reviewed through its correlation (what the dashboard's `v` uses)
local corr = { plugin = "test", key = 42 }
local linked =
	assert(snapshot.begin({ cwd = repo, backend = "fake", agent = "3", trigger = "dispatch", correlation = corr }))
sh(repo, "printf 'one\nTWO\nTHREE\n' > f.txt")
snapshot.finish(linked)
vim.fn.setqflist({})
assert(review.open({ correlation = corr, cwd = repo, backend = "builtin" }), "correlation resolves the turn")
assert(#vim.fn.getqflist() == 1, "correlated review lists the changed file")

-- Empty interval: no buffer, just a notice
local quiet = assert(snapshot.begin({ cwd = repo, backend = "fake", agent = "2", trigger = "manual" }))
snapshot.finish(quiet)
notes = {}
assert(review.open({ id = quiet.id, cwd = repo, backend = "builtin" }))
assert(notes[1] and notes[1]:find("no changes", 1, true), "empty turn reports no changes")

-- No turn at all: falls back to the whole worktree since HEAD
sh(repo, "printf 'one\\nTWO\\nthree\\n' > f.txt")
notes = {}
local ok_head = review.open({ cwd = repo, backend = "builtin", head = true })
assert(ok_head, "head fallback opens")
assert(vim.bo[vim.api.nvim_get_current_buf()].filetype == "diff", "head fallback renders a diff")
assert(#vim.fn.getqflist() >= 1, "head fallback has changes")

-- Tree viewer + unsaved buffer: an in-flight edit must reach the end side without
-- touching disk, which is how a live review stays honest.
local bufid = vim.fn.bufadd(repo .. "/f.txt")
vim.fn.bufload(bufid)
vim.api.nvim_buf_set_lines(bufid, 0, -1, false, { "one", "UNSAVED", "three" })
assert(vim.bo[bufid].modified, "buffer is modified")

local seen = {}
package.loaded["diffbandit"] = {
	folder_diff = function(left, right)
		seen.left = left
		seen.right = right
		seen.left_text = vim.fn.readfile(left .. "/f.txt")
		seen.right_text = vim.fn.readfile(right .. "/f.txt")
	end,
}
local rec2 = assert(snapshot.begin({ cwd = repo, backend = "fake", agent = "3", trigger = "manual" }))
sh(repo, "printf 'one\\nTWO\\nthree\\n\\n' > f.txt") -- committed worktree differs from the buffer
snapshot.finish(rec2)
assert(review.open({ id = rec2.id, cwd = repo, backend = "diffbandit" }), "tree viewer opens")
package.loaded["diffbandit"] = nil
assert(seen.left and seen.right, "folder_diff received both sides")
assert(seen.right_text[2] == "UNSAVED", "unsaved buffer wins on the end side: " .. vim.inspect(seen.right_text))
assert(seen.left_text[2] == "TWO", "start side is the captured tree")
assert(seen.right_text[1] == "one", "file is otherwise intact")

-- include_unsaved = false keeps the last written bytes
seen = {}
package.loaded["diffbandit"] = {
	folder_diff = function(_, right)
		seen.right_text = vim.fn.readfile(right .. "/f.txt")
	end,
}
assert(review.open({ id = rec2.id, cwd = repo, backend = "diffbandit", include_unsaved = false }))
package.loaded["diffbandit"] = nil
assert(seen.right_text[2] == "TWO", "include_unsaved=false uses disk bytes: " .. vim.inspect(seen.right_text))
review.include_unsaved = true

-- A tree viewer that refuses must fall through without raising
notes = {}
package.loaded["diffbandit"] = { broken = true }
local fell_back, fb_err = review.open({ id = rec2.id, cwd = repo, backend = "auto" })
package.loaded["diffbandit"] = nil
assert(fell_back, "auto falls back to an available viewer: " .. tostring(fb_err))

-- Outside a repository: clean failure, no viewer opened
local plain = vim.fn.tempname()
vim.fn.mkdir(plain, "p")
notes = {}
local ok_plain, err = review.open({ cwd = plain, backend = "builtin" })
assert(ok_plain == false and err == "not a git repository", "non-repository error")

vim.cmd("silent! %bwipeout!")
vim.fn.delete(repo, "rf")
vim.fn.delete(plain, "rf")
print("REVIEW OK")
