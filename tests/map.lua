-- Headless: nvim --headless --clean -l tests/map.lua
vim.opt.runtimepath:prepend(".")

local map = require("ask_agent.map")

-- Several Rex windows are stacked into one canvas, each in its own band.
local W, H = map.size()
local windows = {
	{ panes = { { id = "a", rect = { 0, 0, 0.5, 1 }, kind = "tiled" } } },
	{
		panes = {
			{ id = "b", rect = { 0, 0, 0.5, 1 }, kind = "tiled" },
			{ id = "c", rect = { 0.5, 0, 0.5, 1 }, kind = "tiled" },
		},
	},
}
local panes = map.stack(windows)
assert(#panes == 3, "all panes survive stacking")
assert(
	panes[1].rect[2] == 0 and panes[2].rect[2] > 0.2 and panes[2].rect[2] < 0.8,
	"second window is in the lower band"
)
assert(panes[1].rect[4] <= 1 and panes[2].rect[4] <= 1, "bands stay inside the canvas")

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
	"every window's candidate is drawn"
)

vim.api.nvim_buf_delete(buf, { force = true })

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
