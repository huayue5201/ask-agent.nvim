-- lua/ask_agent/context.lua
---@brief Collect the "question anchor": tells the receiver which project / tab /
---file / line / selection the question was asked about.
--
-- Why it exists: with several tabs and projects (tab_workspace uses :tcd to give
-- every tab its own cwd), only nvim knows which project is on screen. Instead of
-- letting the external agent guess, the anchor is pinned at the moment of asking
-- and sent along with the question.
--
-- Pure collection, agent-agnostic -- whoever receives it gets the same data.

local M = {}

---Capture the anchor. With visual=true it uses the current visual selection
---(reading getpos("v")/(".") live rather than relying on '< '>).
---@param visual boolean|nil
---@return table anchor
function M.capture(visual)
	local buf = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(0)
	local name = vim.api.nvim_buf_get_name(buf)
	local path = name ~= "" and vim.fn.fnamemodify(name, ":p") or nil
	local a = {
		cwd = vim.fn.getcwd(),
		tab = vim.fn.tabpagenr(),
		buf = buf,
		bufname = name,
		path = path and vim.fn.fnamemodify(path, ":~:.") or nil,
		line = cursor[1],
		col = cursor[2] + 1,
		filetype = vim.bo[buf].filetype,
		modified = vim.bo[buf].modified,
	}
	if visual then
		local s, e = vim.fn.getpos("v"), vim.fn.getpos(".")
		local sl, el = math.min(s[2], e[2]), math.max(s[2], e[2])
		if sl > 0 and el > 0 then
			a.visual = {
				start_line = sl,
				end_line = el,
				lines = vim.api.nvim_buf_get_lines(buf, sl - 1, el, false),
			}
			a.line = sl
		end
	end
	return a
end

---One-line description of the anchor, for the floating prompt title.
---@param a table
---@return string
function M.describe(a)
	local bits = { a.path and ("%s:%d"):format(a.path, a.line) or "<no filename>" }
	if a.visual then
		table.insert(bits, ("selection %d-%d"):format(a.visual.start_line, a.visual.end_line))
	end
	if a.modified then
		table.insert(bits, "unsaved")
	end
	return table.concat(bits, " · ")
end

---Absolute, symlink-resolved path of the file an anchor names, or nil.
---@param a table anchor
---@return string|nil
local function anchor_file(a)
	if not a or not a.path or a.path == "" then
		return nil
	end
	local path = a.path
	if not path:match("^/") and not path:match("^~") then
		-- anchor.path is recorded relative to the anchor's cwd (":~:."), so resolve
		-- it there rather than against whatever directory we are in now.
		path = (a.cwd or vim.fn.getcwd()) .. "/" .. path
	end
	return vim.fn.resolve(vim.fn.fnamemodify(vim.fn.expand(path), ":p"))
end

---@param file string
---@param dir string
---@return boolean
local function inside(file, dir)
	dir = dir:gsub("/+$", "")
	return file == dir or file:sub(1, #dir + 1) == dir .. "/"
end

---The directory that counts as "the current project": the working directory of
---this tab, widened to its repository root when there is one (a file in a
---sibling directory of the same repo is still the same project).
---@return string
local function project_root()
	local cwd = vim.fn.resolve(vim.fn.fnamemodify(vim.fn.getcwd(), ":p"))
	local ok, root = pcall(vim.fs.root, cwd, ".git")
	if ok and type(root) == "string" and root ~= "" then
		return vim.fn.resolve(root)
	end
	return cwd
end

---Open a file in a tab of its own — another project belongs in its own tab, not
---in the window of the one on screen. The tab takes the anchor's working
---directory, so project-scoped tools keep working there.
---@param cwd string|nil
local function new_tab(cwd)
	vim.cmd("tabnew")
	if cwd and cwd ~= "" and vim.fn.isdirectory(cwd) == 1 then
		pcall(vim.cmd, "tcd " .. vim.fn.fnameescape(cwd))
	end
end

---Jump to the buffer/line an anchor points at. Returns false + reason when the
---buffer is gone or its number was reused by a different file.
---@param a table anchor (needs `buf`, optional `bufname`, `line`, `col`)
---@return boolean ok, string|nil err
function M.jump_to(a)
	local buf = a and a.buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return false, "the buffer of this anchor no longer exists"
	end
	if a.bufname and a.bufname ~= "" and vim.api.nvim_buf_get_name(buf) ~= a.bufname then
		return false, "the buffer number was reused by another file"
	end
	-- win_findbuf looks in every tab, bufwinid only in the current one; an
	-- anchor captured in another tab has to switch tabs, not open a second copy.
	local wins = vim.fn.win_findbuf(buf)
	if #wins > 0 then
		vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(wins[1]))
		vim.api.nvim_set_current_win(wins[1])
	else
		-- Load into a normal editing window, never into the sidebar/panel the jump was
		-- started from: a special buffer (dashboard, quickfix, terminal, float) must keep
		-- its own content. With no editor window left, open a tab instead of splitting
		-- the sidebar.
		local file = anchor_file(a)
		local elsewhere = file ~= nil and not inside(file, project_root())
		if elsewhere then
			new_tab(a.cwd)
			vim.api.nvim_win_set_buf(0, buf)
		else
			local win = vim.api.nvim_get_current_win()
			local cur = vim.api.nvim_win_get_buf(win)
			if vim.bo[cur].buftype ~= "" or vim.api.nvim_win_get_config(win).relative ~= "" then
				win = nil
				for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
					local b = vim.api.nvim_win_get_buf(w)
					if vim.bo[b].buftype == "" and vim.api.nvim_win_get_config(w).relative == "" then
						win = w
						break
					end
				end
				if not win then
					vim.cmd("tabnew")
					win = vim.api.nvim_get_current_win()
				end
			end
			vim.api.nvim_win_set_buf(win, buf)
			vim.api.nvim_set_current_win(win)
		end
	end
	local line = math.max(1, math.min(a.line or 1, vim.api.nvim_buf_line_count(buf)))
	vim.api.nvim_win_set_cursor(0, { line, (a.col or 1) - 1 })
	vim.cmd("normal! zz")
	return true, nil
end

---Go to what an anchor points at, falling back to the file it names.
---
---`jump_to` needs the buffer the anchor was captured in, and Neovim recycles
---buffer numbers: after a `:bd` the number can belong to a different file, and
---the anchor then cannot be trusted to still be the same text. The path and line
---are still good, so an anchor that only survives in that weaker form is opened
---from disk instead of failing.
---@param a table anchor (needs `path` for the fallback)
---@return boolean ok, string|nil err
function M.open(a)
	local ok, err = M.jump_to(a)
	if ok then
		return true, nil
	end
	local file = anchor_file(a)
	if not file then
		return false, err
	end
	if vim.fn.filereadable(file) == 0 then
		return false, (err and (err .. " — ") or "") .. "the file no longer exists: " .. a.path
	end
	if not inside(file, project_root()) then
		new_tab(a.cwd)
	end
	vim.cmd.edit(vim.fn.fnameescape(file))
	local line = math.max(1, a.line or 1)
	vim.api.nvim_win_set_cursor(0, { math.min(line, vim.api.nvim_buf_line_count(0)), math.max(0, (a.col or 1) - 1) })
	vim.cmd("normal! zz")
	return true, nil
end

return M
