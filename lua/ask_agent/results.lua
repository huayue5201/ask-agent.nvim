-- lua/ask_agent/results.lua
---@brief Answers coming back from an agent, and the float that shows a task's Q+A.
--
-- Off by default (`setup({ results = true })`) because it makes the question
-- ledger store what the agent said, and that is a different promise than
-- "questions only". Once on, there are two delivery paths and both end in
-- `history.set_answer(task_id, text)`:
--
--   1. pi, live: the extension quotes the `task_id` it was sent with back over the
--      nvim bridge (`action=result`), so the answer arrives the moment the run
--      ends. This is the good path.
--   2. anything else (Claude hooks, scripts), by mail: a JSON file dropped into
--      `stdpath("cache")/ask-agent/results/`
--      `{"task_id": "...", "text": "..."}` or, without an id,
--      `{"cwd": "/repo", "text": "..."}` to attach to the newest task of the agent
--      working there. Files are imported on demand (dashboard open, `o`) and when
--      an agent reports done; a broken file is left for inspection, not deleted.
--
-- Nothing here reads a transcript: an agent that cannot hand the answer back
-- simply has no answer recorded, and `o` says so.

local M = {}

---Master switch, set by `setup({ results = true })`.
M.enabled = false

local notify = require("ask_agent.notify")

local function history()
	return require("ask_agent.history")
end

local function state()
	return require("ask_agent.state")
end

---@return string
function M.dir()
	return vim.fn.stdpath("cache") .. "/ask-agent/results"
end

---Keep one answer: history keeps the text, state keeps the "has an answer" flag
---(the dashboard reads the flag on every render and the text only on `o`).
---@param req table  { task_id?, text, ts?, cwd? }
---@return boolean ok, string|nil err
function M.record(req)
	if not M.enabled then
		return false, "results are disabled (setup({ results = true }))"
	end
	local text = req and req.text
	if type(text) ~= "string" or text == "" then
		return false, "no answer text"
	end
	local task_id = req.task_id
	if type(task_id) ~= "string" or task_id == "" then
		task_id = M.match_cwd(req.cwd)
	end
	if not task_id then
		return false, "no task to attach this answer to"
	end
	local rec = history().set_answer(task_id, text, req.ts)
	if not rec then
		return false, ("history has no task %s"):format(task_id)
	end
	-- state persists the "has an answer" flag; the dashboard picks it up on its
	-- next render (the write is debounced, like every other state change).
	state().attach_result(task_id, req.ts)
	return true
end

---Newest task of the agent working in `cwd` (mail without a task id).
---@param cwd string|nil
---@return string|nil task_id
function M.match_cwd(cwd)
	if type(cwd) ~= "string" or cwd == "" then
		return nil
	end
	local ok, recs = pcall(state().all)
	if not ok then
		return nil
	end
	local best, best_ts
	for _, rec in ipairs(recs or {}) do
		local at = rec.target and rec.target.cwd
		local task = at == cwd and rec.tasks and rec.tasks[1]
		if task and task.task_id and task.ts and (not best_ts or task.ts > best_ts) then
			best, best_ts = task.task_id, task.ts
		end
	end
	return best
end

---Mail nobody could attach does not pile up forever: each Stop hook leaves one
---behind, so files older than a week are dropped (the task they belong to would
---be pruned by then anyway).
M.mail_ttl = 7 * 24 * 3600

---Import every mail file. Returns how many answers landed. Files that cannot be
---delivered stay on disk: they are the only copy of that answer.
---@return integer imported, integer failed
function M.import()
	if not M.enabled then
		return 0, 0
	end
	local dir = M.dir()
	if vim.fn.isdirectory(dir) == 0 then
		return 0, 0
	end
	local now = os.time()
	local imported, failed = 0, 0
	for name, kind in vim.fs.dir(dir) do
		local path = dir .. "/" .. name
		local stat = kind == "file" and vim.uv.fs_stat(path) or nil
		if stat and stat.mtime and now - stat.mtime.sec > M.mail_ttl then
			pcall(vim.fn.delete, path)
		elseif kind == "file" and name:sub(-5) == ".json" then
			local ok, data = pcall(function()
				return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
			end)
			if ok and type(data) == "table" then
				local ok2 = M.record(data)
				if ok2 then
					imported = imported + 1
					pcall(vim.fn.delete, path)
				else
					failed = failed + 1
				end
			else
				failed = failed + 1
			end
		end
	end
	return imported, failed
end

---Import pending mail whenever an agent reports done. pi's live path does not
---need it, but a hook that only knows how to write a file does.
---@param st table state module
function M.attach(st)
	if M._attached then
		return
	end
	M._attached = true
	st.on("done", function()
		vim.schedule(function()
			if M.enabled then
				M.import()
			end
		end)
	end)
end

---The task id and the record a dashboard node / state task points at.
---@param task table|string
---@return string|nil task_id, table|nil rec
function M.resolve(task)
	local task_id = type(task) == "string" and task or (type(task) == "table" and task.task_id) or nil
	if not task_id then
		return nil, nil
	end
	return task_id, history().get(task_id)
end

---Float with the question and the agent's answer, `q` closes, `y` yanks the answer.
---@param task table|string  a state task (needs task_id), or a task id
---@return boolean ok, string|nil err
function M.show(task)
	local task_id, rec = M.resolve(task)
	if not task_id then
		return false, "this task has no id (sent before results were enabled?)"
	end
	if not rec then
		return false, "the history entry for this task is gone"
	end
	local lines = {}
	local function add(s)
		for _, line in ipairs(vim.split(s or "", "\n", { plain = true })) do
			lines[#lines + 1] = line
		end
	end
	add(("question  %s  %s"):format(rec.backend or "?", os.date("%Y-%m-%d %H:%M", math.floor((rec.ts or 0) / 1000))))
	if rec.cwd then
		add("cwd       " .. rec.cwd)
	end
	add("")
	add(rec.text or "")
	add("")
	if rec.answer then
		add(("answer  %s"):format(os.date("%Y-%m-%d %H:%M", math.floor((rec.answer_ts or rec.ts or 0) / 1000))))
		add("")
		add(rec.answer)
	else
		add("(no answer recorded yet)")
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "markdown"
	pcall(vim.api.nvim_buf_set_name, buf, "ask-agent-answer://" .. task_id)
	local width = math.max(40, math.min(math.floor(vim.o.columns * 0.7), 110))
	local height = math.max(10, math.min(#lines, math.floor(vim.o.lines * 0.7)))
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " answer ",
		title_pos = "center",
	})
	local function close()
		if vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end
	vim.keymap.set("n", "q", close, { buffer = buf, silent = true, nowait = true, desc = "Close the answer" })
	vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true, nowait = true })
	vim.keymap.set("n", "y", function()
		if not rec.answer then
			notify.notify("[ask_agent] this task has no answer yet", vim.log.levels.INFO)
			return
		end
		vim.fn.setreg('"', rec.answer)
		notify.notify("[ask_agent] Answer copied", vim.log.levels.INFO)
	end, { buffer = buf, silent = true, desc = "Copy the answer" })
	return true
end

return M
