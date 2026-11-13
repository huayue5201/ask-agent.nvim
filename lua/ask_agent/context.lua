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

-- Directories review.lua extracts a git tree into (git.tempdir("ask-agent-tree")
-- is `<tempname>-ask-agent-tree`). A file under one of them is real text, but it
-- is a *copy at that revision*: writing to it changes nothing, and the file may
-- not exist in the project at all.
local COPY_DIR = { "%-ask%-agent%-tree$", "%-ask%-agent%-view$" }

---@param path string
---@return string|nil rel path inside the extracted tree, when `path` is a copy
local function extracted(path)
	local dir = vim.fn.fnamemodify(path, ":h"):gsub("/+$", "")
	while dir ~= "" and dir ~= "/" do
		for _, pattern in ipairs(COPY_DIR) do
			if dir:match(pattern) then
				return path:sub(#dir + 2)
			end
		end
		dir = vim.fn.fnamemodify(dir, ":h"):gsub("/+$", "")
	end
	return nil
end

---@param file string
---@param dir string
---@return boolean
local function inside(file, dir)
	dir = dir:gsub("/+$", "")
	return file == dir or file:sub(1, #dir + 1) == dir .. "/"
end

---How much source an anchor carries on its own. Only buffers whose content the
---agent cannot get from disk travel with their text (unsaved, or no file at all);
---for everything else `path:line` is enough and the agent reads the file itself.
M.lines = 20 -- lines of source around the cursor
---Longest selection inlined into the question (lines, then bytes).
M.max_selection = 200
M.max_selection_bytes = 8192

---@param o { lines?: integer, max_selection?: integer, max_selection_bytes?: integer }|nil
function M.setup(o)
	if type(o) ~= "table" then
		return
	end
	for _, name in ipairs({ "lines", "max_selection", "max_selection_bytes" }) do
		local n = math.floor(tonumber(o[name]) or -1)
		if n >= 0 then
			M[name] = n
		end
	end
end

---The repository root for `dir` (cached by ask_agent.git), or nil.
---@param dir string
---@return string|nil
local function repo_root(dir)
	local ok, root = pcall(function()
		return require("ask_agent.git").root(dir)
	end)
	if ok and type(root) == "string" and root ~= "" then
		return root
	end
	return nil
end

local branches = {} -- root -> branch | false

---The branch `root` is on, or nil (detached HEAD, no repo, or git failed).
---@param root string
---@return string|nil
local function branch_of(root)
	if branches[root] ~= nil then
		return branches[root] or nil
	end
	local ok, name = pcall(function()
		local good, out = require("ask_agent.git").git(root, { "rev-parse", "--abbrev-ref", "HEAD" })
		return (good and type(out) == "string") and vim.trim(out) or nil
	end)
	name = (ok and type(name) == "string") and name or nil
	if not name or name == "" or name == "HEAD" then
		name = nil
	end
	branches[root] = name or false
	return name
end

---Diagnostics sitting on `line` (error/warn only, at most three).
---@param buf integer
---@param line integer
---@return table[]|nil
function M.diagnostics(buf, line)
	local ok, list = pcall(vim.diagnostic.get, buf, { lnum = line - 1 })
	if not ok or type(list) ~= "table" then
		return nil
	end
	local SEV = { "error", "warn", "info", "hint" }
	local out = {}
	for _, d in ipairs(list) do
		if type(d.severity) == "number" and d.severity <= vim.diagnostic.severity.WARN and #out < 3 then
			out[#out + 1] = {
				line = (d.lnum or (line - 1)) + 1,
				severity = SEV[d.severity] or "info",
				source = d.source,
				message = ((d.message or ""):gsub("\n.*", "")),
			}
		end
	end
	return #out > 0 and out or nil
end

---The source around the cursor, when the file on disk is not what is on screen.
---@param a table anchor
---@return table|nil
function M.snippet(a)
	local buf = a.buf
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return nil
	end
	-- A saved file is readable through `path`; an unsaved one, or a buffer with no
	-- path at all (a diff, a scratch buffer), is only visible from here.
	if M.lines <= 0 or not (a.modified or (a.virtual and not a.path)) then
		return nil
	end
	local total = vim.api.nvim_buf_line_count(buf)
	local line = math.min(math.max(a.line or 1, 1), total)
	local from = math.max(1, line - M.lines)
	local to = math.min(total, line + M.lines)
	if to < from then
		return nil
	end
	return {
		start_line = from,
		end_line = to,
		lines = vim.api.nvim_buf_get_lines(buf, from - 1, to, false),
	}
end

---Capture the anchor. With visual=true it uses the current visual selection
---(reading getpos("v")/(".") live rather than relying on '< '>).
---@param visual boolean|nil
---@return table anchor
function M.capture(visual)
	local buf = vim.api.nvim_get_current_buf()
	if vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= "" then
		M.remember_look() -- an anchor comes from a real file window
	end
	local cursor = vim.api.nvim_win_get_cursor(0)
	local name = vim.api.nvim_buf_get_name(buf)
	-- A plugin buffer (`codediff://…`, `fugitive://…`) is not a path: feeding it
	-- through fnamemodify turns it into a plausible-looking file that never
	-- existed, so it travels as a name only.
	local scheme = name:match("^(%a[%w+.-]*)://")
	local path = scheme == nil and name ~= "" and vim.fn.fnamemodify(name, ":p") or nil
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
	if scheme then
		a.virtual = scheme
	elseif path then
		-- `snapshot` = the relative path inside the extracted tree, so a jump can
		-- find the same file in the project instead of the throwaway copy.
		a.snapshot = extracted(path)
	end
	-- Project identity: a path relative to this tab's cwd can read `../other/x`
	-- and says nothing about which repository/branch the file belongs to.
	local root = repo_root(a.cwd)
	if root then
		a.root = root
		a.branch = branch_of(root)
		local abs = path and vim.fn.resolve(vim.fn.fnamemodify(vim.fn.expand(path), ":p")) or nil
		if abs and inside(abs, root) then
			a.rel = abs:sub(#root + 2)
		end
	end
	if visual then
		local s, e = vim.fn.getpos("v"), vim.fn.getpos(".")
		local sl, el = math.min(s[2], e[2]), math.max(s[2], e[2])
		if sl > 0 and el > 0 then
			local lines = vim.api.nvim_buf_get_lines(buf, sl - 1, el, false)
			local clip = M.clip_selection(lines, sl)
			a.visual = {
				start_line = sl,
				end_line = el,
				lines = clip.lines,
				clipped = clip.clipped or nil,
			}
			a.line = sl
		end
	end
	a.diagnostics = M.diagnostics(buf, a.line)
	a.context = M.snippet(a)
	return a
end

---Cut an oversized selection down to `M.max_selection` lines / `M.max_selection_bytes`.
---The agent still learns the range, so a clipped paste is not a lie.
---@param lines string[]
---@param start_line integer
---@return { lines: string[], clipped?: boolean }
function M.clip_selection(lines, start_line)
	local out, bytes = {}, 0
	for _, line in ipairs(lines) do
		local more = #out + 1 <= M.max_selection and bytes + #line + 1 <= M.max_selection_bytes
		if not more then
			return { lines = out, clipped = true }
		end
		out[#out + 1] = line
		bytes = bytes + #line + 1
	end
	return { lines = out }
end

---The anchor without the bulk: the source and diagnostics it inlined are for the
---question, not for the journal (a task keeps the coordinate it can jump to).
---@param a table|nil
---@return table|nil
function M.lean(a)
	if type(a) ~= "table" then
		return a
	end
	local out = vim.deepcopy(a)
	out.context, out.diagnostics = nil, nil
	if type(out.visual) == "table" then
		out.visual.lines = nil
	end
	return out
end

---One-line description of the anchor, for the floating prompt title.
---@param a table
---@return string
function M.describe(a)
	local bits = {
		a.path and ("%s:%d"):format(a.path, a.line)
			or (a.virtual and (a.bufname or (a.virtual .. "://")))
			or "<no filename>",
	}
	if a.branch then
		table.insert(bits, a.branch)
	end
	if a.snapshot then
		table.insert(bits, "diff snapshot")
	end
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

---A window that could show a file rather than the sidebar: a plain editing window
---(no special buffer, no float).
---@param win integer
---@return boolean
local function plain(win)
	local buf = vim.api.nvim_win_get_buf(win)
	return vim.bo[buf].buftype == "" and vim.api.nvim_win_get_config(win).relative == ""
end

local LOOK = { "number", "relativenumber", "signcolumn", "foldcolumn", "wrap", "list", "cursorline", "winbar" }

---How an editing window looks. A panel overrides `number`, `signcolumn`,
---`winbar` … window-locally, and a tab opened from it copies those overrides —
---so remember the look while a real editing window is still around.
local look

---Remember the look of an editing window (call before a panel takes the window).
---@param win integer|nil
---@return table|nil
function M.remember_look(win)
	win = win and vim.api.nvim_win_is_valid(win) and win or vim.api.nvim_get_current_win()
	local rec = {}
	for _, name in ipairs(LOOK) do
		local ok, value = pcall(vim.api.nvim_get_option_value, name, { win = win })
		if not ok then
			return nil
		end
		rec[name] = value
	end
	look = rec
	return rec
end

---The look a file wants: the nearest editing window's, else the remembered one,
---else whatever the option means globally.
---@param win integer
---@return table<string, any>
local function editor_look(win)
	local cur = vim.api.nvim_get_current_win()
	for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
		for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
			if w ~= win and w ~= cur and plain(w) then
				local buf = vim.api.nvim_win_get_buf(w)
				if vim.api.nvim_buf_get_name(buf) ~= "" then
					local rec = {}
					for _, name in ipairs(LOOK) do
						local ok, value = pcall(vim.api.nvim_get_option_value, name, { win = w })
						if not ok then
							return look or {}
						end
						rec[name] = value
					end
					return rec
				end
			end
		end
	end
	return look or {}
end

---A tab opened from a panel inherits the panel's look — no numbers, no sign
---column, its own winbar. Give it a file's look instead.
---@param win integer
local function dress(win)
	local opts = editor_look(win)
	for name, value in pairs(opts) do
		pcall(vim.api.nvim_set_option_value, name, value, { win = win })
	end
	pcall(vim.api.nvim_set_option_value, "winfixwidth", false, { win = win })
end

---Open a file in a tab of its own — another project belongs in its own tab, not
---in the window of the one on screen. The tab takes the anchor's working
---directory, so project-scoped tools keep working there.
---@param cwd string|nil
local function new_tab(cwd)
	vim.cmd("tabnew")
	dress(vim.api.nvim_get_current_win())
	if cwd and cwd ~= "" and vim.fn.isdirectory(cwd) == 1 then
		pcall(vim.cmd, "tcd " .. vim.fn.fnameescape(cwd))
	end
end

---The window a jump should land in: the current one when it is a plain editing
---window, another one in this tab when not, and a tab of its own when this tab is
---all sidebar. Never the dashboard/panel/quickfix/terminal the jump came from —
---a panel must keep its own content.
---@return integer win
local function editing_window()
	local win = vim.api.nvim_get_current_win()
	if plain(win) then
		return win
	end
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if plain(w) then
			return w
		end
	end
	vim.cmd("tabnew")
	local fresh = vim.api.nvim_get_current_win()
	dress(fresh)
	return fresh
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
			local win = editing_window()
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
	if a and a.virtual then
		return false, ("this anchor lives in a plugin buffer (%s://), which has no file to open"):format(a.virtual)
	end
	local ok, err = M.jump_to(a)
	if ok then
		return true, nil
	end
	local file = anchor_file(a)
	-- A diff snapshot is a copy of the project at that revision. The copy is the
	-- right thing to *read*, but the file the user means is in the project.
	if a and a.snapshot then
		local real = vim.fs.joinpath(project_root(), a.snapshot)
		if vim.fn.filereadable(real) == 1 then
			file = vim.fn.fnamemodify(real, ":p")
		else
			return false, ("this anchor is a diff snapshot of %s, and the project has no such file"):format(a.snapshot)
		end
	end
	if not file then
		return false, err
	end
	if vim.fn.filereadable(file) == 0 then
		return false, (err and (err .. " — ") or "") .. "the file no longer exists: " .. a.path
	end
	-- `:edit` acts on the current window: put the cursor in a window that may show
	-- a file first, or the fallback would replace the sidebar with the code.
	local win = editing_window()
	if not inside(file, project_root()) then
		new_tab(a.cwd)
		win = vim.api.nvim_get_current_win()
	end
	vim.api.nvim_set_current_win(win)
	vim.cmd.edit(vim.fn.fnameescape(file))
	local line = math.max(1, a.line or 1)
	vim.api.nvim_win_set_cursor(0, { math.min(line, vim.api.nvim_buf_line_count(0)), math.max(0, (a.col or 1) - 1) })
	vim.cmd("normal! zz")
	return true, nil
end

return M
