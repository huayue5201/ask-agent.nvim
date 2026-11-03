-- lua/ask_agent/ui.lua
---@brief Floating input box: write a question; in normal mode <CR> hands it to on_submit(text). Agent-agnostic.
--
-- Keys deliberately avoid intruding on Vim's two modes:
--   insert: except <A-]> (minuet completion) and <C-s> (send directly), everything is native — <CR>/<C-j> insert newlines
--   normal: <CR> sends, <Esc>/q cancels, <C-c> cancels
--
-- Why a floating window instead of an :edit temp file / codecompanion: asking is a one-off 5-second action,
-- not worth opening a buffer, switching windows, and managing a file's lifecycle.

local M = {}

--- Open the input floating window
---@param opts { title: string, on_submit: fun(text: string), prompt?: string }
---@return integer buf, integer win
function M.input(opts)
	local ui_w, ui_h = vim.o.columns, vim.o.lines
	local width = math.max(40, math.min(ui_w - 8, 92))
	local height = 8

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].buflisted = false
	-- markdown: lets minuet (auto_trigger_ft includes markdown) complete inside the input window too.
	-- But keep manual trigger only: with an empty nofile context and a free-form question, automatic
	-- suggestions are inevitably off-topic, wasting a FIM request (measured: an unrelated full ghost
	-- after 2.9s in an empty buffer), so disable buffer-level auto_trigger and pull one on demand with <A-]>.
	vim.bo[buf].filetype = "markdown"
	vim.b[buf].minuet_virtual_text_auto_trigger = false -- minuet virtualtext.lua:26 reads this variable directly

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		width = width,
		height = height,
		row = math.max(0, math.floor((ui_h - height) / 2) - 1),
		col = math.max(0, math.floor((ui_w - width) / 2)),
		title = " " .. opts.title .. " ",
		title_pos = "center",
		footer = " <C-s> send · <Esc> leave insert · <CR> in normal mode sends · q close · <A-]> complete ",
		footer_pos = "center",
		noautocmd = true,
	})
	vim.wo[win].wrap = true
	vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"

	local function close()
		-- The floating window is the current window: closing it directly leaves insert mode
		-- in the buffer underneath, so the next keystroke types into code. Exit insert first.
		if vim.fn.mode():match("^[iR]") then
			vim.cmd("stopinsert")
		end
		if vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end

	local function submit()
		local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
		if vim.trim(text) == "" then
			close()
			return
		end
		close()
		opts.on_submit(text)
	end

	-- Only send in normal mode: <CR> in insert keeps the native newline, same for <C-j>
	vim.keymap.set("n", "<CR>", submit, { buffer = buf, nowait = true, desc = "Ask agent: send question" })
	-- <C-s> sends directly from insert mode: no need to leave normal mode after writing
	vim.keymap.set("i", "<C-s>", submit, { buffer = buf, nowait = true, desc = "Ask agent: send question" })
	-- <Esc>/<C-c> keep their defaults in insert mode (leave insert, keep the window); only normal mode closes it
	vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true, desc = "Ask agent: cancel" })
	vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, desc = "Ask agent: cancel" })
	vim.keymap.set("n", "<C-c>", close, { buffer = buf, nowait = true, desc = "Ask agent: cancel" })

	vim.cmd("startinsert")
	return buf, win
end

return M
