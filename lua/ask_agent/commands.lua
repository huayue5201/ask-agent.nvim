-- lua/ask_agent/commands.lua
---@brief The user commands. Keymaps stay out on purpose: commands are the API.

local M = {}
local notify = require("ask_agent.notify")

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
	vim.api.nvim_create_user_command("AskAgentChat", function(args)
		local a = args.args ~= "" and args.args or nil
		if a == "close" then
			require("ask_agent.chat_ui").close()
			return
		end
		api.chat({ thread = a })
	end, { desc = "ask-agent: group chat (@name routes a task)", nargs = "?" })

	vim.api.nvim_create_user_command("AskAgentPi", function()
		api.ask()
	end, { desc = "Ask agent: same as :AskAgent (legacy name)" })
	vim.api.nvim_create_user_command("AskAgentDiff", function(args)
		local arg = args.args ~= "" and args.args or nil
		if arg == "head" then
			api.diff({ head = true })
		else
			api.diff({ id = arg })
		end
	end, {
		nargs = "?",
		complete = function()
			local ids = { "head" }
			for _, rec in ipairs(api.turns() or {}) do
				ids[#ids + 1] = rec.id:sub(1, 8)
			end
			return ids
		end,
		desc = "Ask agent: review what an agent changed (last turn, a turn id, or 'head' = since HEAD)",
	})
	vim.api.nvim_create_user_command("AskAgentSnapshot", function(args)
		api.snapshot(args.args ~= "" and args.args or nil)
	end, {
		nargs = "?",
		desc = "Ask agent: start (no arg) or close ('last' / a turn id) a manual review interval",
	})
	vim.api.nvim_create_user_command("AskAgentBackend", function(args)
		if args.args ~= "" then
			local ok, err = api.use(args.args)
			if not ok then
				notify.notify("[ask_agent] " .. err, vim.log.levels.WARN)
			else
				notify.notify("[ask_agent] Current backend → " .. args.args, vim.log.levels.INFO)
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
			notify.notify(("[ask_agent] Picker must be map or list (currently %s)"):format(cur), vim.log.levels.WARN)
			return
		end
		api.picker(want)
		notify.notify(("[ask_agent] Picker for multiple candidates → %s"):format(want), vim.log.levels.INFO)
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
			notify.notify("[ask_agent] Cleared the manually pinned target", vim.log.levels.INFO)
			return
		end
		local items = api.targets()
		if args.args ~= "" then
			local ok, err = api.pin(args.args)
			if not ok then
				notify.notify("[ask_agent] " .. err, vim.log.levels.WARN)
			else
				notify.notify("[ask_agent] Target pinned to " .. args.args, vim.log.levels.INFO)
			end
			return
		end
		if #items == 0 then
			notify.notify("[ask_agent] Current backend has no available targets", vim.log.levels.WARN)
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

	vim.api.nvim_create_user_command("AskAgentRename", function(args)
		local items = api.targets()
		if #items == 0 then
			notify.notify("[ask_agent] Current backend has no available targets", vim.log.levels.WARN)
			return
		end
		for i, it in ipairs(items) do
			it.index = i
		end
		vim.ui.select(items, {
			prompt = args.bang and "Clear the name of which instance"
				or "Rename which instance (:AskAgentRename! clears)",
			format_item = function(item)
				local alias = deps.aliases.get(item, deps.current())
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
				deps.aliases.clear(item, deps.current())
				notify.notify(("[ask_agent] Cleared alias for #%d"):format(item.index or 0), vim.log.levels.INFO)
				return
			end
			vim.ui.input({
				prompt = ("#%d name (empty = clear): "):format(item.index or 0),
				default = deps.aliases.get(item, deps.current()) or "",
			}, function(name)
				if name == nil then
					return
				end
				if not deps.aliases.set(item, deps.current(), name) then
					notify.notify("[ask_agent] Could not write the alias to the cache file", vim.log.levels.WARN)
					return
				end
				local now = deps.aliases.get(item, deps.current())
				notify.notify(
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

	-- Question history: a searchable ledger of delivered questions. Every action is
	-- local; nothing is re-sent behind your back.
	vim.api.nvim_create_user_command("AskAgentHistory", function(args)
		local history = require("ask_agent.history")
		local recs = history.list({ query = args.args ~= "" and args.args or nil })
		if #recs == 0 then
			notify.notify(
				args.args ~= "" and "[ask_agent] no questions match " .. args.args
					or "[ask_agent] no questions recorded yet",
				vim.log.levels.INFO
			)
			return
		end
		local function stamp(rec)
			return os.date("%m-%d %H:%M", math.floor(rec.ts / 1000))
		end
		vim.ui.select(recs, {
			prompt = ("Questions (%d)"):format(#recs),
			format_item = function(rec)
				return stamp(rec) .. "  " .. history.describe(rec)
			end,
		}, function(rec)
			if not rec then
				return
			end
			vim.ui.select({ "put in the ask window", "copy text", "jump to code", "delete" }, {
				prompt = history.describe(rec),
			}, function(action)
				if action == "put in the ask window" then
					api.ask({ default = rec.text })
				elseif action == "copy text" then
					pcall(vim.fn.setreg, "+", rec.text)
					pcall(vim.fn.setreg, '"', rec.text)
					notify.notify("[ask_agent] Question copied", vim.log.levels.INFO)
				elseif action == "jump to code" then
					local ok, err = history.jump(rec)
					if not ok then
						notify.notify("[ask_agent] " .. (err or "cannot jump"), vim.log.levels.WARN)
					end
				elseif action == "delete" then
					history.remove(rec.id)
					notify.notify("[ask_agent] Question removed from history", vim.log.levels.INFO)
				end
			end)
		end)
	end, {
		nargs = "?",
		desc = "Ask agent: search questions sent before (re-ask / copy / jump / delete)",
	})

	-- Prompt library: templates rendered against the anchor captured at ask time.
	vim.api.nvim_create_user_command("AskAgentPrompt", function(args)
		local prompts = require("ask_agent.prompts")
		local name = args.args ~= "" and args.args or nil
		local visual = args.bang -- `:AskAgentPrompt!` captures the last visual selection
		if name then
			local ok, err = api.prompt(name, { visual = visual })
			if not ok then
				notify.notify("[ask_agent] " .. err, vim.log.levels.WARN)
			end
			return
		end
		local list = prompts.all()
		if #list == 0 then
			notify.notify(
				"[ask_agent] no prompts yet — :AskAgentPromptSave <name> stores the selection as one",
				vim.log.levels.INFO
			)
			return
		end
		vim.ui.select(list, {
			prompt = "Prompts",
			format_item = function(entry)
				return ("%s%s  [%s]"):format(entry.name, entry.desc and (" — " .. entry.desc) or "", entry.source)
			end,
		}, function(entry)
			if not entry then
				return
			end
			vim.ui.select({ "use", "copy text", "edit", "delete" }, { prompt = entry.name }, function(action)
				if action == "use" then
					local ok, err = api.prompt(entry.name, { visual = visual })
					if not ok then
						notify.notify("[ask_agent] " .. err, vim.log.levels.WARN)
					end
				elseif action == "copy text" then
					pcall(vim.fn.setreg, "+", entry.text)
					pcall(vim.fn.setreg, '"', entry.text)
					notify.notify("[ask_agent] Prompt copied", vim.log.levels.INFO)
				elseif action == "edit" then
					require("ask_agent.ui").input({
						title = ("Edit prompt %s ({{file}} {{line}} {{selection}} …)"):format(entry.name),
						default = entry.text,
						on_submit = function(text)
							local ok, err = prompts.save(entry.name, text, {
								desc = entry.desc,
								project = entry.source == "project",
							})
							notify.notify(
								ok and ("[ask_agent] Prompt saved: " .. entry.name)
									or ("[ask_agent] " .. (err or "could not save the prompt")),
								ok and vim.log.levels.INFO or vim.log.levels.WARN
							)
						end,
					})
				elseif action == "delete" then
					local ok, err = prompts.remove(entry.name)
					notify.notify(
						ok and ("[ask_agent] Prompt deleted: " .. entry.name)
							or ("[ask_agent] " .. (err or "could not delete the prompt")),
						ok and vim.log.levels.INFO or vim.log.levels.WARN
					)
				end
			end)
		end)
	end, {
		nargs = "?",
		bang = true,
		complete = function()
			local out = {}
			for _, entry in ipairs(require("ask_agent.prompts").all()) do
				out[#out + 1] = entry.name
			end
			return out
		end,
		desc = "Ask agent: use a prompt template, rendered against the anchor (! = include the selection)",
	})

	-- Store the selection (or the line under the cursor) as a prompt; `!` writes it
	-- into the repository instead of the global cache, so it travels with the code.
	vim.api.nvim_create_user_command("AskAgentPromptSave", function(args)
		local name = vim.trim(args.args or "")
		if name == "" then
			notify.notify("[ask_agent] usage: :AskAgentPromptSave <name>  (bang = project file)", vim.log.levels.WARN)
			return
		end
		local mode = vim.fn.mode()
		local body = ""
		if mode == "v" or mode == "V" or mode == "\22" then
			local sl = vim.fn.getpos("'<")[2]
			local el = vim.fn.getpos("'>")[2]
			if sl > 0 and el >= sl then
				body = table.concat(vim.api.nvim_buf_get_lines(0, sl - 1, el, false), "\n")
			end
		end
		if body == "" then
			body = vim.api.nvim_get_current_line()
		end
		require("ask_agent.ui").input({
			title = ("Save prompt %s%s ({{file}} {{line}} {{selection}} {{cwd}} …)"):format(
				name,
				args.bang and " → project" or " → global"
			),
			default = body,
			on_submit = function(text)
				local ok, err = api.prompt_save(name, text, { project = args.bang })
				notify.notify(
					ok and ("[ask_agent] Prompt saved: " .. name)
						or ("[ask_agent] " .. (err or "could not save the prompt")),
					ok and vim.log.levels.INFO or vim.log.levels.WARN
				)
			end,
		})
	end, {
		nargs = 1,
		bang = true,
		desc = "Ask agent: save the selection/current line as a prompt (bang = project file)",
	})
end

return M
