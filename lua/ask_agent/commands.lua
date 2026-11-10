-- lua/ask_agent/commands.lua
---@brief The user commands. Keymaps stay out on purpose: commands are the API.

local M = {}

---@type table the ask_agent module itself (commands are its public interface)
local api

---@param deps table { api, icon_prefix, name_of, current, backends, aliases }
function M.install(deps)
	if M.installed then
		return
	end
	M.installed = true
	api = deps.api

	vim.api.nvim_create_user_command("AskAgent", function()
		api.ask()
	end, { desc = "Ask agent: open a floating window and send the question with the current anchor" })
	vim.api.nvim_create_user_command("AskAgentVisual", function()
		api.ask({ visual = true })
	end, { desc = "Ask agent: like AskAgent but includes the current selection" })
	vim.api.nvim_create_user_command("AskAgentBatch", function()
		api.batch_ask()
	end, { desc = "Ask agent: queue a question at the cursor instead of sending it now" })
	vim.api.nvim_create_user_command("AskAgentBatchVisual", function()
		api.batch_ask({ visual = true })
	end, { desc = "Ask agent: queue a question anchored to the current selection" })
	vim.api.nvim_create_user_command("AskAgentBatchSend", function(args)
		api.batch_send({ ids = args.args ~= "" and args.args or nil })
	end, {
		nargs = "?",
		desc = "Ask agent: send queued questions (all, or e.g. 3,5-7) to their agents",
	})
	vim.api.nvim_create_user_command("AskAgentBatchRoute", function(args)
		api.batch_route(args.args ~= "" and args.args or nil, { clear = args.bang })
	end, {
		nargs = "?",
		bang = true,
		desc = "Ask agent: route queued questions (all, or e.g. 3,5-7) to an agent ('!' clears)",
	})
	vim.api.nvim_create_user_command("AskAgentBatchList", function()
		api.batch_list()
	end, { desc = "Ask agent: list queued questions (send/route/jump/edit/delete)" })
	vim.api.nvim_create_user_command("AskAgentBatchDelete", function()
		api.batch_delete()
	end, { desc = "Ask agent: delete the queued question on the cursor line (undoable)" })
	vim.api.nvim_create_user_command("AskAgentBatchUndo", function()
		api.batch_undo()
	end, { desc = "Ask agent: undo the last queue delete/clear" })
	vim.api.nvim_create_user_command("AskAgentBatchClear", function()
		api.batch_clear()
	end, { desc = "Ask agent: drop every queued question (undoable)" })
	vim.api.nvim_create_user_command("AskAgentDashboard", function()
		api.dashboard()
	end, { desc = "Ask agent: sidebar - agents with their queued and sent tasks" })
	-- Legacy name
	vim.api.nvim_create_user_command("AskAgentPi", function()
		api.ask()
	end, { desc = "Ask agent: same as :AskAgent (legacy name)" })
	vim.api.nvim_create_user_command("AskAgentBackend", function(args)
		if args.args ~= "" then
			local ok, err = api.use(args.args)
			if not ok then
				vim.notify("[ask_agent] " .. err, vim.log.levels.WARN)
			else
				vim.notify("[ask_agent] Current backend → " .. args.args, vim.log.levels.INFO)
			end
			return
		end
		local items = api.list()
		vim.ui.select(items, {
			prompt = ("Ask agent backend (current: %s)"):format(deps.current()),
			format_item = function(item)
				return ("%s%s%s"):format(deps.icon_prefix(item), item.label, item.available and "" or " (unavailable)")
			end,
		}, function(item)
			if item then
				api.use(item.id)
			end
		end)
	end, {
		nargs = "?",
		complete = function()
			local out = {}
			for _, item in ipairs(api.list()) do
				table.insert(out, item.id)
			end
			return out
		end,
		desc = "Ask agent: select or switch the default backend",
	})

	vim.api.nvim_create_user_command("AskAgentPicker", function(args)
		local cur = api.picker()
		local want = args.args ~= "" and args.args or (cur == "map" and "list" or "map")
		if want ~= "map" and want ~= "list" then
			vim.notify(("[ask_agent] Picker must be map or list (currently %s)"):format(cur), vim.log.levels.WARN)
			return
		end
		api.picker(want)
		vim.notify(("[ask_agent] Picker for multiple candidates → %s"):format(want), vim.log.levels.INFO)
	end, {
		nargs = "?",
		complete = function()
			return { "map", "list" }
		end,
		desc = "Ask agent: picker for multiple candidates (map=split map, list=list)",
	})

	vim.api.nvim_create_user_command("AskAgentTarget", function(args)
		if args.bang then
			api.pin(nil)
			vim.notify("[ask_agent] Cleared the manually pinned target", vim.log.levels.INFO)
			return
		end
		local items = api.targets()
		if args.args ~= "" then
			local ok, err = api.pin(args.args)
			if not ok then
				vim.notify("[ask_agent] " .. err, vim.log.levels.WARN)
			else
				vim.notify("[ask_agent] Target pinned to " .. args.args, vim.log.levels.INFO)
			end
			return
		end
		if #items == 0 then
			vim.notify("[ask_agent] Current backend has no available targets", vim.log.levels.WARN)
			return
		end
		for i, it in ipairs(items) do
			it.index = i
		end
		vim.ui.select(items, {
			prompt = "Pin sends to which target (:AskAgentTarget! to cancel)",
			format_item = function(item)
				return ("#%d %s%s  %s"):format(
					item.index or 0,
					deps.icon_prefix(deps.backends.get(deps.current())),
					deps.name_of(item),
					item.cwd or "?"
				)
			end,
		}, function(item)
			if item then
				api.pin(tostring(item.id))
			end
		end)
	end, { nargs = "?", bang = true, desc = "Ask agent: pin or clear the target used for sending" })

	vim.api.nvim_create_user_command("AskAgentAlias", function(args)
		local items = api.targets()
		if #items == 0 then
			vim.notify("[ask_agent] Current backend has no available targets", vim.log.levels.WARN)
			return
		end
		for i, it in ipairs(items) do
			it.index = i
		end
		vim.ui.select(items, {
			prompt = args.bang and "Clear the alias of which instance"
				or "Give which instance an alias (:AskAgentAlias! clears)",
			format_item = function(item)
				local alias = deps.aliases.get(item)
				return ("#%d %s%s%s  %s"):format(
					item.index or 0,
					deps.icon_prefix(deps.backends.get(deps.current())),
					alias or item.label or item.id,
					alias and ("  (« " .. (item.label or item.id)) or "",
					vim.fn.fnamemodify(item.cwd or "?", ":~")
				)
			end,
		}, function(item)
			if not item then
				return
			end
			if args.bang then
				deps.aliases.clear(item)
				vim.notify(("[ask_agent] Cleared alias for #%d"):format(item.index or 0), vim.log.levels.INFO)
				return
			end
			vim.ui.input({
				prompt = ("#%d name (empty = clear): "):format(item.index or 0),
				default = deps.aliases.get(item) or "",
			}, function(name)
				if name == nil then
					return
				end
				if not deps.aliases.set(item, name) then
					vim.notify("[ask_agent] Could not write the alias to the cache file", vim.log.levels.WARN)
					return
				end
				local now = deps.aliases.get(item)
				vim.notify(
					now and ("[ask_agent] #%d is now called %s"):format(item.index or 0, now)
						or ("[ask_agent] Alias for #%d cleared"):format(item.index or 0),
					vim.log.levels.INFO
				)
			end)
		end)
	end, {
		nargs = 0,
		bang = true,
		desc = "Ask agent: give an instance an alias (shown in lists, same color in the map)",
	})
end

return M
