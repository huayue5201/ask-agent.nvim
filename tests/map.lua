-- Headless: nvim --headless --clean -l tests/map.lua
vim.opt.runtimepath:prepend(".")

local map = require("ask_agent.map")

-- The map only draws the current window's panes (agents in other Rex windows
-- have no position here; they are chosen from the list).
local W, H = map.size()
local panes = {
	{ id = "a", rect = { 0, 0, 0.5, 1 }, kind = "tiled" },
	{ id = "b", rect = { 0.5, 0, 0.5, 0.5 }, kind = "tiled" },
	{ id = "c", rect = { 0.5, 0.5, 0.5, 0.5 }, kind = "tiled" },
}

local items = {}
for i, p in ipairs(panes) do
	items[i] = { pane_id = p.id, target = { label = p.id, cwd = "/tmp/" .. p.id }, name = p.id, icon = "x" }
end

map.select({ panes = panes, items = items })

local buf = vim.api.nvim_get_current_buf()
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(#lines == H, "map fills its height")
local text = table.concat(lines, "\n")
assert(
	text:find("a", 1, true) and text:find("b", 1, true) and text:find("c", 1, true),
	"every pane of the current window is drawn"
)

-- Palette: nvim_get_hl returns integers, so derive #rrggbb before blending.
-- Panes and agent cells must still differ even when Normal and NormalFloat share a bg.
local function bg(name)
	local h = vim.api.nvim_get_hl(0, { name = name, link = false })
	return h.bg
end
assert(bg("AiMapBg") and bg("AiMapPane"), "map backgrounds are set")
assert(bg("AiMapPane") ~= bg("AiMapBg"), "panes stand out from the canvas")
assert(bg("AiMapAgent") ~= bg("AiMapPane"), "agent cells stand out from the pane")
assert(bg("AiMapSel") ~= bg("AiMapAgent"), "the selected agent stands out")

-- Only the selected cell is asked for a name; every other cell keeps its letter, so a
-- long name cannot push the map's shape around.
items[1].name = "apibot"
map.select({ panes = panes, items = items })
local named = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
assert(named:find("apibot", 1, true), "the selected cell shows the agent's name")
assert(named:find("b", 1, true) and named:find("c", 1, true), "unselected cells keep their letters")
vim.api.nvim_buf_delete(0, { force = true })

-- A name that cannot fit is shortened rather than dropped or spilling over the pane.
items[1].name = ("api-worker-"):rep(8)
map.select({ panes = panes, items = items })
local cut = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
assert(cut:find("…", 1, true), "a name too long for its pane is shortened with an ellipsis")
assert(not cut:find("api-worker-api-worker-api-worker", 1, true), "the shortened name stays inside the pane")
vim.api.nvim_buf_delete(0, { force = true })
items[1].name = "a"

-- A narrow pane shortens the name into the cells it has; below three columns the
-- letter is kept instead, so a tiny pane never renders a useless single glyph.
local narrow = {
	{ id = "n1", rect = { 0, 0, 0.2, 1 }, kind = "tiled" },
	{ id = "n2", rect = { 0.2, 0, 0.8, 1 }, kind = "tiled" },
}
local narrow_items = {
	{ pane_id = "n1", target = { label = "n1" }, name = "api-worker", icon = "" },
	{ pane_id = "n2", target = { label = "n2" }, name = "n2", icon = "" },
}
map.select({ panes = narrow, items = narrow_items })
local narrowed = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
assert(narrowed:find("…", 1, true), "a narrow pane shortens the name to its own width")
assert(not narrowed:find("api-worker", 1, true), "the shortened name stops at the pane edge")
assert(narrowed:find("b", 1, true), "the other pane keeps its letter")
vim.api.nvim_buf_delete(0, { force = true })

-- A state badge follows the letter, and a running turn animates it.
items[1].status_glyph = "W"
items[1].status_state = "working"
map.select({ panes = panes, items = items })
local badge = vim.api.nvim_buf_get_lines(0, 0, -1, false)
assert(table.concat(badge, "\n"):find("W", 1, true), "the agent state is drawn next to its letter")
vim.api.nvim_buf_delete(0, { force = true })

items[1].status_glyph = "x"
items[1].status_frames = { "1", "2" }
map.select({ panes = panes, items = items })
local frame1 = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
assert(frame1:find("1", 1, true), "the running badge starts on frame 1")
vim.api.nvim_buf_delete(0, { force = true })

vim.api.nvim_buf_delete(buf, { force = true })

-- Canvas size and label behaviour are configurable (ask.setup({ map = {...} })).
map.setup({ width = 0.5, height = 0.5, min_width = 4, max_width = 10, min_height = 2, max_height = 4 })
local cw, ch = map.size()
assert(cw == 10 and ch == 4, "width/height ratios are clamped by min/max")
map.setup({ width = 0.25, height = 0.20, min_width = 12, max_width = 12, min_height = 3, max_height = 3 })
local cw2 = map.size()
assert(cw2 == 12, "min_width clamps the canvas")

map.setup({ name = false })
items[1].name = "apibot"
map.select({ panes = panes, items = items })
local letters = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
assert(not letters:find("apibot", 1, true), "name = false keeps the map to letters")
vim.api.nvim_buf_delete(0, { force = true })

-- name_min decides when a shortened name is still worth drawing
map.setup({ name = true, name_min = 4 })
items[1].name = ("api-worker-"):rep(8)
map.select({ panes = panes, items = items })
local strict = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
assert(strict:find("…", 1, true), "a shortened name still draws at four columns")
vim.api.nvim_buf_delete(0, { force = true })
map.setup({
	name = true,
	name_min = 3,
	name_over_badge = true,
	width = 0.25,
	height = 0.20,
	min_width = 12,
	max_width = 32,
	min_height = 3,
	max_height = 9,
})
items[1].name = "a"

-- Zoom only changes what rex draws: the map still needs the full split tree,
-- otherwise an agent in a zoomed-away pane becomes unplaceable.
local rex = require("ask_agent.layouts.rex")
local win = {
	zoomed_block_id = "z",
	layers = {
		{
			kind = "tiled",
			layout = {
				split = {
					direction = "row",
					ratio = 0.5,
					before = { block_id = "z", rect = { 0, 0, 0.5, 1 } },
					after = { block_id = "other", rect = { 0.5, 0, 0.5, 1 } },
				},
			},
		},
	},
}
local zp = rex.visible_panes(win)
assert(#zp == 2, "a zoomed window keeps its full split tree")
assert(zp[1].id == "z" and zp[2].id == "other", "both panes remain placeable")
assert(zp[1].rect[3] == 0.5 and zp[2].rect[1] == 0.5, "pane geometry is the real split, not the zoom")

-- Every window of the session shares one canvas: digits switch the drawn window, and a letter
-- keeps pointing at the same agent on every tab (it is assigned once, over the global order).
map.setup({ width = 0.5, height = 0.5, min_width = 16, max_width = 32, min_height = 4, max_height = 9 })
local side_by_side = {
	{ id = "t1", rect = { 0, 0, 0.5, 1 }, kind = "tiled" },
	{ id = "t2", rect = { 0.5, 0, 0.5, 1 }, kind = "tiled" },
}
local stacked = {
	{ id = "t3", rect = { 0, 0, 1, 0.5 }, kind = "tiled" },
	{ id = "t4", rect = { 0, 0.5, 1, 0.5 }, kind = "tiled" },
}
local tab_items = {
	{ pane_id = "t1", target = { label = "one" }, name = "one", icon = "" },
	{ pane_id = "t2", target = { label = "two" }, name = "two", icon = "" },
	{ pane_id = "t3", target = { label = "three" }, name = "three", icon = "" },
}
map.select({
	windows = {
		{ id = "w1", panes = side_by_side },
		{ id = "w2", panes = stacked, label = "logs" },
	},
	active = "w1",
	items = tab_items,
})
local function map_lines()
	return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end
-- The selected cell shows its name, the others their letters: `one` + `b` on tab 1.
local tab1 = map_lines()
assert(tab1:find("one", 1, true) and tab1:find("b", 1, true), "the tab nvim lives in draws its own agents")
assert(not tab1:find("three", 1, true), "an agent on another tab is not drawn")
assert(tab1:find("2 logs", 1, true), "the strip names tabs that rex has a name for")
vim.api.nvim_feedkeys("2", "x", false)
local tab2 = map_lines()
assert(tab2:find("three", 1, true), "a digit switches the drawn window")
assert(not tab2:find("b", 1, true) and not tab2:find("one", 1, true), "the previous tab is no longer drawn")
assert(vim.api.nvim_win_is_valid(0) and vim.api.nvim_win_get_config(0).relative ~= "", "a digit never picks an agent")
vim.api.nvim_feedkeys("1", "x", false)
local tab1_again = map_lines()
assert(tab1_again:find("one", 1, true) and not tab1_again:find("three", 1, true), "switching back restores the first tab")
vim.api.nvim_buf_delete(0, { force = true })

-- A tab without agents is still a complete map of that window's layout, and opening the map
-- stays on the tab nvim lives in instead of jumping to a tab that has an agent.
local empty_layout = {
	{ id = "e1", rect = { 0, 0, 0.5, 1 }, kind = "tiled" },
	{ id = "e2", rect = { 0.5, 0, 0.5, 0.5 }, kind = "tiled" },
	{ id = "e3", rect = { 0.5, 0.5, 0.5, 0.5 }, kind = "tiled" },
}
map.setup({ width = 0.5, height = 0.5, min_width = 24, max_width = 24, min_height = 6, max_height = 6 })
map.select({
	windows = {
		{ id = "w1", panes = empty_layout },
		{ id = "w2", panes = { { id = "solo", rect = { 0, 0, 1, 1 }, kind = "tiled" } } },
	},
	active = "w1",
	items = { { pane_id = "solo", target = { label = "solo" }, name = "solo", icon = "" } },
})
local empty = map_lines()
assert(not empty:find("solo", 1, true), "an agent in another window is not drawn on my tab")
assert(empty:find("1 2", 1, true), "the strip still lists every window")
assert(vim.api.nvim_win_get_cursor(0)[1] > 1, "the cursor lands inside the panes even when the tab has no agent")
vim.api.nvim_feedkeys("2", "x", false)
assert(map_lines():find("solo", 1, true), "a digit reaches the tab that has the agent")
vim.api.nvim_feedkeys("1", "x", false)
assert(not map_lines():find("solo", 1, true), "switching back returns to the empty tab")
vim.api.nvim_buf_delete(0, { force = true })

-- A canvas too small for its layout reports what it cannot show instead of dropping agents silently
map.setup({ min_width = 12, max_width = 12, min_height = 2, max_height = 2, fit = false })
local dense, dense_items = {}, {}
for i = 1, 30 do
	local id = "d" .. i
	dense[i] = { id = id, rect = { (i - 1) / 30, 0, 1 / 30, 1 }, kind = "tiled" }
	dense_items[i] = { pane_id = id, target = { label = id }, name = id, icon = "" }
end
map.select({ panes = dense, items = dense_items })
assert(
	map_lines():find("clipped", 1, true),
	"a canvas too small for its layout says how many agents it cannot show"
)
vim.api.nvim_buf_delete(0, { force = true })

-- Agents with no pane (a desktop app) go on a rail under the canvas instead of vanishing:
-- the map is still the map, and a session whose only agent has no pane still opens it.
map.setup({ width = 0.5, height = 0.5, min_width = 24, max_width = 40, min_height = 5, max_height = 8 })
local rail_items = {
	{ pane_id = "r1", target = { label = "term" }, name = "term", icon = "" },
	{ pane_id = nil, target = { label = "deck" }, name = "deck", icon = "◇" },
}
local rail_choice
map.select({
	panes = { { id = "r1", rect = { 0, 0, 1, 1 }, kind = "tiled" } },
	items = rail_items,
	rail = { rail_items[2] },
	on_choose = function(item)
		rail_choice = item
	end,
})
local rl = vim.api.nvim_buf_get_lines(0, 0, -1, false)
assert(rl[#rl]:find("deck", 1, true), "an agent without a pane is drawn on the rail")
for i = 1, #rl - 1 do
	assert(not rl[i]:find("deck", 1, true), "the rail is its own row, below the canvas")
end
assert(rl[#rl]:find("b", 1, true), "the rail keeps the letter the list gave it")
vim.api.nvim_feedkeys("b", "x", false)
assert(rail_choice and rail_choice.target.label == "deck", "the rail letter chooses the agent")
vim.api.nvim_buf_delete(0, { force = true })

-- A map where no agent has a pane is all rail: still a map, still pickable, no silent fallback.
local only_rail = { { pane_id = nil, target = { label = "deck" }, name = "deck", icon = "◇" } }
local only_choice
map.select({
	panes = { { id = "empty1", rect = { 0, 0, 1, 1 }, kind = "tiled" } },
	items = only_rail,
	rail = only_rail,
	on_choose = function(item)
		only_choice = item
	end,
})
local orl = vim.api.nvim_buf_get_lines(0, 0, -1, false)
assert(orl[#orl]:find("deck", 1, true), "a rail-only map still draws its agent")
vim.api.nvim_feedkeys("\r", "x", false)
assert(only_choice and only_choice.target.label == "deck", "the rail is selectable by default")
vim.api.nvim_buf_delete(0, { force = true })

print("MAP OK")
