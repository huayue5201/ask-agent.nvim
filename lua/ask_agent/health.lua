-- lua/ask_agent/health.lua
---@brief `:checkhealth ask_agent` — where instances are found, which integrations exist.

local M = {}

local function ok(msg)
	vim.health.ok(msg)
end

local function warn(msg)
	vim.health.warn(msg)
end

local function info(msg)
	vim.health.info(msg)
end

function M.check()
	vim.health.start("ask_agent")

	local has_health = type(vim.health) == "table"
	if not has_health then
		return
	end

	-- Neovim version
	if vim.fn.has("nvim-0.10") == 1 then
		ok("Neovim " .. tostring(vim.version().major) .. "." .. tostring(vim.version().minor))
	else
		warn("Neovim 0.10+ is required")
	end

	-- optional integrations
	if pcall(require, "dropbar.utils.menu") then
		ok("dropbar.nvim found (centered, clickable menus)")
	else
		info("dropbar.nvim not found — falling back to plain vim.ui.select")
	end

	local rex = require("ask_agent.rex")
	if rex.available() then
		ok("rex found — the visual map picker is available")
	else
		info("rex not found — the map picker will fall back to the list")
	end

	-- backends and their instances
	local backends = require("ask_agent.backends")
	local ids = {}
	for _, mod in ipairs(backends.list() or {}) do
		ids[#ids + 1] = mod.id
		local good, list = pcall(mod.targets)
		if not good then
			warn(("backend %s: targets() failed: %s"):format(mod.id, tostring(list)))
		elseif #(list or {}) == 0 then
			warn(("backend %s: no instances found"):format(mod.id))
		else
			ok(("backend %s: %d instance(s)"):format(mod.id, #list))
			for _, t in ipairs(list) do
				info(("  #%s %s  cwd=%s"):format(tostring(t.id), t.label or "?", t.cwd or "?"))
			end
		end
	end
	if #ids == 0 then
		warn("no backends registered")
	else
		info("backends: " .. table.concat(ids, ", "))
	end

	-- state files
	local aliases = require("ask_agent.aliases")
	local names = 0
	for _ in pairs(aliases.all() or {}) do
		names = names + 1
	end
	info(("instance names: %d"):format(names))

	local bridge = require("ask_agent.bridge")
	if type(bridge.dir) == "function" then
		local dir = bridge.dir()
		if dir then
			info("bridge registry: " .. dir)
		end
	end
end

return M
