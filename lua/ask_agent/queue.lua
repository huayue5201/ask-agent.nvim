-- lua/ask_agent/queue.lua
---@brief Pending-questions queue: collect several anchored questions while browsing, then send them all at once.
--
-- Each entry keeps the anchor captured at creation time, the question text and an optional route
-- (the agent instance that should handle it). The entry is drawn in the source buffer as an extmark
-- (a sign in the sign column plus virtual text at end-of-line), so the question stays attached to
-- the code it is about even while the buffer is edited. Sending happens elsewhere (init.lua): this
-- module only stores, draws and moves entries.
--
-- The queue is per-Neovim-session, in memory only — the same lifetime as the anchors it refers to.

local icons = require("ask_agent.icons")

local M = {}

local NS = vim.api.nvim_create_namespace("ask_agent.batch")

---@type table[]
local items = {}
local next_id = 0
local hl_done = false

-- Undo history: every destructive operation pushes one group of { entry, pos } pairs.
-- Kept in memory with the queue, so an undo only lives as long as the session.
---@type { items: { entry: table, pos: integer }[], label: string }[]
local undo_groups = {}
local UNDO_LIMIT = 20

local function ensure_hl()
	if hl_done then
		return
	end
	hl_done = true
	vim.api.nvim_set_hl(0, "AskAgentBatchText", { link = "DiagnosticInfo", default = true })
	vim.api.nvim_set_hl(0, "AskAgentBatchTag", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "AskAgentBatchSign", { link = "DiagnosticInfo", default = true })
end

---@param buf integer
---@return boolean
local function loaded(buf)
	return vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)
end

---Draw every entry that lives in `buf`. Called after any change to the entry list.
---@param buf integer
local function draw(buf)
	if not loaded(buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
	local last = vim.api.nvim_buf_line_count(buf)
	for _, it in ipairs(items) do
		if it.buf == buf then
			it.mark = nil
			local prompt_lines = vim.split(it.prompt, "\n", { plain = true })
			local first = prompt_lines[1] or ""
			-- The tag says who this question is routed to, in that instance's fixed color
			local tag, tag_hl = ("[%d]"):format(it.index), "AskAgentBatchTag"
			if it.route then
				tag = ("[%d→%s]"):format(it.index, it.route.name or it.route.id)
				tag_hl = icons.accent_hl(icons.key(it.route)) or tag_hl
			end
			local virt = {
				{ "  » ", "AskAgentBatchSign" },
				{ first, "AskAgentBatchText" },
				{ "  " .. tag, tag_hl },
			}
			local extra = {}
			for i = 2, #prompt_lines do
				table.insert(extra, { { "    │ " .. prompt_lines[i], "AskAgentBatchText" } })
			end
			local line = math.max(1, math.min(it.line or 1, last))
			local ok, mark = pcall(vim.api.nvim_buf_set_extmark, buf, NS, line - 1, it.col or 0, {
				virt_text = virt,
				virt_text_pos = "eol",
				virt_lines = #extra > 0 and extra or nil,
				sign_text = "»",
				sign_hl_group = "AskAgentBatchSign",
				right_gravity = false,
			})
			if ok then
				it.mark = mark
			end
		end
	end
end

---@return integer[]
local function bufs()
	local seen, out = {}, {}
	for _, it in ipairs(items) do
		if not seen[it.buf] then
			seen[it.buf] = true
			table.insert(out, it.buf)
		end
	end
	return out
end

local listeners = {}

---Called after every change to the queue (add / remove / route / update / undo / clear).
---Views (the dashboard) use it instead of polling. Returns an unsubscribe function.
---@param fn function
---@return fun() unsubscribe
function M.on_change(fn)
	table.insert(listeners, fn)
	return function()
		for i, f in ipairs(listeners) do
			if f == fn then
				table.remove(listeners, i)
				return
			end
		end
	end
end

local function notify()
	for _, fn in ipairs(listeners) do
		pcall(fn)
	end
end

---Renumber and repaint every buffer that holds an entry.
function M.redraw()
	ensure_hl()
	for i, it in ipairs(items) do
		it.index = i
	end
	for _, b in ipairs(bufs()) do
		draw(b)
	end
	notify()
end

---Queue one question.
---@param anchor table captured by ask_agent.context (needs `line`, optional `col`/`buf`/`visual`)
---@param prompt string
---@return table entry
function M.add(anchor, prompt)
	ensure_hl()
	next_id = next_id + 1
	local buf = anchor.buf or vim.api.nvim_get_current_buf()
	local line = anchor.line or 1
	local entry = {
		id = next_id,
		anchor = anchor,
		prompt = prompt,
		buf = buf,
		bufname = vim.api.nvim_buf_get_name(buf),
		line = line,
		base = line,
		col = math.max(0, (anchor.col or 1) - 1),
	}
	table.insert(items, entry)
	M.redraw()
	return entry
end

---Assign (nil clears) the agent instance an entry is routed to. Drawn in its marker.
---@param id integer
---@param route table|nil { backend, id, ts?, name? }
---@return boolean ok
function M.route(id, route)
	for _, it in ipairs(items) do
		if it.id == id then
			it.route = route
			M.redraw()
			return true
		end
	end
	return false
end

---Replace an entry's question text (used by the edit action in the list).
---@param id integer
---@param prompt string
---@return boolean ok
function M.update(id, prompt)
	for _, it in ipairs(items) do
		if it.id == id then
			it.prompt = prompt
			M.redraw()
			return true
		end
	end
	return false
end

local function push_undo(items_snapshot, label)
	if #items_snapshot == 0 then
		return
	end
	table.insert(undo_groups, { items = items_snapshot, label = label })
	while #undo_groups > UNDO_LIMIT do
		table.remove(undo_groups, 1)
	end
end

---Follow the marker once more so an undo puts the question back where the code is now,
---then forget the extmark (the entry leaves the list, so the marker must go too).
---@param entry table
local function detach(entry)
	if entry.mark and loaded(entry.buf) then
		local pos = vim.api.nvim_buf_get_extmark_by_id(entry.buf, NS, entry.mark, {})
		if pos and pos[1] then
			entry.line = pos[1] + 1
		end
	end
	entry.mark = nil
end

---Drop one entry and its marker. Undoable with M.undo().
---@param id integer
---@return boolean ok
function M.remove(id)
	for i, it in ipairs(items) do
		if it.id == id then
			detach(it)
			table.remove(items, i)
			push_undo({ { entry = it, pos = i } }, "delete")
			M.redraw()
			return true
		end
	end
	return false
end

---Drop everything (and remove all markers). Undoable with M.undo().
function M.clear()
	local snapshot = {}
	for i, it in ipairs(items) do
		detach(it)
		snapshot[i] = { entry = it, pos = i }
	end
	local all = bufs()
	items = {}
	for _, b in ipairs(all) do
		if loaded(b) then
			vim.api.nvim_buf_clear_namespace(b, NS, 0, -1)
		end
	end
	push_undo(snapshot, "clear")
end

---Restore the most recently deleted entry (or everything removed by the last clear).
---Entries whose buffer has been wiped in the meantime cannot be restored.
---@return integer restored, integer skipped, string|nil label
function M.undo()
	local group = table.remove(undo_groups)
	if not group then
		return 0, 0, nil
	end
	local restored, skipped = 0, 0
	table.sort(group.items, function(a, b)
		return a.pos < b.pos
	end)
	for _, rec in ipairs(group.items) do
		local it = rec.entry
		if loaded(it.buf) then
			it.base = it.line or it.base
			it.mark = nil
			local at = math.min(rec.pos, #items + 1)
			table.insert(items, at, it)
			restored = restored + 1
		else
			skipped = skipped + 1
		end
	end
	if restored > 0 then
		M.redraw()
	end
	return restored, skipped, group.label
end

---@return integer
function M.undo_depth()
	return #undo_groups
end

---Entries in creation order (a copy: batch_send removes entries while iterating).
---@return table[]
function M.list()
	local out = {}
	for i, it in ipairs(items) do
		out[i] = it
	end
	return out
end

---@return integer
function M.count()
	return #items
end

---Current line of an entry, following buffer edits through its extmark, and refresh
---the anchor line (and the selection range, shifted by the same delta) so the agent
---receives the position the question is really attached to now.
---@param entry table
---@return table anchor
function M.sync(entry)
	if entry.mark and loaded(entry.buf) then
		local pos = vim.api.nvim_buf_get_extmark_by_id(entry.buf, NS, entry.mark, {})
		if pos and pos[1] then
			entry.line = pos[1] + 1
		end
	end
	local delta = (entry.line or entry.base or 1) - (entry.base or entry.line or 1)
	entry.anchor.line = entry.line or entry.base
	if entry.anchor.visual then
		entry.original_visual = entry.original_visual or vim.deepcopy(entry.anchor.visual)
		entry.anchor.visual.start_line = entry.original_visual.start_line + delta
		entry.anchor.visual.end_line = entry.original_visual.end_line + delta
	end
	return entry.anchor
end

---Forget entries whose buffer was wiped (their anchors point at nothing).
---@param buf integer
function M.prune_buf(buf)
	local removed = false
	for i = #items, 1, -1 do
		if items[i].buf == buf then
			table.remove(items, i)
			removed = true
		end
	end
	if removed then
		M.redraw()
	end
end

vim.api.nvim_create_autocmd("BufWipeout", {
	group = vim.api.nvim_create_augroup("AskAgentBatchQueue", { clear = true }),
	callback = function(ev)
		M.prune_buf(ev.buf)
	end,
	desc = "ask_agent.nvim: drop queued anchors of a wiped buffer",
})

return M
