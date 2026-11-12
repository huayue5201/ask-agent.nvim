-- lua/ask_agent/chat_ui.lua
---@brief The chat as a floating window: messages on top, an input bar below.
--
-- Two floats make the panel: the transcript (read-only, bubbles) and a one-line
-- input right underneath, so the picture reads top-to-bottom like a chat app
-- instead of a split stealing editor space. The window is a projection of
-- chat.lua (the log is the truth); typing only ever produces text until
-- chat.post routes it.
--
--   i / a / <CR>   jump to the input bar (it starts focused when the panel opens)
--   <C-s>          send (also <CR> in normal mode of the input bar)
--   <Esc>          leave the input bar (nothing is sent)
--   @              completing here lists the agents you can address
--   gp / gu        pin / unpin a fact every agent sees
--   gr / q         repaint / close

local chat = require("ask_agent.chat")

local M = {}

local ns = vim.api.nvim_create_namespace("ask-agent-chat")
local msg_buf, msg_win
local in_buf, in_win
local thread_id
local render_scheduled = false
local forced_width -- tests ask for a fixed panel width

local HL = {
	user = "AskAgentChatUser",
	agent = "AskAgentChatAgent",
	system = "AskAgentChatSystem",
	pin = "AskAgentChatPin",
	queued = "AskAgentChatQueued",
	error = "AskAgentChatError",
}

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
end

---@param key string
---@return string
local function short(key)
	return key
end

---@param e table
---@return string
local function author_of(e)
	if e.author == "user" then
		return "me"
	elseif e.author == "agent" then
		return e.name or short(e.target or "agent")
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
---@param indent string|nil prefix kept on every line
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

---Right-align a line inside the panel (the "outgoing" side of a chat).
---@param line string
---@param width integer
---@return string
local function right(line, width)
	local pad = math.max(0, width - vim.fn.strdisplaywidth(line))
	return string.rep(" ", pad) .. line
end

---@return integer
local function panel_width()
	if forced_width then
		return forced_width
	end
	if msg_win and vim.api.nvim_win_is_valid(msg_win) then
		return vim.api.nvim_win_get_width(msg_win)
	end
	return math.max(20, math.min(vim.o.columns - 6, math.floor(vim.o.columns * 0.62)))
end

---@return { lines: string[], marks: { row: integer, group: string, from: integer, to: integer }[] }
local function build()
	local width = panel_width() - 2
	local lines, marks = {}, {}

	---@param s string
	---@param group string|nil
	local function push(s, group, align_right)
		if align_right then
			s = right(s, width)
		end
		lines[#lines + 1] = s
		if group and #s > 0 then
			marks[#marks + 1] = { row = #lines - 1, group = group, from = 0, to = #s }
		end
	end

	local t = chat.get(thread_id)
	if not t then
		push(" no such thread", HL.system)
		return { lines = lines, marks = marks }
	end

	local pins = t.pins or {}
	if #pins > 0 then
		push(" facts", HL.pin)
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
		local status = (e.status and e.status ~= "done" and e.status ~= "running") and (" · " .. e.status) or ""
		local head = is_user and ("%s  %s %s%s"):format(clock(e.ts), author_of(e), arrow, status)
			or ("%s %s  %s%s"):format(arrow, clock(e.ts), author_of(e), status)
		local group = is_user and HL.user or (e.kind == "system" and HL.system or HL.agent)
		if e.status == "queued" then
			group = HL.queued
		elseif e.status == "error" then
			group = HL.error
		end
		push(head, group, is_user)
		for _, raw in ipairs(vim.split(e.text or "", "\n", { plain = true })) do
			for _, l in ipairs(fit(raw, width, is_user and "" or "  ")) do
				push(l, e.kind == "system" and "Comment" or nil, is_user)
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
	if not msg_win or not vim.api.nvim_win_is_valid(msg_win) then
		return false
	end
	local last = vim.api.nvim_buf_line_count(msg_buf)
	return vim.api.nvim_win_get_cursor(msg_win)[1] >= last - 1
end

---The member list: who can be addressed, and who is busy right now.
---@return string
local function members()
	local roster = chat.roster()
	local bits = {}
	for _, a in ipairs(roster) do
		bits[#bits + 1] = a.name
	end
	return table.concat(bits, " ")
end

local function render()
	local rendered = build()
	if not msg_buf or not vim.api.nvim_buf_is_valid(msg_buf) then
		return
	end
	local follow = at_bottom()
	vim.bo[msg_buf].modifiable = true
	vim.api.nvim_buf_set_lines(msg_buf, 0, -1, false, rendered.lines)
	vim.api.nvim_buf_clear_namespace(msg_buf, ns, 0, -1)
	for _, m in ipairs(rendered.marks) do
		pcall(vim.api.nvim_buf_add_highlight, msg_buf, ns, m.group, m.row, m.from, m.to)
	end
	vim.bo[msg_buf].modifiable = false
	if msg_win and vim.api.nvim_win_is_valid(msg_win) then
		local running = vim.tbl_count(chat.running())
		local pending = #chat.pending()
		local bits = {}
		if running > 0 then
			bits[#bits + 1] = ("◐ %d"):format(running)
		end
		if pending > 0 then
			bits[#bits + 1] = ("⏳ %d"):format(pending)
		end
		local who = members()
		if who ~= "" then
			bits[#bits + 1] = "· " .. who
		end
		bits[#bits + 1] = "· <C-S> send · q close"
		local footer = table.concat(bits, " ")
		local cfg = vim.api.nvim_win_get_config(msg_win)
		cfg.relative, cfg.border, cfg.footer, cfg.footer_pos = "editor", "rounded", " " .. footer .. " ", "right"
		vim.api.nvim_win_set_config(msg_win, cfg)
		if follow then
			local last = math.max(1, vim.api.nvim_buf_line_count(msg_buf))
			pcall(vim.api.nvim_win_set_cursor, msg_win, { last, 0 })
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

---Geometry: the panel is one column wide, the input bar hugs the transcript's
---bottom edge so the two borders read as one box.
local function layout()
	if not (msg_win and vim.api.nvim_win_is_valid(msg_win)) or not (in_win and vim.api.nvim_win_is_valid(in_win)) then
		return
	end
	local w = panel_width()
	local h = math.max(10, math.min(vim.o.lines - 6, math.floor(vim.o.lines * 0.72)))
	local body = math.max(4, h - 4) -- transcript rows (input bar = 1 row + its borders, sharing one)
	local row = math.max(0, math.floor((vim.o.lines - h) / 2))
	local col = math.max(0, math.floor((vim.o.columns - w) / 2))
	vim.api.nvim_win_set_config(msg_win, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		width = w,
		height = body,
		row = row,
		col = col,
		title = (" chat · %s "):format((chat.get(thread_id) or {}).name or "?"),
		title_pos = "left",
	})
	vim.api.nvim_win_set_config(in_win, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		width = w,
		height = 1,
		row = row + body + 2,
		col = col,
		title = " message · @ to address ",
		title_pos = "left",
	})
end

---Fill in the input with the current text (used by `i` from the transcript).
local function focus_input(insert)
	if not (in_win and vim.api.nvim_win_is_valid(in_win)) then
		return
	end
	vim.api.nvim_set_current_win(in_win)
	if insert ~= false then
		vim.cmd("startinsert!")
		-- startup (and a re-open during a `:lua` call) can swallow startinsert, so
		-- make sure the cursor really is in the input bar, ready to type
		vim.schedule(function()
			if not (in_win and vim.api.nvim_win_is_valid(in_win)) then
				return
			end
			if vim.api.nvim_get_current_win() ~= in_win then
				return
			end
			if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
				vim.cmd("startinsert")
			end
		end)
	end
end

local function send()
	if not (in_buf and vim.api.nvim_buf_is_valid(in_buf)) then
		return
	end
	local text = table.concat(vim.api.nvim_buf_get_lines(in_buf, 0, -1, false), "\n")
	if vim.trim(text) == "" then
		return
	end
	vim.api.nvim_buf_set_lines(in_buf, 0, -1, false, { "" })
	chat.post(text, { thread = thread_id })
	if msg_win and vim.api.nvim_win_is_valid(msg_win) then
		pcall(vim.api.nvim_win_set_cursor, msg_win, { math.max(1, vim.api.nvim_buf_line_count(msg_buf)), 0 })
	end
	render()
	focus_input()
end

---`@` completion: the roster, filtered by what has been typed after the @.
---@return table[] items
local function mention_items()
	return chat.roster()
end

local function complete_mentions()
	local line = vim.api.nvim_get_current_line()
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	if row ~= 1 then
		return
	end
	local before = line:sub(1, col)
	local typed = before:match("@([%w_%-%.]*)$")
	if not typed then
		return
	end
	local start = col - #typed + 1 -- 1-based byte column of the typed name
	local items = {}
	for _, a in ipairs(mention_items()) do
		if typed == "" or a.name:lower():sub(1, #typed) == typed:lower() then
			items[#items + 1] = {
				word = a.name,
				menu = "[%s]" .. (a.busy and " busy" or " "),
				info = ("%s · %s"):format(a.key, a.state),
				dup = 0,
			}
		end
	end
	if #items == 0 then
		return
	end
	vim.fn.complete(start, items)
end

---@param b integer buffer
local function attach_transcript(b)
	vim.bo[b].filetype = "ask-agent-chat"
	local o = { buffer = b, nowait = true, silent = true }
	vim.keymap.set("n", "i", function()
		focus_input()
	end, vim.tbl_extend("force", o, { desc = "Chat: write a message" }))
	vim.keymap.set("n", "a", function()
		focus_input()
	end, o)
	vim.keymap.set("n", "<CR>", function()
		focus_input()
	end, o)
	vim.keymap.set("n", "gp", function()
		require("ask_agent.ui").input({
			title = "pin a fact",
			on_submit = function(text)
				chat.pin(thread_id, text)
				render()
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
				render()
			end
		end)
	end, o)
	vim.keymap.set("n", "gr", render, o)
	vim.keymap.set("n", "q", M.close, o)
	vim.keymap.set("n", "<Esc>", M.close, o)
end

---@param b integer buffer
local function attach_input(b)
	vim.bo[b].filetype = "markdown"
	vim.bo[b].buftype = "nofile"
	-- keep completion plugins out: this line has its own @ completion (and a
	-- stray LSP/blink menu would fight it)
	vim.b[b].completion = false
	vim.b[b].minuet_virtual_text_auto_trigger = false
	local o = { buffer = b, nowait = true, silent = true }
	vim.keymap.set("i", "<CR>", send, vim.tbl_extend("force", o, { desc = "Chat: send" }))
	vim.keymap.set("i", "<C-s>", send, o)
	-- <CR> sends, so a multi-line message needs its own key
	vim.keymap.set("i", "<C-j>", function()
		local line, col = unpack(vim.api.nvim_win_get_cursor(0))
		vim.api.nvim_buf_set_text(0, line - 1, col, line - 1, col, { "\n" })
		vim.api.nvim_win_set_cursor(0, { line + 1, 0 })
	end, o)
	vim.keymap.set("n", "<C-s>", send, o)
	vim.keymap.set("n", "<CR>", send, o)
	vim.keymap.set("n", "q", M.close, o)
	vim.keymap.set("n", "<C-q>", M.close, o)
	vim.keymap.set("i", "<C-q>", function()
		vim.cmd("stopinsert")
		M.close()
	end, o)
	vim.keymap.set("n", "<Esc>", function()
		if msg_win and vim.api.nvim_win_is_valid(msg_win) then
			vim.api.nvim_set_current_win(msg_win)
		end
	end, o)
	-- one <Esc> leaves the input and returns to the transcript (a second one,
	-- there, closes the panel — the same as pressing it in a chat app)
	vim.keymap.set("i", "<Esc>", function()
		vim.cmd("stopinsert")
		if msg_win and vim.api.nvim_win_is_valid(msg_win) then
			vim.api.nvim_set_current_win(msg_win)
		end
	end, vim.tbl_extend("force", o, { desc = "Chat: leave the input" }))
	local group = vim.api.nvim_create_augroup("AskAgentChatInput", { clear = true })
	vim.api.nvim_create_autocmd("TextChangedI", {
		group = group,
		buffer = b,
		callback = function()
			complete_mentions()
		end,
	})
end

---@return integer|nil messages window
function M.open(o)
	o = o or {}
	highlights()
	forced_width = o.width
	thread_id = chat.thread(o.thread or chat.current() or "main")
	if o.name then
		local t = chat.get(thread_id)
		if t then
			t.name = o.name
		end
	end
	if msg_win and vim.api.nvim_win_is_valid(msg_win) and in_win and vim.api.nvim_win_is_valid(in_win) then
		layout()
		render()
		focus_input()
		return msg_win
	end

	msg_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[msg_buf].buftype, vim.bo[msg_buf].bufhidden = "nofile", "wipe"
	vim.bo[msg_buf].swapfile, vim.bo[msg_buf].buflisted = false, false
	vim.api.nvim_buf_set_name(msg_buf, "ask-agent://chat")
	msg_win = vim.api.nvim_open_win(msg_buf, false, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		width = 40,
		height = 10,
		row = 0,
		col = 0,
	})
	vim.wo[msg_win].wrap, vim.wo[msg_win].number, vim.wo[msg_win].relativenumber = false, false, false
	vim.wo[msg_win].signcolumn, vim.wo[msg_win].foldcolumn = "no", "0"
	vim.wo[msg_win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"

	in_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[in_buf].buftype, vim.bo[in_buf].bufhidden = "nofile", "wipe"
	vim.bo[in_buf].swapfile, vim.bo[in_buf].buflisted = false, false
	in_win = vim.api.nvim_open_win(in_buf, true, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		width = 40,
		height = 1,
		row = 0,
		col = 0,
	})
	vim.wo[in_win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"
	vim.wo[in_win].wrap = false

	attach_transcript(msg_buf)
	attach_input(in_buf)
	layout()
	render()

	local group = vim.api.nvim_create_augroup("AskAgentChatUI", { clear = true })
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, { group = group, callback = layout })
	vim.api.nvim_buf_attach(msg_buf, false, {
		on_detach = function()
			pcall(vim.api.nvim_del_augroup_by_id, group)
			if in_win and vim.api.nvim_win_is_valid(in_win) then
				pcall(vim.api.nvim_win_close, in_win, true)
			end
			msg_buf, msg_win, in_buf, in_win = nil, nil, nil, nil
		end,
	})
	focus_input()
	vim.api.nvim_win_set_cursor(msg_win, { math.max(1, vim.api.nvim_buf_line_count(msg_buf)), 0 })
	return msg_win
end

---@return string|nil
function M.thread()
	return thread_id
end

---@return integer|nil the input window (tests drive it)
function M.input_win()
	return in_win
end

---Close both floats (tests and `:AskAgentChat close`).
function M.close()
	for _, w in ipairs({ in_win, msg_win }) do
		if w and vim.api.nvim_win_is_valid(w) then
			pcall(vim.api.nvim_win_close, w, true)
		end
	end
end

chat.on("entry", schedule_render)
chat.on("thread", schedule_render)

return M
