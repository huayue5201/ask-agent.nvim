-- lua/ask_agent/map.lua
---@brief Floating map: draw cells from the active layout adapter's real split layout; pressing a cell's letter sends to
---the agent in that pane.
--
-- Only used when a layout adapter reports geometry and at least two candidates can be located on it (see
--lua/ask_agent/layouts/init.lua); otherwise the caller falls back to vim.ui.select.
-- Interaction: each cell shows "icon + letter" (a, b, c... in candidate order); press the letter to pick directly;
-- h/j/k/l move to the adjacent cell in that direction; a click on a cell also works; q or <Esc> cancels.
-- The canvas is a read-only static image: no cursor (Cursor is mapped to the background color), no footer help text.
-- Labels are centered in the area still visible after floating panes cover part of their cell; when too narrow, only the letter remains.
local api = vim.api
local M = {}

-- Extmark namespace for the map buffer (backgrounds/highlights rely on it)
local NS = api.nvim_create_namespace("ai_map")

--- Colors: reuse the host's terminal palette when it exposes one (the map then matches the statusline/winbar),
---otherwise fall back to plain float colors so the plugin needs no dependency.
local function palette()
	local ok, p = pcall(function()
		return require("feat.terminal.highlights").palette()
	end)
	if ok and type(p) == "table" and p.chip_bg then
		return p
	end
	local function hl(name, field)
		local ok, got = pcall(api.nvim_get_hl, 0, { name = name, link = false })
		return ok and type(got) == "table" and got[field] or nil
	end
	return {
		fg = hl("NormalFloat", "fg"),
		green = hl("DiagnosticOk", "fg"),
		dim = hl("Comment", "fg"),
		bar_strip = hl("NormalFloat", "bg"),
		chip_bg = hl("Normal", "bg"),
		chip_fg = hl("Normal", "fg"),
	}
end

local function define_hl()
	local p = palette()
	local blend
	local ok, h = pcall(require, "feat.terminal.highlights")
	if ok and type(h.blend) == "function" then
		blend = function(a, b, ratio)
			return h.blend(a, b, ratio)
		end
	else
		-- no host palette: mix two #rrggbb colors ourselves (ratio = weight of b)
		blend = function(a, b, ratio)
			if type(a) ~= "string" or type(b) ~= "string" or #a ~= 7 or #b ~= 7 then
				return a
			end
			local ar, ag, ab = tonumber(a:sub(2, 3), 16), tonumber(a:sub(4, 5), 16), tonumber(a:sub(6, 7), 16)
			local br, bg, bb = tonumber(b:sub(2, 3), 16), tonumber(b:sub(4, 5), 16), tonumber(b:sub(6, 7), 16)
			ratio = ratio or 0.5
			local function mix(x, y)
				return math.floor(x * (1 - ratio) + y * ratio + 0.5)
			end
			return ("#%02x%02x%02x"):format(mix(ar, br), mix(ag, bg), mix(ab, bb))
		end
	end
	api.nvim_set_hl(0, "AiMapBg", { bg = p.bar_strip, fg = p.dim })
	api.nvim_set_hl(0, "AiMapPane", { bg = p.chip_bg, fg = p.dim })
	api.nvim_set_hl(0, "AiMapAgent", { bg = blend(p.chip_bg, p.green, 0.10), fg = p.green })
	api.nvim_set_hl(0, "AiMapSel", { bg = blend(p.chip_bg, p.green, 0.34), fg = p.green, bold = true })
	-- Floating panes (panes floated out of the tiled layer) are slightly brighter so the overlap hierarchy is visible
	api.nvim_set_hl(0, "AiMapFloat", { bg = blend(p.chip_bg, p.fg, 0.12), fg = p.dim })
	api.nvim_set_hl(
		0,
		"AiMapFloatSel",
		{ bg = blend(blend(p.chip_bg, p.fg, 0.12), p.green, 0.34), fg = p.green, bold = true }
	)
end

-- Icons use the agent's own brand color: set fg only, the background still comes from the cell group
-- (extmark hl_group accepts an array; the latter is layered on top of the former)
local icon_groups = {}
local function icon_group(color)
	if type(color) ~= "string" or color == "" then
		return nil
	end
	local name = "AiMapIcon" .. color:gsub("[^%w]", "")
	if not icon_groups[name] then
		api.nvim_set_hl(0, name, { fg = color, default = true })
		icon_groups[name] = true
	end
	return name
end

--- Combine a base group and an overlay group into an hl_group extmark can use
local function hl(base, extra)
	if extra then
		return { base, extra }
	end
	return base
end

----------------------------------------------------------------------
-- Canvas: one cell per display column; wide characters take two cells (the second has ch = "" as a continuation)
----------------------------------------------------------------------

local function grid_new(W, H)
	local g = {}
	for y = 1, H do
		g[y] = {}
		for x = 1, W do
			g[y][x] = { ch = " ", group = "AiMapBg" }
		end
	end
	return g
end

local function fill(g, y0, y1, x0, x1, group)
	for y = y0, y1 do
		for x = x0, x1 do
			g[y][x] = { ch = " ", group = group }
		end
	end
end

local function chars(str)
	local out = {}
	for i = 1, vim.fn.strchars(str) do
		out[i] = vim.fn.strcharpart(str, i - 1, 1)
	end
	return out
end

local function text(g, y, x0, x1, str, group)
	local col = x0
	for _, ch in ipairs(chars(str)) do
		local w = vim.fn.strdisplaywidth(ch)
		if col + w - 1 > x1 then
			break
		end
		g[y][col] = { ch = ch, group = group }
		for k = 1, w - 1 do
			g[y][col + k] = { ch = "", group = group }
		end
		col = col + w
	end
end

--- A highlight group may be a string or an array (overlay); compare adjacent segments by content rather than reference
local function group_key(grp)
	if type(grp) == "table" then
		return table.concat(grp, ",")
	end
	return grp or "AiMapBg"
end

--- Flatten the canvas into lines + per-line "byte range → highlight group" segments
local function rows_of(g, W, H)
	local lines, segs = {}, {}
	for y = 1, H do
		local parts, row_segs = {}, {}
		local byte, run_group, run_key, run_start = 0, nil, nil, 0
		for x = 1, W do
			local cell = g[y][x] or { ch = " ", group = "AiMapBg" }
			local ch, grp = cell.ch or " ", cell.group or "AiMapBg"
			local key = group_key(grp)
			if key ~= run_key then
				if run_group then
					table.insert(row_segs, { run_start, byte, run_group })
				end
				run_group, run_key, run_start = grp, key, byte
			end
			table.insert(parts, ch)
			byte = byte + #ch
		end
		if run_group then
			table.insert(row_segs, { run_start, byte, run_group })
		end
		lines[y] = table.concat(parts)
		segs[y] = row_segs
	end
	return lines, segs
end

----------------------------------------------------------------------
-- Layout → canvas
----------------------------------------------------------------------

-- Candidates → keys: a, b, c... (falls back to numeric indices beyond 26)
local ALPHABET = "abcdefghijklmnopqrstuvwxyz"
-- h/j/k/l are reserved for directional movement: with more than 7 candidates the 8th candidate's letter would be h
-- and collide with "move left", so skip those four when assigning letters. Beyond 22 candidates, use numbers.
local RESERVED = { h = true, j = true, k = true, l = true }
local LETTERS = {}
for i = 1, #ALPHABET do
	local ch = ALPHABET:sub(i, i)
	if not RESERVED[ch] then
		LETTERS[#LETTERS + 1] = ch
	end
end

local function cells_of(rect, W, H)
	local x = math.floor(rect[1] * W + 0.5) + 1
	local y = math.floor(rect[2] * H + 0.5) + 1
	local w = math.max(1, math.floor(rect[3] * W + 0.5))
	local h = math.max(1, math.floor(rect[4] * H + 0.5))
	-- No gaps: adjacent blocks touch directly, keeping the map compact (previously 1 cell was reserved left/right/top/bottom for separator gaps)
	local x1 = math.min(x + w - 1, W)
	local y1 = math.min(y + h - 1, H)
	return x, math.min(y, H), math.max(x1, x), math.max(y1, y)
end

--- Put only a letter in the cell; panes without a candidate stay empty and express layout through background color and seams
local function pane_label(item)
	if not item then
		return ""
	end
	return item.letter or tostring(item.index)
end

--- Center a piece of text in a cell (place nothing if it does not fit)

--- Find a contiguous run inside the cells that remain visible after floating panes cover them, and place the label there; returns y, start, stop.
--- Start from the center of the visible bbox; when a floating pane covers the center, move to the visible run closest to it.
---@param t table geometry entry
---@param owner table<integer, table<integer, table>> current owner of each cell (later floating panes overwrite earlier ones)
---@param need integer required contiguous display width
---@return integer? y, integer? x, integer? stop
local function place_label(t, owner, need)
	local minx, maxx, miny, maxy = math.huge, -1, math.huge, -1
	for y = t.y0, t.y1 do
		for x = t.x0, t.x1 do
			if owner[y] and owner[y][x] == t.pane then
				if x < minx then
					minx = x
				end
				if x > maxx then
					maxx = x
				end
				if y < miny then
					miny = y
				end
				if y > maxy then
					maxy = y
				end
			end
		end
	end
	if maxx < minx or maxy < miny then
		return nil
	end
	local cx, cy = (minx + maxx) / 2, (miny + maxy) / 2
	local best, best_score
	for y = miny, maxy do
		local start
		for x = minx, maxx + 1 do
			local vis = x <= maxx and owner[y] and owner[y][x] == t.pane
			if vis then
				start = start or x
			elseif start then
				local len = x - start
				if len >= need then
					local at = start + math.floor((len - need) / 2)
					-- Pick by straight-line distance from "label center → visible-area center": uncovered cells land exactly at the center;
					-- when a floating pane covers the center, shift up/down a row rather than lose horizontal centering.
					local dx = at + (need - 1) / 2 - cx
					local dy = y - cy
					local score = dx * dx + dy * dy
					if not best_score or score < best_score then
						best, best_score = { y, at, start + len - 1 }, score
					end
				end
				start = nil
			end
		end
	end
	if not best then
		return nil
	end
	return best[1], best[2], best[3]
end

--- Convert adapter leaf geometry into character cells (1-based, bottom-left inclusive), marking those "too small for a label"
---@param panes table[]
---@param by_pane table<string, table>
---@param W integer
---@param H integer
---@return table[] geom  { { pane, item, x0, y0, x1, y1 } }
local function geometry(panes, by_pane, W, H)
	local out = {}
	for _, pane in ipairs(panes) do
		local item = by_pane[pane.id]
		local x0, y0, x1, y1 = cells_of(pane.rect, W, H)
		table.insert(out, { pane = pane, item = item, x0 = x0, y0 = y0, x1 = x1, y1 = y1 })
	end
	return out
end

--- Draw one frame. The whole area is cells, with no footer — content is fixed and does not jump with candidate count.
local function paint(panes, by_pane, W, H, sel)
	local geom = geometry(panes, by_pane, W, H)
	local g = grid_new(W, H)
	local hit, owner = {}, {}
	for _, t in ipairs(geom) do
		local float = t.pane.kind == "floating"
		local group
		if t.item then
			if sel == t.item then
				group = float and "AiMapFloatSel" or "AiMapSel"
			else
				group = "AiMapAgent"
			end
		else
			group = float and "AiMapFloat" or "AiMapPane"
		end
		fill(g, t.y0, t.y1, t.x0, t.x1, group)
		for y = t.y0, t.y1 do
			hit[y] = hit[y] or {}
			owner[y] = owner[y] or {}
			for x = t.x0, t.x1 do
				hit[y][x] = t.item
				owner[y][x] = t.pane
			end
		end
	end

	-- Labels are placed in a second pass: floating panes cover the center of the pane underneath, so writing them in the first pass
	-- would make covered labels disappear (the visible part would have no label). So only search cells that still have their
	-- own background color, and center the label within that visible area.
	for _, t in ipairs(geom) do
		local letter = pane_label(t.item)
		if letter ~= "" then
			local float = t.pane.kind == "floating"
			local group
			if t.item then
				if sel == t.item then
					group = float and "AiMapFloatSel" or "AiMapSel"
				else
					group = "AiMapAgent"
				end
			else
				group = float and "AiMapFloat" or "AiMapPane"
			end
			-- Treat icon + space + letter as one unit when centering; if a floating pane cuts the cell too narrow, keep only the letter
			local icon = t.item and t.item.icon or nil
			if icon == "" then
				icon = nil
			end
			local iw = icon and vim.fn.strdisplaywidth(icon) or 0
			local lw = vim.fn.strdisplaywidth(letter)
			local y, x, stop
			if icon then
				y, x, stop = place_label(t, owner, iw + 1 + lw)
			end
			if not y then
				icon, iw = nil, 0
				y, x, stop = place_label(t, owner, lw)
			end
			if y then
				if icon then
					text(g, y, x, stop, icon, hl(group, icon_group(t.item.icon_hl)))
					text(g, y, x + iw + 1, stop, letter, hl(group, "Bold"))
				else
					text(g, y, x, stop, letter, hl(group, "Bold"))
				end
			end
		end
	end

	local rows, segs = rows_of(g, W, H)
	return { rows, segs, hit }
end

--- Directional selection: the nearest pane from `from` in direction `dir` (h/j/k/l)
---@param panes table[]
---@param from table|nil
---@param dir string
---@return table|nil
local function covers(outer, inner)
	return outer[1] <= inner[1] + 1e-9
		and outer[2] <= inner[2] + 1e-9
		and outer[1] + outer[3] >= inner[1] + inner[3] - 1e-9
		and outer[2] + outer[4] >= inner[2] + inner[4] - 1e-9
end

local function neighbour(panes, from, dir)
	if not from or not from.rect then
		return nil
	end
	local horizontal = dir == "h" or dir == "l"
	local r0 = from.rect
	local fcx, fcy = r0[1] + r0[3] / 2, r0[2] + r0[4] / 2

	-- A floating pane sits on top of some pane: all four of its edges are inside that pane, so directional neighbour search always
	-- comes up empty (that is why you cannot get back). So first find "who contains me", and let all four directions move to it.
	local holder, holder_area
	for _, pane in ipairs(panes) do
		local r = pane.rect
		if r and pane.id ~= from.id and covers(r, r0) then
			local area = r[3] * r[4]
			if not holder_area or area < holder_area then
				holder, holder_area = pane, area
			end
		end
	end
	if holder then
		return holder
	end

	-- Pick neighbours by "edge-to-edge gap" rather than center distance: center distance makes a distant floating pane look closer
	-- than an adjacent split (small floating pane, offset center); only gap 0 is truly adjacent.
	local best, best_score
	for _, pane in ipairs(panes) do
		local r = pane.rect
		if r and pane.id ~= from.id then
			local cx, cy = r[1] + r[3] / 2, r[2] + r[4] / 2
			local gap
			if dir == "h" then
				gap = r0[1] - (r[1] + r[3])
			elseif dir == "l" then
				gap = r[1] - (r0[1] + r0[3])
			elseif dir == "j" then
				gap = r[2] - (r0[2] + r0[4])
			else
				gap = r0[2] - (r[2] + r[4])
			end
			if gap >= -1e-6 then
				local cross = horizontal and math.abs(cy - fcy) or math.abs(cx - fcx)
				local score = gap * 4 + cross
				if not best_score or score < best_score then
					best, best_score = pane, score
				end
			end
		end
	end
	if best then
		return best
	end

	-- A full-height pane (the whole left column) has no "adjacent" block when moving up/down, so only then fall back to center-point
	-- search: cross the boundary into the upper/lower half of the other column. Floating panes contained by itself do not participate (not neighbours).
	for _, pane in ipairs(panes) do
		local r = pane.rect
		if r and pane.id ~= from.id and not covers(r0, r) then
			local cx, cy = r[1] + r[3] / 2, r[2] + r[4] / 2
			local along = horizontal and (cx - fcx) or (cy - fcy)
			local forward = ((dir == "l" or dir == "j") and along > 1e-6)
				or ((dir == "h" or dir == "k") and along < -1e-6)
			if forward then
				local cross = horizontal and math.abs(cy - fcy) or math.abs(cx - fcx)
				local score = cross * 4 + math.abs(along)
				if not best_score or score < best_score then
					best, best_score = pane, score
				end
			end
		end
	end
	return best
end

----------------------------------------------------------------------
-- Picker
----------------------------------------------------------------------

--- Open the map picker
---@param opts { panes: table[], items: table[], cursor_pane?: string, on_choose: fun(item: table|nil), on_switch?: fun() }
function M.select(opts)
	local panes = opts.panes or {}
	local items = opts.items or {}
	define_hl()

	local by_pane = {}
	for i, it in ipairs(items) do
		it.letter = LETTERS[i]
		if it.letter == "" then
			it.letter = nil
		end
		if it.pane_id then
			by_pane[it.pane_id] = it
		end
	end

	-- Only panes in this window are visible; other candidates can still be reached by letter
	local located = {}
	for _, it in ipairs(items) do
		if it.pane_id and by_pane[it.pane_id] == it then
			for _, p in ipairs(panes) do
				if p.pane_id == it.pane_id then
					table.insert(located, it)
					break
				end
			end
		end
	end

	-- Only one letter is needed, so make a small hint map: about a quarter screen; anything larger is empty
	local W = math.min(math.max(math.floor(vim.o.columns * 0.25 + 0.5), 12), 32)
	local H = math.min(math.max(math.floor(vim.o.lines * 0.20 + 0.5), 3), 9)

	-- The message area (above cmdheight) has a higher zindex than floating windows, so leftover messages can cover the map,
	-- showing up as a vertical line or garbled characters in the middle. Clear the message area before opening the window.
	pcall(vim.cmd, "silent! messages clear")
	pcall(api.nvim_echo, { { "" } }, false, {})

	local buf = api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	-- Plugins that draw indent guides put a vertical line on the cursor line (mini.indentscope's symbol is │);
	-- it would cover the map and show up as an extra vertical line in every pane.
	vim.b[buf].miniindentscope_disable = true

	local sel = nil
	for _, it in ipairs(located) do
		if it.pane_id == opts.cursor_pane then
			sel = it
		end
	end
	sel = sel or located[1]

	local hit
	local win
	-- Center the floating window: use the UI's real size, not vim.o.lines. vim.o.lines includes the bottom cmdline row,
	-- and the editor area changes as the message area/cmdline height changes, so calculating from o.lines drifts.
	local function editor_size()
		local ui = api.nvim_list_uis()[1]
		if not ui then
			return vim.o.columns, vim.o.lines
		end
		return ui.width, ui.height - (vim.o.cmdheight or 1)
	end

	-- Re-place the window on every repaint: when cmdline/message area size changes, the floating window should not be pushed around.
	local function place()
		if not (win and api.nvim_win_is_valid(win)) then
			return
		end
		local cols, rows = editor_size()
		pcall(api.nvim_win_set_config, win, {
			relative = "editor",
			row = math.max(0, math.floor((rows - H) / 2)),
			col = math.max(0, math.floor((cols - W) / 2)),
		})
	end

	local function repaint()
		local painted = paint(panes, by_pane, W, H, sel)
		local lines, segs, h = painted[1], painted[2], painted[3]
		hit = h
		vim.bo[buf].modifiable = true
		api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false
		place()
		api.nvim_buf_clear_namespace(buf, NS, 0, -1)
		for y, list in ipairs(segs) do
			for _, seg in ipairs(list) do
				if seg[2] > seg[1] then
					pcall(api.nvim_buf_set_extmark, buf, NS, y - 1, seg[1], {
						end_col = seg[2],
						hl_group = seg[3],
						priority = 10,
					})
				end
			end
		end
	end

	repaint()

	local cols0, rows0 = editor_size()
	win = api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.max(0, math.floor((rows0 - H) / 2)),
		col = math.max(0, math.floor((cols0 - W) / 2)),
		width = W,
		height = H,
		style = "minimal",
		-- No border: the whole block is the map itself, so cells touch the screen directly (title depends on a border, so remove that too)
		border = "none",
		-- Keep autocmds such as WinEnter/BufWinEnter away from this window: some plugins inject
		-- number columns/indent guides/status columns, which would render as vertical lines or digits in the float.
		noautocmd = true,
	})
	-- Nothing in the floating window: number/fold/sign/status columns may be injected by other plugins (statuscol.nvim sets
	-- statuscolumn for every new window) and would render as a vertical line or extra digits in the float.
	vim.wo[win].wrap = false
	vim.wo[win].cursorline = false
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].foldcolumn = "0"
	vim.wo[win].foldenable = false
	vim.wo[win].statuscolumn = ""
	vim.wo[win].colorcolumn = ""
	vim.wo[win].list = false
	vim.wo[win].spell = false
	vim.wo[win].winbar = ""
	-- Cursor mapped to background = invisible cursor: this is a read-only canvas, and a cursor block would only look dirty.
	vim.wo[win].winhighlight = "Normal:AiMapBg,Cursor:AiMapBg,CursorIM:AiMapBg"
	-- The cursor moves between cells; if 'scrolloff' kicks in the floating window scrolls by itself (canvas width == window height,
	-- so scrolling has no empty lines and visually the whole map shifts up). Turn it off.
	vim.wo[win].scrolloff = 0
	vim.wo[win].sidescrolloff = 0
	api.nvim_set_current_win(win)

	local finished = false
	local function close(item, switch)
		if finished then
			return
		end
		finished = true
		if api.nvim_win_is_valid(win) then
			api.nvim_win_close(win, true)
		end
		if api.nvim_buf_is_valid(buf) then
			pcall(api.nvim_buf_delete, buf, { force = true })
		end
		if switch then
			if opts.on_switch then
				opts.on_switch()
			end
			return
		end
		if opts.on_choose then
			opts.on_choose(item)
		end
	end

	local function move_to(item)
		-- Land in the middle of the cell rather than the "first cell": cursor position stays stable when moving back and forth
		local cells = {}
		for y, list in pairs(hit or {}) do
			for x, it in pairs(list) do
				if it == item then
					cells[#cells + 1] = { y, x }
				end
			end
		end
		if #cells == 0 then
			return false
		end
		table.sort(cells, function(a, b)
			if a[1] ~= b[1] then
				return a[1] < b[1]
			end
			return a[2] < b[2]
		end)
		local mid = cells[math.floor((#cells + 1) / 2)]
		pcall(api.nvim_win_set_cursor, win, { mid[1], mid[2] - 1 })
		return true
	end

	if sel then
		move_to(sel)
	end

	-- Current cell (the cursor is invisible, so this is expressed by highlight only): not counted when the cell has no candidate
	api.nvim_create_autocmd("VimResized", {
		group = api.nvim_create_augroup("AiMapPlace", { clear = true }),
		callback = place,
	})

	local function at_current()
		local row = api.nvim_win_get_cursor(win)[1]
		local col = api.nvim_win_get_cursor(win)[2] + 1
		local list = hit and hit[row]
		return list and (list[col] or list[1]) or nil
	end

	local function current_pane()
		local row = api.nvim_win_get_cursor(win)[1]
		local col = api.nvim_win_get_cursor(win)[2] + 1
		local list = hit and hit[row]
		local item = list and (list[col] or list[1]) or nil
		if not item then
			return nil
		end
		for _, p in ipairs(panes) do
			if p.pane_id == item.pane_id then
				return p
			end
		end
		return nil
	end

	-- Walk by screen: step outward cell by cell from the cursor cell; the first other pane encountered is the on-screen neighbour.
	-- This lets a floating pane and the pane underneath cross back and forth (when computing "who is next to me" from rects, a floating
	-- pane's edges are all inside the pane it covers, so the two cannot see each other and you cannot get back).
	---@return table|nil item, integer|nil y, integer|nil x first cell crossed into the other pane
	local function walk(dir)
		local dy = (dir == "j" and 1) or (dir == "k" and -1) or 0
		local dx = (dir == "l" and 1) or (dir == "h" and -1) or 0
		local cur = api.nvim_win_get_cursor(win)
		local y, x = cur[1], cur[2] + 1
		local from = hit and hit[y] and hit[y][x]
		while true do
			y, x = y + dy, x + dx
			if y < 1 or y > H or x < 1 or x > W then
				return nil
			end
			local item = hit and hit[y] and hit[y][x]
			if item and item ~= from then
				return item, y, x
			end
		end
	end

	local function map(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
	end

	-- Mouse: click a cell to select it directly (no need to move the cursor first)
	map("<LeftMouse>", function()
		local ok, pos = pcall(vim.fn.getmousepos)
		if not (ok and pos and pos.winid == win) then
			return
		end
		local list = hit and hit[pos.line]
		local item = list and (list[pos.wincol] or list[pos.column] or list[1])
		if item then
			close(item)
		end
	end, "Click a cell")
	map("<CR>", function()
		local item = at_current()
		if item then
			close(item)
		end
	end, "Select current cell")
	map("<Tab>", function()
		close(nil, true)
	end, "Switch to list picker")
	map("q", function()
		close(nil)
	end, "Cancel")
	map("<Esc>", function()
		close(nil)
	end, "Cancel")

	-- h/j/k/l: move the highlight to an adjacent cell (does not send; <CR> confirms)
	for _, dir in ipairs({ "h", "j", "k", "l" }) do
		map(dir, function()
			-- Walk by screen first; when that leaves the canvas (full-height pane moving up/down), fall back to rect neighbours
			local item, y, x = walk(dir)
			if not item then
				local pane = neighbour(panes, current_pane(), dir)
				item = pane and by_pane[pane.id]
			end
			if item then
				sel = item
				if y then
					pcall(api.nvim_win_set_cursor, win, { y, x - 1 })
				else
					move_to(item)
				end
				repaint()
			end
		end, "Move " .. dir)
	end
	for _, it in ipairs(items) do
		if it.letter then
			local letter = it.letter
			for _, lhs in ipairs({ letter, letter:upper() }) do
				map(lhs, function()
					close(it)
				end, "Choose " .. letter)
			end
		end
	end
	for i = 1, 9 do
		map(tostring(i), function()
			for _, it in ipairs(items) do
				if it.index == i then
					close(it)
					return
				end
			end
		end, "Jump to candidate " .. i)
	end

	-- Read-only canvas: does not follow the cursor, no CursorMoved repaint, content stays stable
	local group = api.nvim_create_augroup("AiMapSel" .. buf, { clear = true })
	api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = buf,
		callback = function()
			pcall(api.nvim_del_augroup_by_id, group)
		end,
	})
end

return M
