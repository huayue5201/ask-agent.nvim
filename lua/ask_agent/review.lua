-- lua/ask_agent/review.lua
---@brief Show "what the agent changed" in whatever diff viewer the user already has.
--
-- The plugin owns the *points* (snapshot.lua turns them into two git trees), never the
-- rendering: diff UIs are a solved, crowded problem (diffbandit, codediff, and Neovim
-- 0.12's builtin nvim.difftool), so review.lua only picks one and hands it two things
-- to compare. When none is installed the builtin scratch buffer still shows the full
-- patch, so review never requires a dependency.
--
-- Backends, best first:
--   diffbandit   folder_diff(left, right)  — richest rendering, buffer-level support
--   difftool     nvim.difftool (0.12+)     — zero install, rename detection
--   codediff     :CodeDiff <commit> <commit> — commit-ish only, so trees are wrapped
--   builtin      one buffer, filetype=diff  — no dependencies at all
--
-- Directory-based viewers get both trees extracted to temp dirs. Unsaved buffers are
-- written into the *end* extraction, which is how an in-flight edit becomes reviewable
-- without touching disk or staging anything.

local git = require("ask_agent.git")
local snapshot = require("ask_agent.snapshot")
local notify = require("ask_agent.notify")

local M = {}

---"auto" (first available) or one of diffbandit / difftool / codediff / builtin.
M.backend = "auto"
---Fold unsaved buffers into the end side of the comparison.
M.include_unsaved = true

local materialized = {} -- tree oid -> directory

---@param tree string
---@param root string
---@return string|nil dir
local function materialize(tree, root)
	if materialized[tree] then
		return materialized[tree]
	end
	local dir = git.materialize(root, tree, git.tempdir("ask-agent-tree"))
	if not dir then
		return nil
	end
	materialized[tree] = dir
	return dir
end

---Every modified, loaded, plain buffer inside `root` (the freshest version of a file).
---@param root string
---@return { buf: integer, rel: string }[]
local function unsaved_buffers(root)
	local out = {}
	local prefix = root:gsub("/+$", "") .. "/"
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified and vim.bo[buf].buftype == "" then
			local name = vim.api.nvim_buf_get_name(buf)
			if name:sub(1, #prefix) == prefix then
				out[#out + 1] = { buf = buf, rel = name:sub(#prefix + 1) }
			end
		end
	end
	return out
end

---Copy an extracted tree so overlays cannot leak into the cached extraction.
---@param dir string
---@return string|nil
local function clone(dir)
	local dest = git.tempdir("ask-agent-view")
	local res = vim.system({ "cp", "-a", dir .. "/.", dest }, { text = true }):wait()
	if res.code ~= 0 then
		vim.fn.delete(dest, "rf")
		return nil
	end
	return dest
end

---@param dir string
---@param root string
---@return integer count
local function overlay_buffers(dir, root)
	local count = 0
	for _, item in ipairs(unsaved_buffers(root)) do
		local target = vim.fs.joinpath(dir, item.rel)
		local lines = vim.api.nvim_buf_get_lines(item.buf, 0, -1, false)
		vim.fn.mkdir(vim.fs.dirname(target), "p")
		if vim.fn.writefile(lines, target) == 0 then
			count = count + 1
		end
	end
	return count
end

---@param mod string
---@return boolean
local function have(mod)
	local ok, plug = pcall(require, mod)
	return ok and plug ~= nil
end

---@return string[]
local function order()
	if M.backend ~= "auto" then
		return { M.backend }
	end
	local out = {}
	if have("diffbandit") then
		out[#out + 1] = "diffbandit"
	end
	if vim.fn.has("nvim-0.12") == 1 then
		out[#out + 1] = "difftool"
	end
	if have("codediff") then
		out[#out + 1] = "codediff"
	end
	out[#out + 1] = "builtin"
	return out
end

---Viewers this machine would try, best first (public for `:checkhealth`).
---@return string[]
function M.viewers()
	return order()
end

---@param root string
---@param from string
---@param to string
---@param meta table
---@return boolean ok, string|nil err
local function show_builtin(root, from, to, meta)
	local text, err = git.patch(root, from, to)
	if not text then
		return false, err
	end
	local files = git.changed(root, from, to) or {}
	local items = {}
	for _, f in ipairs(files) do
		items[#items + 1] = {
			filename = vim.fs.joinpath(root, f.path),
			lnum = 1,
			text = ("%s %s"):format(f.status, f.path),
		}
	end
	vim.fn.setqflist(items, "r")
	vim.fn.setqflist({}, "a", { title = "AskAgent: " .. (meta.label or "changes") })

	local lines = vim.split(text, "\n", { plain = true })
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].filetype = "diff"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].modifiable = false
	local name = ("ask-agent-diff://%s"):format(meta.id or "head")
	pcall(vim.api.nvim_buf_set_name, buf, name)
	vim.cmd("tab split")
	vim.api.nvim_win_set_buf(0, buf)
	return true
end

---@param root string
---@param from string
---@param to string
---@param meta table
---@return boolean ok, string|nil err
local function show_tree_viewer(viewer, root, from, to)
	local left = materialize(from, root)
	if not left then
		return false, "could not extract the starting tree"
	end
	local right = materialize(to, root)
	if not right then
		return false, "could not extract the ending tree"
	end
	if M.include_unsaved and #unsaved_buffers(root) > 0 then
		-- Never write into the cached extraction: it is shared by every review of that tree.
		local copy = clone(right)
		if copy then
			right = copy
			overlay_buffers(right, root)
		end
	end
	if viewer == "diffbandit" then
		local ok, diffbandit = pcall(require, "diffbandit")
		if not ok or type(diffbandit.folder_diff) ~= "function" then
			return false, "diffbandit.folder_diff is missing"
		end
		diffbandit.folder_diff(left, right)
		return true
	end
	-- nvim.difftool ships with Neovim 0.12 but is only loadable on demand
	local loaded = pcall(vim.cmd, "packadd nvim.difftool")
	if not loaded then
		return false, "nvim.difftool is not available"
	end
	local ok, difftool = pcall(require, "nvim.difftool")
	if not ok or type(difftool.open) ~= "function" then
		return false, "nvim.difftool is not available"
	end
	difftool.open(left, right, { rename = { detect = true } })
	return true
end

---codediff wants commit-ish revisions; wrap each tree in a commit (no ref, no branch).
---@param root string
---@param from string
---@param to string
---@param meta table
---@return boolean ok, string|nil err
local function show_codediff(root, from, to, meta)
	local a, err = git.commit(root, from, "ask-agent: " .. (meta.label or "turn start"))
	if not a then
		return false, err
	end
	local b, b_err = git.commit(root, to, "ask-agent: " .. (meta.label or "turn end"), a)
	if not b then
		return false, b_err
	end
	local ok, cmd_err = pcall(vim.cmd, "CodeDiff " .. a .. " " .. b)
	return ok, ok and nil or tostring(cmd_err)
end

---Open a review for one turn (or for the whole repository since HEAD when there is no
---turn yet). Never raises: returns ok + the reason a viewer was unavailable.
---@param opts { id?: string, cwd?: string, backend?: string, include_unsaved?: boolean, head?: boolean }|nil
---@return boolean ok, string|nil err, table|nil meta
function M.open(opts)
	opts = opts or {}
	if opts.backend then
		M.backend = opts.backend
	end
	if opts.include_unsaved ~= nil then
		M.include_unsaved = opts.include_unsaved
	end
	local cwd = opts.cwd or vim.fn.getcwd()
	local root = git.root(cwd)
	if not root then
		return false, "not a git repository"
	end

	local rec = nil
	if not opts.head then
		if opts.correlation then
			rec = snapshot.for_task(opts.correlation)
		elseif opts.id then
			rec = snapshot.get(opts.id)
		else
			rec = snapshot.last(cwd)
		end
	end
	local from, to, live, label
	if rec then
		local f, t, l = snapshot.range(rec)
		if not f then
			return false, "could not snapshot the worktree"
		end
		from, to, live = f, t, l
		label = ("turn %s · %s%s"):format(
			rec.id:sub(1, 8),
			rec.trigger or "manual",
			rec.task and (" · " .. rec.task) or ""
		)
	else
		local ok, head = git.git(root, { "rev-parse", "HEAD^{tree}" })
		from = ok and vim.trim(head) or "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
		to = git.snapshot(root)
		if not to then
			return false, "could not snapshot the worktree"
		end
		label = "whole worktree since HEAD"
	end

	local meta = { id = rec and rec.id or "head", label = label, root = root, from = from, to = to, live = live }
	local changed = git.changed(root, from, to)
	if changed and #changed == 0 then
		notify.notify("[ask_agent] no changes in " .. label, vim.log.levels.INFO)
		return true, nil, meta
	end
	local errs = {}
	for _, viewer in ipairs(order()) do
		local ok, err
		if viewer == "builtin" then
			ok, err = show_builtin(root, from, to, meta)
		elseif viewer == "codediff" then
			ok, err = show_codediff(root, from, to, meta)
		else
			ok, err = show_tree_viewer(viewer, root, from, to)
		end
		if ok then
			return true, nil, meta
		end
		errs[#errs + 1] = ("%s: %s"):format(viewer, err or "failed")
	end
	return false, table.concat(errs, "; "), meta
end

---The patch text of a turn (public for tests and for callers that render it themselves).
---@param rec table
---@return string|nil text, string|nil err
function M.text(rec)
	local from, to = snapshot.range(rec)
	if not from or not to then
		return nil, "no usable range"
	end
	return git.patch(rec.root or git.root(rec.cwd), from, to)
end

return M
