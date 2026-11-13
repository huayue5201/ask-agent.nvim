-- lua/ask_agent/project.lua
---@brief The project overview digest that rides along with a question.
--
-- Two things travel with a question: *where* it was asked (the anchor, see context.lua) and
-- *what* it is being asked about (this file). The second one is a cheap index of the repository —
-- structure, size, build entry, conventions, no source — that saves the agent a round of
-- `find`/`grep` before it can even start answering.
--
-- The overview itself belongs to project-overview.nvim; this module only decides when to ask for
-- one, how long to wait, and what to do when that plugin is not installed (nothing: a missing
-- digest must never fail a question).
--
-- Cost control: the digest is cached per root with a short TTL, and the wait is bounded, so a
-- cold repository costs one measurable pause and every later question is free.

local M = {}

---@type boolean  attach the digest to outgoing questions
M.enabled = true
---@type integer  how long a question may wait for a cold collect (ms)
M.wait_ms = 1500
---@type boolean  ask for the full digest (deps / conventions / size detail)
M.full = false
---@type integer  seconds a digest stays usable (branch switches and new commits are not watched)
M.ttl = 300

---@type table<string, { text: string, ts: integer }>
local cache = {}

---@param opts? { enabled?: boolean, wait_ms?: integer, full?: boolean, ttl?: integer }
function M.setup(opts)
	opts = opts or {}
	if type(opts.enabled) == "boolean" then
		M.enabled = opts.enabled
	end
	if tonumber(opts.wait_ms) then
		M.wait_ms = math.max(0, math.floor(opts.wait_ms))
	end
	if type(opts.full) == "boolean" then
		M.full = opts.full
	end
	if tonumber(opts.ttl) then
		M.ttl = math.max(0, math.floor(opts.ttl))
	end
end

---Forget every cached digest (tests, and `:AskAgent` after a branch switch)
function M.reset()
	cache = {}
end

---Whether a digest can be produced at all: enabled and project-overview.nvim is installed.
---@return boolean
function M.available()
	if not M.enabled then
		return false
	end
	local ok, project = pcall(require, "project_overview")
	return ok and type(project) == "table" and type(project.bridge) == "function"
end

---The digest for `root`, or nil when there is none to give.
---Never raises: a broken overview must not take the question down with it.
---@param root string|nil
---@return string|nil
function M.digest(root)
	if not M.available() or type(root) ~= "string" or root == "" then
		return nil
	end
	local hit = cache[root]
	if hit and (os.time() - hit.ts) < M.ttl then
		return hit.text
	end
	local project = require("project_overview")
	-- bridge() blocks on a cold collect (`wait_ms`), reuses project-overview's own cache when it
	-- has one, and reports `origin` so a slow first question is explainable.
	local called, res = pcall(project.bridge, { root = root, full = M.full, wait_ms = M.wait_ms })
	if not called or type(res) ~= "table" or res.ok == false then
		return nil
	end
	if type(res.digest) ~= "string" or res.digest == "" then
		return nil
	end
	cache[root] = { text = res.digest, ts = os.time() }
	return res.digest
end

return M
