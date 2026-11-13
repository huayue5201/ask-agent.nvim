-- lua/ask_agent/message.lua
---@brief Render "question + anchor" into the final text that gets sent.
--
-- Rendering lives on the nvim side (rather than in each agent adapter) so every backend receives
-- the same message format; switching agents does not require rewriting the assembly logic. The format
-- matches the pi extension's early renderAsk, so older pi extensions can still parse the legacy
-- {prompt, anchor} payload.

local M = {}

---@param anchor table
---@param prompt string
---@return string
function M.render(anchor, prompt)
	local a = anchor or {}
	local question = vim.trim(prompt or "")
	local out = { question ~= "" and question or "(empty question)" }

	local where = {
		a.path and ("%s:%d"):format(a.path, a.line or 1)
			or (a.virtual and (a.bufname or "<no filename>"))
			or "<no filename>",
		a.snapshot and ("a diff snapshot of %s"):format(a.snapshot) or nil,
		a.tab and ("tab %d"):format(a.tab) or nil,
		a.modified and "unsaved" or nil,
	}
	local bits = {}
	for _, w in ipairs(where) do
		if w then
			table.insert(bits, w)
		end
	end

	table.insert(out, "")
	-- Project overview digest (optional): placed before the anchor so the model sees "what project this is"
	-- before "where this question lives"
	if a.digest and a.digest ~= "" then
		table.insert(out, "<project-overview>")
		for line in (a.digest .. "\n"):gmatch("(.-)\n") do
			table.insert(out, line)
		end
		table.insert(out, "</project-overview>")
		table.insert(out, "")
	end
	table.insert(out, ("<nvim-context %s>"):format(table.concat(bits, " · ")))
	if a.cwd then
		table.insert(out, "cwd: " .. a.cwd)
	end
	if a.snapshot then
		table.insert(
			out,
			"note: that path is a copy extracted for a diff, not the file in the project — read it, don't edit it"
		)
	end
	if a.visual then
		table.insert(out, ("selection %d-%d:"):format(a.visual.start_line, a.visual.end_line))
		table.insert(out, "```" .. (a.filetype or ""))
		for _, line in ipairs(a.visual.lines or {}) do
			table.insert(out, line)
		end
		table.insert(out, "```")
	end
	table.insert(out, "</nvim-context>")
	return table.concat(out, "\n")
end

---The question as it was typed: `M.render` output without the context block.
---The anchor/overview is metadata about *where* the question was asked; the
---answer float and a copied task should show the words, not the envelope.
---@param text string|nil
---@return string
function M.question(text)
	local out = {}
	for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
		if line:match("^<nvim%-context") or line:match("^<project%-overview>") then
			break
		end
		out[#out + 1] = line
	end
	while #out > 0 and vim.trim(out[#out]) == "" do
		table.remove(out)
	end
	return table.concat(out, "\n")
end

return M
