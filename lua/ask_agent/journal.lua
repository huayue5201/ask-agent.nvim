-- lua/ask_agent/journal.lua
---@brief Read and write the JSON journals (history, snapshots, agent state) — one
---implementation, and one rule for a file that is not what we expect.
--
-- The rule: a journal that cannot be decoded is *moved aside*, never overwritten
-- in place. Before this module existed, each journal decoded with a pcall and
-- silently started from an empty list, so the next save replaced a corrupt-but-
-- possibly-recoverable file with a fresh empty one.

local M = {}

---@param file string
---@return string dir
local function dir_of(file)
	return vim.fn.fnamemodify(file, ":h")
end

---Move a journal that failed to decode out of the way (`<file>.bad-<timestamp>`).
---@param file string
---@return string|nil moved_to
local function move_aside(file)
	local target = ("%s.bad-%d"):format(file, os.time())
	if vim.uv.fs_rename(file, target) then
		return target
	end
	return nil
end

---Tell the user about a journal that had to be moved aside. Never raises: a broken
---journal must not break the plugin that could not read it.
---@param problem string|nil
function M.report(problem)
	if not problem or problem == "" then
		return
	end
	pcall(function()
		require("ask_agent.notify").notify("[ask_agent] " .. problem, vim.log.levels.WARN)
	end)
end

---Read a journal.
---
---Returns `data` (the decoded object) and, when the file was there but unusable, a
---`problem` string. The caller decides whether to notify; the file has already been
---renamed, so `M.write` cannot destroy it.
---@param file string
---@return table|nil data, string|nil problem
function M.read(file)
	local stat = vim.uv.fs_stat(file)
	if not stat then
		return nil, nil
	end
	local ok, lines = pcall(vim.fn.readfile, file)
	if not ok or type(lines) ~= "table" then
		return nil, ("%s could not be read"):format(file)
	end
	if #lines == 0 then
		return nil, nil
	end
	local decoded, data = pcall(vim.json.decode, table.concat(lines, "\n"))
	if not decoded or type(data) ~= "table" then
		local moved = move_aside(file)
		if moved then
			return nil, ("%s was not valid JSON; it is now %s"):format(file, moved)
		end
		return nil, ("%s was not valid JSON and could not be moved aside"):format(file)
	end
	return data, nil
end

---Write a journal, creating its directory. Encodes before touching the file, so a
---failed encode leaves the previous journal intact.
---@param file string
---@param data table
---@return boolean ok
function M.write(file, data)
	local ok, encoded = pcall(vim.json.encode, data)
	if not ok then
		return false
	end
	pcall(vim.fn.mkdir, dir_of(file), "p")
	local stat = vim.uv.fs_stat(file)
	-- rename over the old file instead of rewriting it in place: a crash mid-write
	-- then leaves the previous journal, not half a line
	if stat then
		local tmp = ("%s.tmp-%d"):format(file, vim.uv.os_getpid())
		if pcall(vim.fn.writefile, { encoded }, tmp) and vim.uv.fs_rename(tmp, file) then
			return true
		end
		pcall(vim.fn.delete, tmp)
	end
	return (pcall(vim.fn.writefile, { encoded }, file))
end

return M
