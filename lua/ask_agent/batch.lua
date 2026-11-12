-- lua/ask_agent/batch.lua
---@brief Queued questions: routing them to agents and sending subsets of them.
--
-- The queue itself lives in ask_agent.queue; this module is the *sending* half.
-- It needs a few things only init.lua knows (which backend is current, how to
-- pick a target, how to deliver text), so init injects them with `attach()`.

local backends = require("ask_agent.backends")
local notify = require("ask_agent.notify")
local context = require("ask_agent.context")
local message = require("ask_agent.message")
local queue = require("ask_agent.queue")
local ui = require("ask_agent.ui")

local M = {}

---@type { choose_target: fun(mod: table, cb: fun(t: table|nil)), name_of: fun(t: table): string, deliver_text: fun(mod: table, t: table, text: string, opts: table|nil): boolean, string|nil, current: fun(): string }
local api

---Wire the batch sender to the rest of the plugin. Called from init.setup().
---@param deps table see the api type above
function M.attach(deps)
	api = deps
end

---Entries named by an index spec ("3", "3,5-7"), or every entry when spec is nil.
---@param spec string|nil
---@return table[]|nil entries, string|nil err
local function select_entries(spec)
	if spec == nil or vim.trim(spec) == "" then
		return queue.list()
	end
	local want = {}
	for token in tostring(spec):gmatch("[^,%s]+") do
		local from, to = token:match("^(%d+)%-(%d+)$")
		if from then
			for i = tonumber(from), tonumber(to) do
				want[i] = true
			end
		elseif token:match("^%d+$") then
			want[tonumber(token)] = true
		else
			return nil, ("Invalid selection %q (use e.g. 3 or 3,5-7)"):format(token)
		end
	end
	local out = {}
	for _, entry in ipairs(queue.list()) do
		if want[entry.index] then
			out[#out + 1] = entry
		end
	end
	return out
end

---Resolve a queued entry's stored route (backend id + instance id) to a live target.
---@param route { backend: string, id: string, name?: string }
---@return table|nil mod, table|nil target, string|nil err
local function resolve_route(route)
	local mod = backends.get(route.backend)
	if not mod then
		return nil, nil, ("no backend with id %s"):format(route.backend)
	end
	for _, t in ipairs(mod.targets()) do
		if tostring(t.id) == tostring(route.id) then
			return mod, t
		end
	end
	return nil, nil, ("%s is not running"):format(route.name or route.id)
end

---Send one group of entries to one target, dropping the ones that went out.
---@param mod table backend
---@param target table
---@param entries table[]
local function deliver_one(mod, target, entries)
	local sent, failed = 0, {}
	for _, entry in ipairs(entries) do
		local index = entry.index
		local text = message.render(queue.sync(entry), entry.prompt)
		local ok, send_err = api.deliver_text(mod, target, text, { anchor = entry.anchor })
		if ok then
			sent = sent + 1
			queue.remove(entry.id)
		else
			failed[#failed + 1] = { index = index, err = send_err }
		end
	end
	if sent > 0 then
		local where = target.cwd and vim.fn.fnamemodify(target.cwd, ":~") or "?"
		notify.notify(
			("[%s] Sent %d batched question(s) → %s (%s)"):format(mod.label, sent, api.name_of(target), where),
			vim.log.levels.INFO
		)
	end
	for _, f in ipairs(failed) do
		notify.notify(
			("[%s] Batch #%d failed: %s"):format(mod.label, f.index, f.err or "unknown error"),
			vim.log.levels.WARN
		)
	end
end

---Send queued questions, one message each. Entries with a route go to their own agent;
---the unrouted rest shares a single picker. Successfully sent entries are removed (their
---markers disappear); failed or unreachable ones stay queued.
---@param opts { backend?: string, ids?: string }|nil ids = "3", "3,5-7"; nil = all
---@return boolean ok
function M.send(opts)
	opts = opts or {}
	local pending, sel_err = select_entries(opts.ids)
	if not pending then
		notify.notify("[ask_agent] " .. sel_err, vim.log.levels.WARN)
		return false
	end
	if #pending == 0 then
		notify.notify(
			opts.ids and ("[ask_agent] No queued question matches %s (queue has %d)"):format(opts.ids, queue.count())
				or "[ask_agent] Batch queue is empty",
			vim.log.levels.INFO
		)
		return false
	end

	-- Group by route (keyed by backend + instance id), keeping creation order
	local groups, keyed, rest = {}, {}, {}
	for _, entry in ipairs(pending) do
		if entry.route then
			local key = ("%s:%s"):format(entry.route.backend, tostring(entry.route.id))
			if not keyed[key] then
				keyed[key] = { route = entry.route, entries = {} }
				groups[#groups + 1] = keyed[key]
			end
			table.insert(keyed[key].entries, entry)
		else
			rest[#rest + 1] = entry
		end
	end
	for _, group in ipairs(groups) do
		local mod, target, why = resolve_route(group.route)
		if target then
			deliver_one(mod, target, group.entries)
		else
			local indices = {}
			for _, entry in ipairs(group.entries) do
				indices[#indices + 1] = "#" .. entry.index
			end
			notify.notify(
				("[ask_agent] Kept %s queued: %s"):format(table.concat(indices, ", "), why),
				vim.log.levels.WARN
			)
		end
	end
	if #rest > 0 then
		local mod = backends.get(opts.backend or api.current())
		if not mod then
			notify.notify(
				("[ask_agent] No backend registered with id %s"):format(opts.backend or current),
				vim.log.levels.WARN
			)
			return false
		end
		api.choose_target(mod, function(target)
			if target then
				deliver_one(mod, target, rest)
			end
		end)
	end
	return true
end

---Route queued questions to the agent that should handle them (shown in the marker).
---A route survives for the session: `:AskAgentBatchSend` then honours it per entry.
---@param ids string|nil "3", "3,5-7"; nil = every entry
---@param opts { backend?: string, clear?: boolean }|nil
---@return boolean ok
function M.route(ids, opts)
	opts = opts or {}
	local entries, sel_err = select_entries(ids)
	if not entries then
		notify.notify("[ask_agent] " .. sel_err, vim.log.levels.WARN)
		return false
	end
	if #entries == 0 then
		notify.notify("[ask_agent] Batch queue is empty", vim.log.levels.INFO)
		return false
	end
	if opts.clear then
		for _, entry in ipairs(entries) do
			queue.route(entry.id, nil)
		end
		notify.notify(("[ask_agent] Cleared the route of %d queued question(s)"):format(#entries), vim.log.levels.INFO)
		return true
	end
	local mod = backends.get(opts.backend or api.current())
	if not mod then
		notify.notify(
			("[ask_agent] No backend registered with id %s"):format(opts.backend or current),
			vim.log.levels.WARN
		)
		return false
	end
	api.choose_target(mod, function(target)
		if not target then
			return
		end
		local route = { backend = mod.id, id = tostring(target.id), ts = target.ts, name = api.name_of(target) }
		for _, entry in ipairs(entries) do
			queue.route(entry.id, route)
		end
		notify.notify(
			("[ask_agent] Routed %d queued question(s) → %s"):format(#entries, route.name),
			vim.log.levels.INFO
		)
	end)
	return true
end

--- Jump to the code an entry is attached to.
---@param entry table
local function goto_entry(entry)
	local ok, err = context.open(entry.anchor or {
		buf = entry.buf,
		bufname = entry.bufname,
		line = entry.line,
		col = (entry.col or 0) + 1,
	})
	if not ok then
		notify.notify("[ask_agent] " .. err, vim.log.levels.WARN)
	end
end

--- List queued questions: jump / edit / delete.
function M.list()
	local list = queue.list()
	if #list == 0 then
		notify.notify("[ask_agent] Batch queue is empty", vim.log.levels.INFO)
		return
	end
	local function describe(entry)
		local a = entry.anchor
		local first = (entry.prompt:gsub("\n.*", ""))
		return ("#%d  %s%s:%d  %s"):format(
			entry.index,
			entry.route and ("[→ %s] "):format(entry.route.name or entry.route.id) or "",
			a.path or "<no filename>",
			entry.line or 1,
			first
		)
	end
	vim.ui.select(list, {
		prompt = ("Queued questions (%d)"):format(#list),
		format_item = describe,
	}, function(entry)
		if not entry then
			return
		end
		vim.ui.select({ "send now", "route to an agent", "jump to code", "edit question", "delete" }, {
			prompt = describe(entry),
		}, function(action)
			if action == "send now" then
				M.send({ ids = tostring(entry.index) })
			elseif action == "route to an agent" then
				M.route(tostring(entry.index))
			elseif action == "jump to code" then
				goto_entry(entry)
			elseif action == "edit question" then
				ui.input({
					title = ("Edit #%d · %s"):format(entry.index, context.describe(entry.anchor)),
					default = entry.prompt,
					on_submit = function(text)
						queue.update(entry.id, text)
					end,
				})
			elseif action == "delete" then
				queue.remove(entry.id)
				notify.notify(
					("[ask_agent] Deleted queued question #%d (:AskAgentBatchUndo restores it)"):format(entry.index),
					vim.log.levels.INFO
				)
			end
		end)
	end)
end

--- Delete the queued question(s) sitting on the cursor line of the current buffer.
--- With several entries on the line, asks which one; undo with M.batch_undo().
function M.delete_query()
	local buf = vim.api.nvim_get_current_buf()
	local line = vim.api.nvim_win_get_cursor(0)[1]
	local hits = {}
	for _, it in ipairs(queue.list()) do
		if it.buf == buf then
			queue.sync(it)
			if it.line == line then
				table.insert(hits, it)
			end
		end
	end
	if #hits == 0 then
		notify.notify(
			("[ask_agent] No queued question on this line (queue has %d)"):format(queue.count()),
			vim.log.levels.INFO
		)
		return
	end
	local function drop(entry)
		queue.remove(entry.id)
		notify.notify(("[ask_agent] Deleted queued question on line %d (:AskAgentBatchUndo restores it)"):format(line))
	end
	if #hits == 1 then
		return drop(hits[1])
	end
	vim.ui.select(hits, {
		prompt = ("%d queued questions on this line"):format(#hits),
		format_item = function(entry)
			return ("#%d  %s"):format(entry.index, (entry.prompt:gsub("\n.*", "")))
		end,
	}, function(entry)
		if entry then
			drop(entry)
		end
	end)
end

--- Undo the last delete (or clear): put the question(s) back with their markers.
function M.undo()
	local restored, skipped, label = queue.undo()
	if not label then
		notify.notify("[ask_agent] Nothing to undo in the batch queue", vim.log.levels.INFO)
		return
	end
	local msg = ("[ask_agent] Restored %d queued question(s) from last %s"):format(restored, label)
	if skipped > 0 then
		msg = msg .. (" (%d skipped: buffer was wiped)"):format(skipped)
	end
	notify.notify(msg, skipped > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
end

--- Drop every queued question and its marker. Undoable with M.batch_undo().
function M.clear()
	local n = queue.count()
	if n == 0 then
		notify.notify("[ask_agent] Batch queue is empty", vim.log.levels.INFO)
		return
	end
	queue.clear()
	notify.notify(
		("[ask_agent] Cleared %d queued question(s) (:AskAgentBatchUndo restores them)"):format(n),
		vim.log.levels.INFO
	)
end

---@return integer
function M.count()
	return queue.count()
end

return M
