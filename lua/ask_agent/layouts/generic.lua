-- lua/ask_agent/layouts/generic.lua
---@brief Layout adapter factories for multiplexers we do not ship a dedicated
---adapter for. `generic.tmux()` is a working example: it turns tmux panes into
---the same normalised rectangles the map picker expects, so any backend that
---stamps `target.layout = { pane = "%3" }` on its targets gets the map for free.
--
-- ```lua
-- require("ask_agent").register_layout(require("ask_agent.layouts.generic").tmux())
-- ```
local M = {}

local function run(cmd)
	local ok, res = pcall(function()
		return vim.system(cmd, { text = true }):wait(1500)
	end)
	if not ok or not res or res.code ~= 0 then
		return nil
	end
	return res.stdout
end

---@param opts table|nil  { tmux = <executable>, id = <adapter id> }
---@return table layout adapter
function M.tmux(opts)
	opts = opts or {}
	local bin = opts.tmux or "tmux"
	local adapter = {
		id = opts.id or "tmux",
		label = "tmux",
	}

	function adapter.available()
		if type(vim.env.TMUX) ~= "string" or vim.env.TMUX == "" then
			return false, "not inside tmux ($TMUX unset)"
		end
		if vim.fn.executable(bin) ~= 1 then
			return false, bin .. " not found"
		end
		return true
	end

	---@return table|nil window, table|nil data, string|nil err
	function adapter.window()
		local out = run({ bin, "display-message", "-p", "-F", "#{window_id}" })
		if not out then
			return nil, nil, "tmux display-message failed"
		end
		local window_id = out:gsub("%s+$", "")
		if window_id == "" then
			return nil, nil, "cannot read the tmux window"
		end
		local data = { window_id = window_id }
		return data, data
	end

	---@param window table|nil
	---@return table[]
	function adapter.panes(window)
		local window_id = window and window.window_id or nil
		local format = "#{pane_id}\t#{pane_left}\t#{pane_top}\t#{pane_width}\t#{pane_height}"
			.. "\t#{window_width}\t#{window_height}"
		local cmd = { bin, "list-panes", "-F", format }
		if window_id then
			table.insert(cmd, "-t")
			table.insert(cmd, window_id)
		end
		local out = run(cmd)
		if not out then
			return {}
		end
		local panes = {}
		for line in out:gmatch("[^\n]+") do
			local id, left, top, w, h, ww, wh = line:match("^(%S+)\t(%d+)\t(%d+)\t(%d+)\t(%d+)\t(%d+)\t(%d+)$")
			if id and tonumber(ww) > 0 and tonumber(wh) > 0 then
				panes[#panes + 1] = {
					id = id,
					kind = "tiled",
					rect = {
						tonumber(left) / tonumber(ww),
						tonumber(top) / tonumber(wh),
						tonumber(w) / tonumber(ww),
						tonumber(h) / tonumber(wh),
					},
				}
			end
		end
		return panes
	end

	---Which pane hosts an instance: backends stamp `target.layout.pane` (`%3`, …)
	---@param t table
	---@return string|nil
	function adapter.match(t)
		local loc = t and t.layout
		return type(loc) == "table" and loc.pane or nil
	end

	---The pane nvim runs in, so the map opens with the cursor already there.
	---@return string|nil
	function adapter.cursor()
		local out = run({ bin, "display-message", "-p", "-F", "#{pane_id}" })
		return out and out:gsub("%s+$", "") or nil
	end

	return adapter
end

return M
