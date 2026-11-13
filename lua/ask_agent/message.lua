-- lua/ask_agent/message.lua
---@brief Render "question + anchor" into the final text that gets sent.
--
-- Two ways out, one format:
--
--   * text-only backends (a TUI you paste into, an email file, tmux send-keys) get `M.render`:
--     question + block, exactly what a human would have typed.
--   * backends that understand the protocol (pi) get the question *and* the anchor as JSON, and
--     render the block themselves; the question stays clean so the agent's transcript, the history
--     ledger and the answer float all show the words rather than an envelope (see pi.lua).
--
-- The block format is shared with extensions/nvim-context.ts (`renderBlock`), which is why it
-- lives in one function here and one there, and nowhere else.

local M = {}

---Everything after the question: the project digest (what this is) and the anchor (where it is).
---Backends that carry a structured anchor render this themselves; every other backend gets
---`M.render`, which is the two concatenated.
---@param anchor table
---@return string
function M.block(anchor)
	local a = anchor or {}
	local out = {}

	-- Where the question lives. The repository-relative path is what an agent can
	-- use as-is (`git grep`, an editor, a compiler), so it wins over the cwd one.
	-- Built by appending, not in a pre-sized table: most of these are nil.
	local bits = {}
	local function add(bit)
		if bit then
			table.insert(bits, bit)
		end
	end
	if a.rel then
		add(("%s:%d"):format(a.rel, a.line or 1))
	elseif a.path then
		add(("%s:%d"):format(a.path, a.line or 1))
	elseif a.virtual then
		add(a.bufname or "<no filename>")
	else
		add("<no filename>")
	end
	if a.snapshot then
		add(("a diff snapshot of %s"):format(a.snapshot))
	end
	if a.branch then
		add(("branch %s"):format(a.branch))
	end
	if a.tab then
		add(("tab %d"):format(a.tab))
	end
	if a.modified then
		add("unsaved")
	end

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
	if a.root then
		table.insert(out, "root: " .. a.root)
	end
	if a.snapshot then
		table.insert(
			out,
			"note: that path is a copy extracted for a diff, not the file in the project — read it, don't edit it"
		)
	end
	if a.diagnostics then
		table.insert(out, "diagnostics:")
		for _, d in ipairs(a.diagnostics) do
			table.insert(
				out,
				("  %s:%d: %s: %s"):format(d.source or "lsp", d.line or 0, d.severity or "warn", d.message or "")
			)
		end
	end
	-- Inlined source: an unsaved buffer (disk has something else) or no path at all
	-- (a diff). A saved file needs no copy — the agent reads it.
	if a.context then
		table.insert(
			out,
			("context (lines %d-%d%s):"):format(
				a.context.start_line,
				a.context.end_line,
				a.context.clipped and ", clipped" or ""
			)
		)
		table.insert(out, "```" .. (a.filetype or ""))
		vim.list_extend(out, a.context.lines or {})
		table.insert(out, "```")
	end
	if a.visual then
		local clipped = a.visual.clipped and " (clipped)" or ""
		table.insert(out, ("selection %d-%d%s:"):format(a.visual.start_line, a.visual.end_line, clipped))
		table.insert(out, "```" .. (a.filetype or ""))
		vim.list_extend(out, a.visual.lines or {})
		table.insert(out, "```")
	end
	table.insert(out, "</nvim-context>")
	return table.concat(out, "\n")
end

---The whole message: the words, then what they are about.
---
---The digest is fetched here rather than at capture time because this runs at the moment of
---sending (a window that is opened and abandoned should not pay for a cold collect).
---@param anchor table
---@param prompt string
---@return string
function M.render(anchor, prompt)
	local a = anchor or {}
	local question = vim.trim(prompt or "")
	if a.digest == nil and a.root then
		a.digest = require("ask_agent.project").digest(a.root)
	end
	local out = { question ~= "" and question or "(empty question)" }
	table.insert(out, "")
	table.insert(out, M.block(a))
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
