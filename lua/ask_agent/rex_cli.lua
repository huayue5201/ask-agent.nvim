-- lua/ask_agent/rex_cli.lua
---@brief Where the `rex` CLI is, even when it is not on $PATH.
--
-- The Rex app ships its CLI inside the app bundle and (only when a shell was
-- started by Rex itself) adds it to $PATH. A Neovim started anywhere else — a
-- herdr pane, a tmux session, an IDE terminal — therefore sees `vim.fn.executable
-- ("rex") == 1` fail while the app is running fine, and every rex feature
-- (viewer, jump, status) reports "rex is not installed". Resolve the binary once
-- and use it everywhere instead of the bare name.

local M = {}

---@type string|nil resolved, `false` when already searched and not found
local resolved

local function home_versions()
	local root = vim.fn.expand("~/Library/Application Support/com.superlogical.rex/RexServer/Versions")
	local out = {}
	for _, name in ipairs(vim.fn.readdir(root) or {}) do
		if name:match("^%d+$") then
			out[#out + 1] = tonumber(name)
		end
	end
	table.sort(out, function(a, b)
		return a > b
	end)
	local paths = {}
	for _, v in ipairs(out) do
		paths[#paths + 1] = ("%s/%d/Rex Server.app/Contents/MacOS/rex"):format(root, v)
	end
	-- "Current" is a plain directory, not a symlink, so it is only a fallback
	paths[#paths + 1] = root .. "/Current/Rex Server.app/Contents/MacOS/rex"
	return paths
end

---@return string[] candidates, most explicit first
local function candidates()
	local out = {}
	for _, v in ipairs({ vim.g.ask_agent_rex, vim.env.ASK_AGENT_REX }) do
		if type(v) == "string" and v ~= "" then
			out[#out + 1] = v
		end
	end
	out[#out + 1] = "rex" -- whatever $PATH offers
	vim.list_extend(out, home_versions())
	out[#out + 1] = "/Applications/Rex Beta.app/Contents/MacOS/rex"
	out[#out + 1] = "/Applications/Rex.app/Contents/MacOS/rex"
	return out
end

---Absolute path to the rex CLI, or nil when Rex is not installed at all.
---`vim.g.ask_agent_rex` (or $ASK_AGENT_REX) wins, then $PATH, then the app
---bundle (newest installed version first).
---@param force boolean|nil re-search even if the answer is cached
---@return string|nil
function M.path(force)
	if resolved and not force then
		return resolved or nil
	end
	for _, c in ipairs(candidates()) do
		if c == "rex" then
			if vim.fn.executable("rex") == 1 then
				resolved = "rex"
				return resolved
			end
		elseif vim.fn.executable(c) == 1 then
			resolved = c
			return resolved
		end
	end
	resolved = false
	return nil
end

---@return boolean
function M.available()
	return M.path() ~= nil
end

---Forget the cached answer (after `:AskAgentHealth` or an install).
function M.reset()
	resolved = nil
end

return M
