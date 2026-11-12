-- lua/ask_agent/git.lua
---@brief Git plumbing for "what did the agent change": snapshot the worktree into a
---tree object without touching the user's index, and diff two trees.
--
-- Why a tree and not `git diff HEAD`: a tree is a *point in time* that stays valid
-- after the user keeps editing. Two trees (the agent's turn start and end) therefore
-- describe exactly one interval, reproducible later by anyone holding the two oids.
-- Trees also include untracked files, which `git diff HEAD` never shows.
--
-- The snapshot never touches the real index: it copies `.git/index` to a temp file,
-- sets GIT_INDEX_FILE and runs `git add -A` + `git write-tree` against the copy.
-- Nothing is written to refs, nothing is staged, `git status` stays as it was.
--
-- All calls are synchronous (vim.system): a snapshot costs about one `git status`,
-- a few milliseconds to a few hundred on a big repository. Callers must never let a
-- failure escape: outside a repository every function returns nil + reason.

local M = {}

local roots = {} -- dir -> root | false

---Run git in `dir`. Returns ok, stdout|err, stderr.
---@param dir string
---@param args string[]
---@param opts { env?: table<string,string>, cwd?: string }|nil
---@return boolean ok, string out, string|nil err
function M.git(dir, args, opts)
	opts = opts or {}
	local cmd = { "git", "--no-optional-locks", "--no-pager", "-C", opts.cwd or dir }
	vim.list_extend(cmd, args)
	local res = vim.system(cmd, { text = true, env = opts.env }):wait()
	if res.code ~= 0 then
		return false, res.stdout or "", (res.stderr ~= "" and res.stderr) or ("git exited with " .. tostring(res.code))
	end
	return true, res.stdout or "", nil
end

---The worktree root of `dir`, or nil when it is not inside a repository.
---@param dir string|nil
---@return string|nil
function M.root(dir)
	dir = dir or vim.fn.getcwd()
	if roots[dir] ~= nil then
		return roots[dir] or nil
	end
	local ok, out = M.git(dir, { "rev-parse", "--show-toplevel" })
	local root = ok and vim.trim(out) or nil
	if root == "" then
		root = nil
	end
	roots[dir] = root or false
	return root
end

---Forget cached roots (tests, or after a `:cd` into a fresh repository).
function M.reset()
	roots = {}
end

---Whether `dir` is inside a git repository.
---@param dir string|nil
---@return boolean
function M.available(dir)
	return M.root(dir) ~= nil
end

---Snapshot the worktree of `dir` into a tree object.
---Includes tracked modifications and untracked (non-ignored) files; never mutates the
---index, never stages anything, never writes a ref.
---@param dir string|nil
---@return string|nil tree, string|nil err
function M.snapshot(dir)
	local root = M.root(dir)
	if not root then
		return nil, "not a git repository"
	end
	local ok, gitdir = M.git(root, { "rev-parse", "--absolute-git-dir" })
	if not ok then
		return nil, gitdir
	end
	local index = vim.fs.joinpath(vim.trim(gitdir), "index")
	local tmp = vim.fn.tempname()
	-- Seed from the real index when it exists: `add -A` then only has to refresh what
	-- changed, instead of hashing every file in the worktree.
	if vim.uv.fs_stat(index) then
		local copied = vim.uv.fs_copyfile(index, tmp)
		if not copied then
			tmp = vim.fn.tempname() -- fall back to an empty index; `add -A` still works
		end
	end
	local env = { GIT_INDEX_FILE = tmp }
	local added, _, add_err = M.git(root, { "add", "-A" }, { env = env })
	if not added then
		os.remove(tmp)
		return nil, add_err
	end
	local written, tree, write_err = M.git(root, { "write-tree" }, { env = env })
	os.remove(tmp)
	if not written then
		return nil, write_err
	end
	return vim.trim(tree)
end

---Changed files between two trees (or a tree and "now" when `to` is nil, which cannot
---see untracked files — callers should pass a second snapshot instead).
---@param root string
---@param from string
---@param to string|nil
---@return { status: string, path: string, old_path?: string }[]|nil files, string|nil err
function M.changed(root, from, to)
	local args = { "diff", "--name-status", "-z", "-M", from }
	if to then
		table.insert(args, to)
	end
	table.insert(args, "--")
	local ok, out, err = M.git(root, args)
	if not ok then
		return nil, err
	end
	local fields, files = {}, {}
	for field in out:gmatch("([^%z]*)%z") do
		fields[#fields + 1] = field
	end
	local i = 1
	while i <= #fields do
		local status = fields[i]
		if status == "" then
			break
		end
		local kind = status:sub(1, 1)
		if kind == "R" or kind == "C" then
			files[#files + 1] = { status = kind, old_path = fields[i + 1], path = fields[i + 2] }
			i = i + 3
		else
			files[#files + 1] = { status = kind, path = fields[i + 1] }
			i = i + 2
		end
	end
	return files
end

---`git diff --stat` text between two points.
---@param root string
---@param from string
---@param to string|nil
---@return string|nil text, string|nil err
function M.stat(root, from, to)
	local args = { "diff", "--stat", "--no-color", from }
	if to then
		table.insert(args, to)
	end
	table.insert(args, "--")
	local ok, out, err = M.git(root, args)
	return ok and out or nil, err
end

---Unified patch text between two points (what the builtin viewer shows).
---@param root string
---@param from string
---@param to string|nil
---@param path string|nil limit to one path
---@return string|nil text, string|nil err
function M.patch(root, from, to, path)
	local args = { "diff", "--no-color", from }
	if to then
		table.insert(args, to)
	end
	table.insert(args, "--")
	if path then
		table.insert(args, path)
	end
	local ok, out, err = M.git(root, args)
	return ok and out or nil, err
end

---Contents of `path` at `tree`, as a string.
---@param root string
---@param tree string
---@param path string
---@return string|nil text
function M.blob(root, tree, path)
	local ok, out = M.git(root, { "show", tree .. ":" .. path })
	if not ok then
		return nil
	end
	return out
end

---Wrap a tree in a commit object (no ref, no branch) for tools that insist on a
---commit-ish, e.g. codediff's `rev-parse --verify` / `rev-list` paths.
---@param root string
---@param tree string
---@param msg string
---@param parent string|nil
---@return string|nil oid, string|nil err
function M.commit(root, tree, msg, parent)
	local args = { "commit-tree", tree }
	if parent then
		vim.list_extend(args, { "-p", parent })
	end
	vim.list_extend(args, { "-m", msg })
	local ok, out, err = M.git(root, args)
	if not ok then
		return nil, err
	end
	return vim.trim(out)
end

---Extract a tree into `dest` (created when missing). Used by the directory-based
---viewers (nvim.difftool, diffbandit.folder_diff).
---@param root string
---@param tree string
---@param dest string
---@return string|nil dest, string|nil err
function M.materialize(root, tree, dest)
	vim.fn.mkdir(dest, "p")
	local tar = vim.fn.tempname() .. ".tar"
	local ok, _, err = M.git(root, { "archive", "--format=tar", "-o", tar, tree })
	if not ok then
		os.remove(tar)
		return nil, err
	end
	local res = vim.system({ "tar", "-xf", tar, "-C", dest }, { text = true }):wait()
	os.remove(tar)
	if res.code ~= 0 then
		return nil, res.stderr ~= "" and res.stderr or "tar failed"
	end
	return dest
end

---A fresh temp directory (not removed by us; the OS cleans /tmp).
---@param prefix string|nil
---@return string
function M.tempdir(prefix)
	return vim.fn.tempname() .. "-" .. (prefix or "ask-agent")
end

return M
