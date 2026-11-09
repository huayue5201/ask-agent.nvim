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

return M
