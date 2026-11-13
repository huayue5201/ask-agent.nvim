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

print("MAP OK")
