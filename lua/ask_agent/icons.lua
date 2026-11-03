-- lua/ask_agent/icons.lua
---@brief One icon per agent: pickers/notifications show at a glance who answers.
--
-- A single backend may host different agents (e.g. several picked up from tmux),
-- so icons resolve from "instance id" first and backend id second. Glyphs live in
-- common-use or Nerd Font ranges; build them with nr2char to keep the source and
-- any sync process from mangling private-use codepoints -- but this is a
-- hand-edited table, so literals are fine as long as they render.
--
-- To switch to a Nerd Font glyph, write the entry as vim.fn.nr2char(0xF0C0B) or
-- override it with setup({ icons = { pi = "π" } }).
local M = {}

local api = vim.api

---Unknown agents get a robot: nf-md-robot (U+F06A9)
M.fallback = vim.fn.nr2char(0xF06A9)

local glyphs = {
	-- pi's mark is π
	pi = "π",
	-- Claude Code's spinner asterisk, also its product mark
	claude = vim.fn.nr2char(0x273B),
	-- any other CLI agent running in a terminal: nf-fa-terminal
	generic = vim.fn.nr2char(0xF120),
}

---Primary icon colour (brand colour). Unlisted keys return nil, and the caller
---inherits the foreground colour of its cell.
local colors = {
	-- Anthropic orange, Claude Code's brand colour
	claude = "#d97757",
}

---Per-instance accents: the same instance (same registration id + ts) always gets
---the same colour, so "that row in the list" and "that cell on the map" match up.
---Hues are deliberately spread out so neighbours stay distinguishable.
local accents = {
	"#7aa2f7", -- blue
	"#e0af68", -- amber
	"#9ece6a", -- green
	"#bb9af7", -- purple
	"#f7768e", -- red
	"#7dcfff", -- cyan
}

---Normalise an id to a key in glyphs ("claude-code" / "claude_code" -> "claude")
---@param key string|nil
---@return string|nil
local function base_key(key)
	if type(key) ~= "string" or key == "" then
		return nil
	end
	if glyphs[key] then
		return key
	end
	local base = key:lower():gsub("[^%w]+", "-"):match("^[%a]+")
	return (base and glyphs[base]) and base or nil
end

---@param key string|nil
---@return string|nil
local function lookup(key)
	local k = base_key(key)
	return k and glyphs[k] or nil
end

---Icon for an agent; falls back when unknown (never returns nil).
---@param key string|nil instance id or backend id
---@return string
function M.get(key)
	return lookup(key) or M.fallback
end

---Returns nil when nothing has been configured (for "should I use a default icon"
---decisions).
---@param key string|nil
---@return string|nil
function M.find(key)
	return lookup(key)
end

---Primary colour of an agent's icon; nil when unset (the caller falls back).
---@param key string|nil
---@return string|nil
function M.color(key)
	local k = base_key(key)
	return k and colors[k] or nil
end

local accent_cache = {}

---Per-instance colour: prefer key "<id>:<ts>", the result is stable across calls.
---@param key string|nil
---@return string|nil
function M.accent(key)
	if type(key) ~= "string" or key == "" then
		return nil
	end
	local hit = accent_cache[key]
	if hit then
		return hit
	end
	-- simple string hash (base 31): only needs to be stable, not uniform
	local h = 0
	for i = 1, #key do
		h = (h * 31 + key:byte(i)) % 2147483647
	end
	local color = accents[(h % #accents) + 1]
	accent_cache[key] = color
	return color
end

---Highlight group name for an instance colour (already defined, ready to use).
---@param key string|nil
---@return string|nil
function M.accent_hl(key)
	local color = M.accent(key)
	if not color then
		return nil
	end
	local name = "AiInst" .. color:gsub("[^%w]+", "")
	api.nvim_set_hl(0, name, { fg = color, default = true })
	return name
end

---@param map table<string, string>|nil glyph overrides
---@param palette table<string, string>|nil colour overrides (hex)
function M.setup(map, palette)
	for k, v in pairs(map or {}) do
		if type(v) == "string" and v ~= "" then
			glyphs[k] = v
		end
	end
	for k, v in pairs(palette or {}) do
		if type(v) == "string" and v ~= "" then
			colors[k] = v
		end
	end
end

---@return table<string, string>
function M.all()
	return vim.deepcopy(glyphs)
end

---@return table<string, string>
function M.all_colors()
	return vim.deepcopy(colors)
end

return M
