-- lua/ask_agent/prompts.lua
---@brief Reusable question templates, stored as JSON and rendered against an anchor.
--
-- A prompt is text with placeholders that the plugin fills in at ask time:
--
--   "Explain {{selection}} in {{file}}:{{line}}"  →  the selection is inline, the
--   location travels in the anchor like any other question
--
-- Two layers, project wins over global for the same name:
--   global   stdpath("cache")/ask-agent/prompts.json
--   project  <root>/.ask-agent/prompts.json   (root = git root, else nearest
--            ancestor containing .ask-agent; shareable with the repository)
--
-- Rendering never guesses: a missing value becomes an empty string, and an unknown
-- placeholder is left verbatim so a typo is visible instead of silently disappearing.

local M = {}

---Global prompt file (tests override).
M.global_path = nil
---File name looked for under the project root (tests override).
M.project_file = ".ask-agent/prompts.json"

---@return string
local function global_file()
	return M.global_path or (vim.fn.stdpath("cache") .. "/ask-agent/prompts.json")
end

---Nearest ancestor that looks like a project. `git.root` is authoritative when git
---is available; `.ask-agent` also makes a non-git directory a project.
---@param cwd string|nil
---@return string|nil
function M.root(cwd)
	cwd = vim.fn.fnamemodify(cwd or vim.fn.getcwd(), ":p"):gsub("/+$", "")
	local ok, git = pcall(require, "ask_agent.git")
	if ok and git.available() then
		local root = git.root(cwd)
		if root then
			return root
		end
	end
	local dir = cwd
	while dir and dir ~= "" do
		if vim.fn.isdirectory(dir .. "/.ask-agent") == 1 then
			return dir
		end
		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir then
			break
		end
		dir = parent
	end
	return nil
end

---@param cwd string|nil
---@return string|nil
function M.project_path(cwd)
	local root = M.root(cwd)
	if not root then
		return nil
	end
	return root .. "/" .. M.project_file
end

---@param file string
---@return table[] list of { name, text, desc } (empty on any problem)
local function read_file(file)
	if vim.uv.fs_stat(file) == nil then
		return {}
	end
	local ok, lines = pcall(vim.fn.readfile, file)
	if not ok or not lines then
		return {}
	end
	local decoded_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
	if not decoded_ok or type(decoded) ~= "table" then
		return {}
	end
	local list = type(decoded.prompts) == "table" and decoded.prompts or decoded
	local out = {}
	for _, item in ipairs(list) do
		if type(item) == "table" and type(item.name) == "string" and type(item.text) == "string" then
			out[#out + 1] = { name = item.name, text = item.text, desc = item.desc }
		end
	end
	return out
end

---@param file string
---@param list table[]
---@return boolean ok, string|nil err
local function write_file(file, list)
	local encoded_ok, encoded = pcall(vim.json.encode, { version = 1, prompts = list })
	if not encoded_ok then
		return false, "could not encode prompts"
	end
	local dir = vim.fn.fnamemodify(file, ":h")
	if vim.fn.mkdir(dir, "p") == 0 and vim.fn.isdirectory(dir) == 0 then
		return false, "could not create " .. dir
	end
	local ok, err = pcall(vim.fn.writefile, { encoded }, file)
	if not ok then
		return false, tostring(err)
	end
	return true
end

---Every prompt visible from `cwd`: global first, project overrides by name.
---Each entry carries `source` = "global" | "project" and `file`.
---@param cwd string|nil
---@return table[]
function M.all(cwd)
	local merged, index = {}, {}
	local function add(item, source, file)
		local existing = index[item.name]
		if existing then
			existing.text = item.text
			existing.desc = item.desc
			existing.source = source
			existing.file = file
			return
		end
		local entry = { name = item.name, text = item.text, desc = item.desc, source = source, file = file }
		merged[#merged + 1] = entry
		index[item.name] = entry
	end
	local global = global_file()
	for _, item in ipairs(read_file(global)) do
		add(item, "global", global)
	end
	local project = M.project_path(cwd)
	if project then
		for _, item in ipairs(read_file(project)) do
			add(item, "project", project)
		end
	end
	return merged
end

---Find a prompt by exact name, then by case-insensitive name.
---@param name string
---@param cwd string|nil
---@return table|nil
function M.get(name, cwd)
	if type(name) ~= "string" or name == "" then
		return nil
	end
	local list = M.all(cwd)
	for _, item in ipairs(list) do
		if item.name == name then
			return item
		end
	end
	local needle = name:lower()
	for _, item in ipairs(list) do
		if item.name:lower() == needle then
			return item
		end
	end
	return nil
end

---Create or update a prompt. `project = true` writes it into the repository
---(`.ask-agent/prompts.json`), so it can be committed with the code.
---@param name string
---@param text string
---@param opts { desc?: string, project?: boolean, cwd?: string }|nil
---@return boolean ok, string|nil err
function M.save(name, text, opts)
	opts = opts or {}
	if type(name) ~= "string" or vim.trim(name) == "" then
		return false, "a prompt needs a name"
	end
	if type(text) ~= "string" or vim.trim(text) == "" then
		return false, "a prompt needs text"
	end
	local file = global_file()
	if opts.project then
		file = M.project_path(opts.cwd)
		if not file then
			return false, "no project root found (create .ask-agent/ or use a git repository)"
		end
	end
	local list = read_file(file)
	local found
	for _, item in ipairs(list) do
		if item.name == name then
			item.text = text
			item.desc = opts.desc
			found = item
			break
		end
	end
	if not found then
		list[#list + 1] = { name = name, text = text, desc = opts.desc }
	end
	return write_file(file, list)
end

---Delete a prompt from the file that defines it (project copy wins, like `all`).
---@param name string
---@param opts { cwd?: string }|nil
---@return boolean ok, string|nil err
function M.remove(name, opts)
	local item = M.get(name, opts and opts.cwd)
	if not item then
		return false, "no prompt named " .. tostring(name)
	end
	local list = {}
	for _, candidate in ipairs(read_file(item.file)) do
		if candidate.name ~= item.name then
			list[#list + 1] = candidate
		end
	end
	return write_file(item.file, list)
end

---Fill placeholders from an anchor (see context.capture). Unknown placeholders are
---left untouched; a known placeholder with no value becomes "".
---@param text string
---@param anchor table|nil
---@return string
function M.render(text, anchor)
	anchor = anchor or {}
	local visual = anchor.visual or {}
	local selection = visual.lines and table.concat(visual.lines, "\n") or ""
	local diagnostics = ""
	if anchor.buf and vim.api.nvim_buf_is_valid(anchor.buf) then
		local ok, hits = pcall(vim.diagnostic.get, anchor.buf)
		if ok then
			diagnostics = tostring(#hits)
		end
	end
	local values = {
		file = anchor.path or "",
		line = tostring(anchor.line or ""),
		col = tostring(anchor.col or ""),
		filetype = anchor.filetype or "",
		cwd = anchor.cwd or vim.fn.getcwd(),
		selection = selection,
		diagnostics = diagnostics,
		modified = anchor.modified and "unsaved" or "",
		cursor = "", -- the anchor already carries it; kept for symmetry
	}
	return (
		text:gsub("{{%s*([%w_]+)%s*}}", function(key)
			local value = values[key]
			if value == nil then
				return "{{" .. key .. "}}"
			end
			return value
		end)
	)
end

return M
