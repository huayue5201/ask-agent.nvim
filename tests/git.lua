-- Headless: nvim --headless --clean -l tests/git.lua
-- Covers the git plumbing: root detection, snapshot trees that never touch the real
-- index, untracked files, .gitignore, empty repositories, and diffs between two trees.
vim.opt.runtimepath:prepend(".")

local git = require("ask_agent.git")

local function sh(cwd, cmd)
	local res = vim.system({ "sh", "-c", cmd }, { cwd = cwd, text = true }):wait()
	assert(res.code == 0, ("cmd failed: %s\n%s"):format(cmd, res.stderr))
	return (res.stdout or ""):gsub("%s+$", "")
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
sh(dir, "git init -q -b main && git config user.email t@t && git config user.name t")
sh(dir, "printf 'one\\ntwo\\n' > a.txt && mkdir -p sub && printf 'x\\n' > sub/b.txt")
sh(dir, "printf 'ignored.txt\\n' > .gitignore")
sh(dir, "git add -A && git commit -qm init")

assert(git.root(dir) == sh(dir, "git rev-parse --show-toplevel"), "root detection")
assert(not git.root("/"), "a path outside a repository has no root")

-- A snapshot is a tree; taking it must not stage or touch the real index
local before = sh(dir, "git status --porcelain")
local t0 = assert(git.snapshot(dir))
assert(sh(dir, "git cat-file -t " .. t0) == "tree", "snapshot returns a tree")
assert(sh(dir, "git status --porcelain") == before, "snapshot leaves the index alone")

-- The agent writes: modified, new file, deleted, ignored
sh(dir, "printf 'one\\nSECOND-LINE-CHANGED\\n' > a.txt")
sh(dir, "printf 'new\\n' > new.txt")
sh(dir, "rm sub/b.txt")
sh(dir, "printf 'nope\\n' > ignored.txt")
local t1 = assert(git.snapshot(dir))

local files = assert(git.changed(dir, t0, t1))
local by_path = {}
for _, f in ipairs(files) do
	by_path[f.path] = f
end
assert(by_path["a.txt"] and by_path["a.txt"].status == "M", "modified file: " .. vim.inspect(files))
assert(by_path["new.txt"] and by_path["new.txt"].status == "A", "untracked file is part of the tree")
assert(by_path["sub/b.txt"] and by_path["sub/b.txt"].status == "D", "deleted file")
assert(not by_path["ignored.txt"], ".gitignore is honored")
assert(not by_path[".gitignore"], "unchanged files are absent")

local patch = assert(git.patch(dir, t0, t1))
assert(patch:find("+SECOND-LINE-CHANGED", 1, true), "patch shows the addition")
assert(patch:find("new.txt", 1, true), "patch includes the new file")

local stat = assert(git.stat(dir, t0, t1))
assert(stat:find("3 files changed", 1, true), "stat counts the three changes: " .. stat)

-- A tree also works as a "now" side, so the same interval is reproducible later
sh(dir, "printf 'new\\nedited-later\\n' > new.txt")
local later = assert(git.snapshot(dir))
local between = assert(git.changed(dir, t1, later))
assert(#between == 1 and between[1].path == "new.txt", "edits after the end boundary are excluded")

-- blob reads
assert(git.blob(dir, t0, "a.txt") == "one\ntwo\n", "blob at a tree")
assert(git.blob(dir, t0, "missing.txt") == nil, "missing blob is nil")

-- Rename detection (status R)
sh(dir, "git mv a.txt renamed.txt")
local t2 = assert(git.snapshot(dir))
local renamed = assert(git.changed(dir, t1, t2))
local found = false
for _, f in ipairs(renamed) do
	if f.status == "R" and f.old_path == "a.txt" and f.path == "renamed.txt" then
		found = true
	end
end
assert(found, "rename is detected")

-- commit-tree wraps a tree without creating a branch or moving HEAD
local head_before = sh(dir, "git rev-parse HEAD")
local c = assert(git.commit(dir, t2, "ask-agent test"))
assert(sh(dir, "git cat-file -t " .. c) == "commit")
assert(sh(dir, "git rev-parse HEAD") == head_before, "commit-tree does not move HEAD")
assert(sh(dir, "git branch --list | wc -l | tr -d ' '") == "1", "commit-tree creates no branch")

-- materialize extracts a tree into a directory
local out = git.tempdir("test-tree")
assert(git.materialize(dir, t0, out) == out)
assert(vim.fn.readfile(out .. "/a.txt")[2] == "two", "materialize writes the tree contents")

-- Empty (unborn) repository: write-tree still yields a tree, HEAD has no tree
local bare = vim.fn.tempname()
vim.fn.mkdir(bare, "p")
sh(bare, "git init -q -b main && printf 'fresh\\n' > f.txt")
local unborn = assert(git.snapshot(bare))
assert(sh(bare, "git cat-file -t " .. unborn) == "tree", "unborn repo still snapshots")

-- Non-repository: nil + reason, never an error
local plain = vim.fn.tempname()
vim.fn.mkdir(plain, "p")
local tree, err = git.snapshot(plain)
assert(tree == nil and type(err) == "string", "no repository → nil + err")

vim.fn.delete(dir, "rf")
vim.fn.delete(bare, "rf")
vim.fn.delete(plain, "rf")
vim.fn.delete(out, "rf")
print("GIT OK")
