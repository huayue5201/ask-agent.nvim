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

	-- optional integrations: the list mode only needs *some* vim.ui.select implementation
	local select_impl = "builtin (blocking)"
	for _, name in ipairs({ "dropbar.utils.menu", "telescope", "fzf-lua", "snacks.picker", "mini.pick" }) do
		if pcall(require, name) then
			select_impl = name
			break
		end
	end
	if select_impl == "builtin (blocking)" then
		info("no vim.ui.select implementation installed — list mode uses the blocking builtin prompt")
	else
		ok(("list mode via vim.ui.select (found: %s)"):format(select_impl))
	end

	-- layout adapters: they decide whether the map picker can work at all
	local layouts = require("ask_agent.layouts")
	local active = layouts.active(require("ask_agent").layout())
	for _, id in ipairs(layouts.list()) do
		local mod = layouts.get(id)
		local good, reason = pcall(mod.available or function()
			return true
		end)
		local usable = good and reason
		local line = ("layout %s: %s"):format(id, usable and "usable" or (reason or "unusable"))
		if mod == active then
			ok(line .. " (active)")
		elseif usable then
			info(line)
		else
			info(line .. " — the map picker falls back to the list")
		end
	end
	if not active then
		info("no layout adapter usable — the map picker will fall back to the list")
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

	-- state layer: where the dashboard/statusline get their truth from
	local state = require("ask_agent.state")
	local st = require("ask_agent.status.rex")
	if st.available() then
		ok("rex program status available (OSC 7501 beats busy markers)")
	else
		info("rex not on PATH — agent state comes from backend probes only")
	end
	local counts = state.counts()
	info(
		("state: %d agent(s), %d blocked, %d finished, %d working"):format(
			counts.total,
			counts.blocked,
			counts.done,
			counts.working
		)
	)

	-- state files
	local aliases = require("ask_agent.aliases")
	local names = 0
	for _ in pairs(aliases.all() or {}) do
		names = names + 1
	end
	info(("instance names: %d"):format(names))

	if state.persist then
		info("journal: " .. (state.journal_path or (vim.fn.stdpath("cache") .. "/ask-agent/journal.json")))
	else
		info("journal: disabled (persist = false)")
	end

	-- change review: snapshots need git, inspection needs a viewer
	local git = require("ask_agent.git")
	if git.available() then
		local root = git.root(vim.fn.getcwd())
		if root then
			ok("change review: git repository at " .. root)
		else
			info("change review: cwd is not inside a git repository")
		end
	else
		warn("change review: git is not on PATH — :AskAgentDiff is unavailable")
	end
	local snap = require("ask_agent.snapshot")
	if snap.enabled then
		info(("turn snapshots: %d kept in %s"):format(#snap.list(), snap.path or "?"))
	else
		info("turn snapshots: disabled (snapshots = false)")
	end
	local review = require("ask_agent.review")
	info("review viewers: " .. table.concat(review.viewers(), " → "))

	-- jump adapters: which host can bring an agent's own window to the front
	local jump = require("ask_agent.jump")
	local jids = {}
	for _, a in ipairs(jump.list()) do
		jids[#jids + 1] = a.id
	end
	info("jump adapters: " .. table.concat(jids, ", "))

	-- viewer floats: which host can show an agent's terminal in a second display
	local view = require("ask_agent.view")
	local vids = {}
	for _, p in ipairs(view.list()) do
		vids[#vids + 1] = p.id .. (p.readonly_only and " (read only)" or "")
	end
	if #vids > 0 then
		info("view providers: " .. table.concat(vids, ", "))
	else
		info("view providers: none — <CR> in the dashboard opens no float")
	end
	for _, name in ipairs({ "tmux", "herdr" }) do
		if vim.fn.executable(name) ~= 1 then
			info(("view provider %s: %s is not on PATH"):format(name, name))
		end
	end
	local rex_path = require("ask_agent.rex_cli").path()
	if rex_path and rex_path ~= "rex" then
		info("rex CLI: not on PATH, using " .. rex_path)
	elseif not rex_path then
		info("rex: not found (neither on PATH nor in the Rex app bundle)")
	end
	if rex_path and vim.fn.executable(vim.g.ask_agent_python or "python3") ~= 1 then
		warn("rex viewer: python3 is not on PATH — the rex viewer float cannot start")
	end

	-- question history and the prompt library are plain local files
	local hist = require("ask_agent.history")
	if hist.enabled then
		info(
			("question history: %d kept in %s"):format(
				#hist.list(),
				hist.path or (vim.fn.stdpath("cache") .. "/ask-agent/history.json")
			)
		)
	else
		info("question history: disabled (history = false)")
	end
	local prompts = require("ask_agent.prompts")
	info(
		("prompts: %d visible (global %s)"):format(
			#prompts.all(),
			prompts.global_path or (vim.fn.stdpath("cache") .. "/ask-agent/prompts.json")
		)
	)

	local bridge = require("ask_agent.bridge")
	if type(bridge.dir) == "function" then
		local dir = bridge.dir()
		if dir then
			info("bridge registry: " .. dir)
		end
	end
end

return M
