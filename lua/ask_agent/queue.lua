-- lua/ask_agent/queue.lua
---@brief Pending-questions queue: collect several anchored questions while browsing, then send them all at once.
--
-- Each entry keeps the anchor captured at creation time plus the question text. The entry is drawn
-- in the source buffer as an extmark (a sign in the sign column plus virtual text at end-of-line),
-- so the question stays attached to the code it is about even while the buffer is edited. Sending
-- happens elsewhere (init.lua): this module only stores, draws and moves entries.
--
-- The queue is per-Neovim-session, in memory only — the same lifetime as the anchors it refers to.

local M = {}

local NS = vim.api.nvim_create_namespace("ask_agent.batch")

---@type table[]
local items = {}
local next_id = 0
local hl_done = false

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
			local virt = {
				{ "  » ", "AskAgentBatchSign" },
				{ first, "AskAgentBatchText" },
				{ ("  [%d]"):format(it.index), "AskAgentBatchTag" },
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

---Renumber and repaint every buffer that holds an entry.
function M.redraw()
	ensure_hl()
	for i, it in ipairs(items) do
		it.index = i
	end
	for _, b in ipairs(bufs()) do
		draw(b)
	end
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

---Drop one entry and its marker.
---@param id integer
---@return boolean ok
function M.remove(id)
	for i, it in ipairs(items) do
		if it.id == id then
			table.remove(items, i)
			M.redraw()
			return true
		end
	end
	return false
end

---Drop everything (and remove all markers).
function M.clear()
	local all = bufs()
	items = {}
	for _, b in ipairs(all) do
		if loaded(b) then
			vim.api.nvim_buf_clear_namespace(b, NS, 0, -1)
		end
	end
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
