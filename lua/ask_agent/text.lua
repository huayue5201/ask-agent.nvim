-- lua/ask_agent/text.lua
---@brief Cutting text down to a display width — one implementation for the list, the
---map, notifications and names. Counting happens in display cells (a CJK character is
---two), so a cut never lands in the middle of a character or of a wide glyph.

local M = {}

---Split a string into characters (grapheme-ish: one codepoint each).
---@param str string
---@return string[]
function M.chars(str)
	local out = {}
	for i = 1, vim.fn.strchars(str) do
		out[i] = vim.fn.strcharpart(str, i - 1, 1)
	end
	return out
end

---Shorten `str` to at most `width` display cells, ending in an ellipsis.
---
---`opts.keep_tail` leaves `str` untouched when it already fits (the default
---behaviour); `opts.min` sets how many cells a shortened result must use before it
---is worth showing at all (below that, nil is returned so the caller can fall back
---to something else, e.g. a single letter in the map).
---@param str string
---@param width integer
---@param opts? { min?: integer }
---@return string|nil text nil when nothing readable fits
function M.fit(str, width, opts)
	opts = opts or {}
	if type(str) ~= "string" then
		return nil
	end
	if width <= 0 then
		return nil
	end
	if vim.fn.strdisplaywidth(str) <= width then
		return str
	end
	-- one character plus the ellipsis is the minimum that reads as a word
	local min = math.max(opts.min or 3, 3)
	if width < min then
		return nil
	end
	local out, used = {}, 0
	for _, ch in ipairs(M.chars(str)) do
		local cw = vim.fn.strdisplaywidth(ch)
		if used + cw > width - 1 then
			break
		end
		used = used + cw
		out[#out + 1] = ch
	end
	if #out == 0 then
		return nil
	end
	return table.concat(out) .. "…"
end

return M
