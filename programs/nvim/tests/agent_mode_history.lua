-- Run from the repository root:
-- nvim --headless -u NONE -i NONE -l programs/nvim/tests/agent_mode_history.lua
local root = vim.fn.getcwd() .. "/programs/nvim/lua/agent_mode/"
for _, name in ipairs({ "backend", "history", "identity", "project" }) do
	package.preload["config.agent_mode." .. name] = function()
		return dofile(root .. name .. ".lua")
	end
end
local History = require("config.agent_mode.history")
local mode = dofile(root .. "init.lua")
local internals, visited = {}, {}
local function inspect(fn)
	if visited[fn] then return end
	visited[fn] = true
	for index = 1, math.huge do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		internals[name] = value
		if type(value) == "function" then inspect(value) end
	end
end
for _, fn in pairs(mode) do
	if type(fn) == "function" then inspect(fn) end
end

local temporary = vim.fn.tempname()
local count = 0
local function test(name, fn)
	fn()
	count = count + 1
	print("ok " .. count .. " - " .. name)
end
local function same(actual, expected)
	assert(vim.deep_equal(actual, expected), vim.inspect(actual) .. " != " .. vim.inspect(expected))
end
local function history(name, options)
	return History.new(vim.tbl_extend("force", { path = temporary .. "/" .. name .. ".json" }, options or {}))
end

test("each character is on disk immediately and prefixes grow in place", function()
	local saved = history("keystrokes")
	local draft = "hello\n世界"
	for index = 1, vim.fn.strchars(draft) do
		local text = vim.fn.strcharpart(draft, 0, index)
		saved:record(text)
		-- A new reader must recover without a timer, flush, or clean shutdown.
		same(history("keystrokes"):items(), { text })
	end
	saved:close()
end)

test("deleting and branching preserve the fuller draft", function()
	local saved = history("branches")
	for _, text in ipairs({ "hello world", "hello", "hello there", "" }) do saved:record(text) end
	same(history("branches"):items(), { "hello world", "hello there" })
	saved:close()
end)

test("typing an existing prompt again deduplicates the finished draft", function()
	local saved = history("duplicates")
	saved:record_final("hello")
	saved:record_final("other")
	for _, text in ipairs({ "h", "he", "hel", "hell", "hello" }) do saved:record(text) end
	same(history("duplicates"):items(), { "other", "hello" })
	saved:close()
end)

test("history evicts oldest entries at its configured limit", function()
	local saved = history("bounded", { limit = 3 })
	for _, text in ipairs({ "one", "two", "three", "four", "five" }) do saved:record_final(text) end
	same(history("bounded"):items(), { "three", "four", "five" })
	saved:close()
end)

test("Up recovers rapid edits and Down restores the working draft", function()
	local state = assert(internals.state)
	state.opts = { sidebar_width = 24 }
	state.project = { launch_cwd = "/repo", worktrees = { { path = "/repo" } } }
	state.prompt_history = history("composer")
	state.prompt_history:record_final("older prompt")
	internals.create_ui()
	internals.open_new_chat()
	local composer = assert(state.composer)
	local function edit(text)
		vim.api.nvim_buf_set_lines(composer.buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
	end
	local function text()
		return table.concat(vim.api.nvim_buf_get_lines(composer.buf, 0, -1, false), "\n")
	end
	local function key(lhs, mapping_mode)
		local mapping = vim.api.nvim_buf_call(composer.buf, function()
			return vim.fn.maparg(lhs, mapping_mode or "i", false, true)
		end)
		assert(type(mapping.callback) == "function", lhs .. " must be mapped")
		mapping.callback()
	end
	-- No TextChanged event or event-loop turn between typing and losing text.
	edit("h")
	same(history("composer"):items(), { "older prompt", "h" })
	edit("hello\nworld")
	edit("")
	key("<Up>")
	same(text(), "hello\nworld")
	-- Delayed/duplicate UI events must not reset the history cursor.
	for _ = 1, 2 do
		vim.api.nvim_exec_autocmds("TextChangedI", { buffer = composer.buf })
	end
	key("<Up>")
	same(text(), "older prompt")
	key("<Up>")
	same(text(), "older prompt")
	key("<Down>")
	same(text(), "hello\nworld")
	key("<Down>")
	same(text(), "")
	same(history("composer"):items(), { "older prompt", "hello\nworld" })

	edit("working draft")
	key("<Up>", "n")
	same(text(), "hello\nworld")
	key("<Down>", "n")
	same(text(), "working draft")
	key("<Up>")
	edit("hello\nworld edited")
	same(history("composer"):items(), { "older prompt", "hello\nworld", "working draft", "hello\nworld edited" })
	key("<C-c>")
	same(text(), "")
	key("<Up>")
	same(text(), "hello\nworld edited")

	-- Reopening the composer with a freshly loaded history recovers the draft.
	internals.hide_composer()
	vim.api.nvim_win_set_buf(state.chat_win, state.placeholder_buf)
	vim.api.nvim_buf_delete(composer.buf, { force = true })
	vim.api.nvim_buf_delete(composer.background_buf, { force = true })
	state.composer = nil
	state.prompt_history:close()
	state.prompt_history = history("composer")
	internals.open_new_chat()
	composer = state.composer
	key("<Up>")
	same(text(), "hello\nworld edited")
	internals.hide_composer()
	vim.api.nvim_win_set_buf(state.chat_win, state.placeholder_buf)
	vim.api.nvim_buf_delete(composer.buf, { force = true })
	vim.api.nvim_buf_delete(composer.background_buf, { force = true })
	state.composer = nil
	state.prompt_history:close()
	mode.leave()
end)

vim.fn.delete(temporary, "rf")
print(string.format("Passed %d prompt history regression tests", count))
