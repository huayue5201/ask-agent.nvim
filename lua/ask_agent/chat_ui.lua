-- lua/ask_agent/chat_ui.lua
---@brief The chat transcript as a window: one thread, bubbles, an input box.
--
-- The window is a projection of chat.lua (the log is the truth), so anything
-- posted from `:AskAgentChat` or by an agent's turn shows up here without this
-- module knowing how it happened. Typing goes through ui.input, the same box
-- `:AskAgent` uses, so `@name` is only ever a string until chat.post routes it.
--
--   i / a / <CR>   write a message (`@name` addresses an agent)
--   gp             pin a fact that every agent sees
--   gu             unpin (asks which one)
--   gr             repaint
--   q              close the window

local chat = require("ask_agent.chat")

local M = {}

---Bubbles are plain highlight groups so a colorscheme can restyle them.
local function highlights()
	if vim.g.ask_agent_chat_hl then
		return
	end
	vim.g.ask_agent_chat_hl = true
	vim.api.nvim_set_hl(0, "AskAgentChatUser", { link = "Title", default = true })
	vim.api.nvim_set_hl(0, "AskAgentChatAgent", { link = "Identifier", default = true })
	vim.api.nvim_set_hl(0, "AskAgentChatSystem", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "AskAgentChatPin", { link = "DiagnosticInfo", default = true })
	vim.api.nvim_set_hl(0, "AskAgentChatQueued", { link = "DiagnosticWarn", default = true })
	vim.api.nvim_set_hl(0, "AskAgentChatError", { link = "DiagnosticError", default = true })
	vim.api.nvim_set_hl(0, "AskAgentChatMeta", { link = "Comment", default = true })
end

local ns = vim.api.nvim_create_namespace("ask-agent-chat")
local buf, win, thread_id
local render_scheduled = false

local HL = {
	user = "AskAgentChatUser",
	agent = "AskAgentChatAgent",
	system = "AskAgentChatSystem",
	pin = "AskAgentChatPin",
	queued = "AskAgentChatQueued",
	error = "AskAgentChatError",
	meta = "AskAgentChatMeta",
}

---@param key string
---@return string
local function key_id(key)
	return key
end

---Names shown in a bubble: "me", "claude", "system".
---@param e table
---@return string
local function author_of(e)
	if e.author == "user" then
		return "me"
	elseif e.author == "agent" then
		return e.name or key_id(e.target or "agent")
	end
	return "system"
end

---@param ts integer|nil
---@return string
local function clock(ts)
	return os.date("%H:%M", math.floor((ts or 0) / 1000))
end

---Break a paragraph into display-width chunks: words first (so ASCII text keeps
---its spaces), cells for anything a word cannot fit (CJK, long paths).
---@param text string
---@param width integer
---@param indent string|nil prefix kept on every line (so bubbles stay indented)
---@return string[]
local function fit(text, width, indent)
	indent = indent or ""
	width = math.max(8, width - vim.fn.strdisplaywidth(indent))
	local out = {}
	local line, used = "", 0
	local function flush()
		out[#out + 1] = line == "" and "" or (indent .. line)
		line, used = "", 0
	end
	for _, word in ipairs(vim.split(text, " ", { plain = true })) do
		local w = vim.fn.strdisplaywidth(word)
		local sep = line == "" and 0 or 1
		if used + sep + w <= width then
			line = line == "" and word or (line .. " " .. word)
			used = used + sep + w
		elseif w <= width then
			flush()
			line, used = word, w
		else
			if line ~= "" then
				flush()
			end
			for _, ch in ipairs(vim.fn.split(word, "\\zs")) do
				local cw = vim.fn.strdisplaywidth(ch)
				if used + cw > width then
					flush()
				end
				line = line .. ch
				used = used + cw
			end
		end
	end
	flush()
	return out
end

---@return integer
local function body_width()
	if win and vim.api.nvim_win_is_valid(win) then
		return math.max(20, vim.api.nvim_win_get_width(win) - 4)
	end
	return math.max(20, vim.o.columns - 4)
end

---@return { lines: string[], marks: { row: integer, group: string, from: integer, to: integer }[] }
local function build()
	local width = body_width()
	local lines, marks = {}, {}

	---@param s string
	---@param group string|nil
	local function push(s, group)
		lines[#lines + 1] = s
		if group then
			marks[#marks + 1] = { row = #lines - 1, group = group, from = 0, to = #s }
		end
	end

	local t = chat.get(thread_id)
	if not t then
		push("  no such thread", HL.system)
		return { lines = lines, marks = marks }
	end

	local pins = t.pins or {}
	if #pins > 0 then
		push("  facts", HL.pin)
		for _, p in ipairs(pins) do
			for _, l in ipairs(fit(p, width, "  · ")) do
				push(l, "Comment")
			end
		end
		push("", nil)
	end

	for _, e in ipairs(t.entries) do
		local is_user = e.author == "user"
		local arrow = is_user and "▍" or (e.kind == "system" and "·" or "◂")
		local status = e.status and e.status ~= "done" and e.status ~= "running" and (" · " .. e.status) or ""
		local head = ("%s %s  %s%s"):format(arrow, clock(e.ts), author_of(e), status)
		local group = is_user and HL.user or (e.kind == "system" and HL.system or HL.agent)
		if e.status == "queued" then
			group = HL.queued
		elseif e.status == "error" then
			group = HL.error
		end
		push(head, group)
		for _, raw in ipairs(vim.split(e.text or "", "\n", { plain = true })) do
			for _, l in ipairs(fit(raw, width, "  ")) do
				push(l, e.kind == "system" and "Comment" or nil)
			end
		end
		push("", nil)
	end

	-- drop the trailing blank so the window does not end on an empty line
	while #lines > 0 and lines[#lines] == "" do
		lines[#lines] = nil
		local kept = {}
		for _, m in ipairs(marks) do
			if m.row < #lines then
				kept[#kept + 1] = m
			end
		end
		marks = kept
	end
	return { lines = lines, marks = marks }
end

---@return boolean
local function at_bottom()
	if not win or not vim.api.nvim_win_is_valid(win) then
		return false
	end
	local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
	return vim.api.nvim_win_get_cursor(win)[1] >= last - 1
end

local function render()
	local rendered = build()
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local follow = at_bottom()
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, rendered.lines)
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for _, m in ipairs(rendered.marks) do
		pcall(vim.api.nvim_buf_add_highlight, buf, ns, m.group, m.row, m.from, m.to)
	end
	vim.bo[buf].modifiable = false
	if win and vim.api.nvim_win_is_valid(win) then
		local running = vim.tbl_count(chat.running())
		local pending = #chat.pending()
		local bits = { (" ask-agent chat · %s "):format(chat.get(thread_id) and chat.get(thread_id).name or "?") }
		if running > 0 then
			bits[#bits + 1] = ("◐ %d"):format(running)
		end
		if pending > 0 then
			bits[#bits + 1] = ("⏳ %d"):format(pending)
		end
		vim.wo[win].winbar = table.concat(bits, "  ")
		if follow then
			local last = math.max(1, vim.api.nvim_buf_line_count(buf))
			pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
		end
	end
end

local function schedule_render()
	if render_scheduled then
		return
	end
	render_scheduled = true
	vim.schedule(function()
		render_scheduled = false
		render()
	end)
end

---Ask for text in the shared input float and post it as a chat message.
local function compose(default)
	require("ask_agent.ui").input({
		title = "chat · " .. ((chat.get(thread_id) or {}).name or "main"),
		default = default,
		on_submit = function(text)
			chat.post(text, { thread = thread_id })
			if win and vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_set_current_win(win)
			end
		end,
	})
end

---@param b integer buffer
local function attach(b)
	vim.bo[b].filetype = "ask-agent-chat"
	local o = { buffer = b, nowait = true }
	vim.keymap.set("n", "i", function()
		compose()
	end, vim.tbl_extend("force", o, { desc = "Chat: write a message" }))
	vim.keymap.set("n", "a", function()
		compose()
	end, o)
	vim.keymap.set("n", "<CR>", function()
		compose()
	end, o)
	vim.keymap.set("n", "gp", function()
		require("ask_agent.ui").input({
			title = "pin a fact",
			on_submit = function(text)
				chat.pin(thread_id, text)
			end,
		})
	end, vim.tbl_extend("force", o, { desc = "Chat: pin a fact for every agent" }))
	vim.keymap.set("n", "gu", function()
		local pins = chat.pins(thread_id)
		if #pins == 0 then
			vim.notify("[ask_agent] nothing is pinned", vim.log.levels.INFO)
			return
		end
		vim.ui.select(pins, { prompt = "Unpin" }, function(choice)
			if choice then
				chat.unpin(thread_id, choice)
			end
		end)
	end, o)
	vim.keymap.set("n", "gr", render, o)
	vim.keymap.set("n", "q", function()
		if win and vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end, o)
	vim.keymap.set("n", "<Esc>", function()
		if win and vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end, o)
end

---Open (or focus) the chat window for a thread.
---@param o { thread?: string, pos?: "left"|"right", width?: integer, name?: string }|nil
function M.open(o)
	o = o or {}
	highlights()
	thread_id = chat.thread(o.thread or chat.current() or "main")
	if o.name then
		local t = chat.get(thread_id)
		if t then
			t.name = o.name
		end
	end
	if win and vim.api.nvim_win_is_valid(win) and buf and vim.api.nvim_buf_is_valid(buf) then
		if vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage() then
			vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(win))
		end
		vim.api.nvim_set_current_win(win)
		render()
		return win
	end
	buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype, vim.bo[buf].bufhidden = "nofile", "wipe"
	vim.bo[buf].swapfile, vim.bo[buf].buflisted = false, false
	vim.api.nvim_buf_set_name(buf, "ask-agent://chat")
	local width = o.width or math.max(40, math.min(vim.o.columns - 20, 72))
	vim.cmd((o.pos == "left" and "topleft " or "botright ") .. "vsplit")
	win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_width(win, width)
	vim.wo[win].number, vim.wo[win].relativenumber = false, false
	vim.wo[win].signcolumn, vim.wo[win].foldcolumn = "no", "0"
	vim.wo[win].wrap, vim.wo[win].spell = false, false
	vim.wo[win].cursorline = false
	attach(buf)
	local group = vim.api.nvim_create_augroup("AskAgentChatUI", { clear = true })
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, { group = group, callback = render })
	vim.api.nvim_buf_attach(buf, false, {
		on_detach = function()
			pcall(vim.api.nvim_del_augroup_by_id, group)
			buf, win = nil, nil
		end,
	})
	render()
	vim.api.nvim_win_set_cursor(win, { math.max(1, vim.api.nvim_buf_line_count(buf)), 0 })
	return win
end

---@return string|nil
function M.thread()
	return thread_id
end

---Close the window (tests and `:AskAgentChat close`).
function M.close()
	if win and vim.api.nvim_win_is_valid(win) then
		pcall(vim.api.nvim_win_close, win, true)
	end
end

chat.on("entry", schedule_render)
chat.on("thread", schedule_render)

return M
