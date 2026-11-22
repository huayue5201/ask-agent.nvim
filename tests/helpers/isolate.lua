-- Shared test helper: silence every backend a test does not own.
--
-- The picker is unified (a desktop app has no pane of its own, so `aq` has to offer every
-- backend at once). On a developer machine that means a running StudyDeck, pi sessions and
-- the like can join a test's candidate list. A test that asserts on counts must opt out.
--
--   local isolate = dofile(vim.fn.getcwd() .. "/tests/helpers/isolate.lua")
--   isolate.only({ fake = true })   -- keep only the backend(s) this test registered
local M = {}

-- Originals are remembered so a test can hand a backend back (sections later in the same file
-- often need a different cast of agents). Kept on _G because tests `dofile` this file, which
-- re-executes it and would otherwise forget.
local saved = rawget(_G, "__ask_agent_test_isolation") or {}
rawset(_G, "__ask_agent_test_isolation", saved)

---@param keep table<string, boolean>|nil backend ids to leave alone
function M.only(keep)
	keep = keep or {}
	local backends = require("ask_agent.backends")
	for _, mod in ipairs(backends.all()) do
		if keep[mod.id] then
			if saved[mod.id] then
				mod.available = saved[mod.id].available
				mod.targets = saved[mod.id].targets
				saved[mod.id] = nil
			end
		elseif not saved[mod.id] then
			saved[mod.id] = { available = mod.available, targets = mod.targets }
			mod.available = function()
				return false, "disabled by the test"
			end
			mod.targets = function()
				return {}
			end
		end
	end
end

return M
