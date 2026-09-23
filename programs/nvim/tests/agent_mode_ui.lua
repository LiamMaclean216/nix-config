-- Run from the repository root:
-- nvim --headless -u NONE -i NONE -l programs/nvim/tests/agent_mode_ui.lua
local root = vim.fn.getcwd() .. "/programs/nvim/lua/agent_mode/"
for _, name in ipairs({ "backend", "history", "identity", "project", "sidebar", "docker" }) do
	package.preload["config.agent_mode." .. name] = function()
		return dofile(root .. name .. ".lua")
	end
end
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
for _, fn in pairs(mode) do inspect(fn) end
local state = assert(internals.state)
state.backend = {
	start = function(_, callback) callback(nil) end,
	stop = function() end,
	list_threads = function(_, _, callback) callback(nil, {}) end,
}
local history_path = vim.fn.tempname()
mode.setup({ history_path = history_path, sidebar_width = 24 })
vim.wait(20, function() return false end)

vim.o.columns, vim.o.lines = 120, 40
vim.o.showtabline, vim.o.laststatus, vim.o.cmdheight = 2, 3, 1
vim.cmd("tabnew")
vim.cmd("vsplit")
vim.cmd("split")
local origin = vim.api.nvim_get_current_win()
local editor_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(editor_buf, 0, -1, false, { "unsaved editor text" })
local tabs = vim.api.nvim_list_tabpages()
local windows = vim.api.nvim_tabpage_list_wins(0)
local layout = vim.fn.winlayout()
local function window_sizes()
	return vim.tbl_map(function(win)
		return { vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win) }
	end, windows)
end
local sizes = window_sizes()
local function listed_buffers()
	return vim.tbl_filter(function(buf) return vim.bo[buf].buflisted end, vim.api.nvim_list_bufs())
end
local listed = listed_buffers()
local function assert_editor()
	assert(vim.deep_equal(tabs, vim.api.nvim_list_tabpages()), "Agent Mode must never create tabs")
	assert(vim.deep_equal(windows, vim.api.nvim_tabpage_list_wins(0)), "editor windows must survive unchanged")
	assert(vim.deep_equal(layout, vim.fn.winlayout()), "editor splits must survive unchanged")
	assert(vim.deep_equal(listed, listed_buffers()), "Agent Mode must never create listed buffers")
	assert(vim.api.nvim_get_current_win() == origin, "return to the original editor window")
	assert(vim.bo[editor_buf].modified, "preserve unsaved edits")
	assert(vim.api.nvim_buf_get_lines(editor_buf, 0, -1, false)[1] == "unsaved editor text")
	assert(vim.o.showtabline == 2 and vim.o.laststatus == 3 and vim.o.cmdheight == 1,
		"restore the user's editor chrome: " .. vim.inspect({ vim.o.showtabline, vim.o.laststatus, vim.o.cmdheight }))
end
local function assert_overlay()
	assert(vim.deep_equal(tabs, vim.api.nvim_list_tabpages()))
	assert(vim.deep_equal(listed, listed_buffers()))
	assert(vim.o.showtabline == 0 and vim.o.laststatus == 0 and vim.o.cmdheight == 0)
	local sidebar = vim.api.nvim_win_get_config(state.sidebar_win)
	local chat = vim.api.nvim_win_get_config(state.chat_win)
	assert(sidebar.relative == "editor" and chat.relative == "editor")
	assert(sidebar.row == 0 and sidebar.col == 0 and chat.row == 0)
	assert(sidebar.height == vim.o.lines and chat.height == vim.o.lines, "cover the full screen height")
	assert(chat.col == sidebar.width + 1 and chat.col + chat.width == vim.o.columns,
		"cover the full screen width")
end

local buffer_count
for iteration = 1, 3 do
	internals.ensure_ui()
	assert_overlay()
	local sidebar, chat = state.sidebar_win, state.chat_win
	internals.ensure_ui()
	assert(sidebar == state.sidebar_win and chat == state.chat_win, "repeated entry must reuse the overlay")
	mode.leave()
	assert_editor()
	assert(vim.deep_equal(sizes, window_sizes()), "preserve editor split sizes")
	assert(not vim.api.nvim_win_is_valid(sidebar) and not vim.api.nvim_win_is_valid(chat))
	if iteration == 1 then buffer_count = #vim.api.nvim_list_bufs() end
	assert(#vim.api.nvim_list_bufs() == buffer_count, "reopening must not accumulate scratch buffers")
end
print("ok - repeated entry fills the screen without adding tabs or buffers")

internals.ensure_ui()
internals.open_new_chat()
local composer = state.composer
vim.api.nvim_buf_set_lines(composer.buf, 0, -1, false, { "draft to keep" })
mode.leave()
assert_editor()
assert(not composer.win)
internals.ensure_ui()
assert_overlay()
assert(state.composer == composer and vim.api.nvim_win_is_valid(composer.win))
assert(vim.api.nvim_buf_get_lines(composer.buf, 0, -1, false)[1] == "draft to keep")
assert(vim.api.nvim_win_get_buf(state.chat_win) == composer.background_buf)
vim.o.columns, vim.o.lines = 100, 32
internals.resize_ui()
assert_overlay()
assert(vim.api.nvim_win_get_config(composer.win).win == state.chat_win)
mode.leave()
assert_editor()
print("ok - drafts survive leaving and resizing the overlay")

internals.ensure_ui()
internals.hide_composer()
local terminal = vim.api.nvim_create_buf(false, true)
vim.bo[terminal].bufhidden = "hide"
vim.api.nvim_win_set_buf(state.chat_win, terminal)
vim.api.nvim_set_current_win(state.chat_win)
local job = vim.fn.jobstart({ vim.fn.exepath("cat") }, { term = true })
assert(job > 0)
mode.leave()
assert_editor()
assert(vim.fn.jobwait({ job }, 0)[1] == -1, "leaving must keep the conversation process alive")
internals.ensure_ui()
assert(vim.api.nvim_win_get_buf(state.chat_win) == terminal, "reopening must reuse the same conversation")
assert_overlay()
mode.leave()
vim.fn.jobstop(job)
vim.api.nvim_buf_delete(terminal, { force = true })
print("ok - terminal conversations survive leaving and reopening")

internals.ensure_ui()
vim.api.nvim_set_current_win(state.sidebar_win)
internals.filter_recents()
local filter = state.filter
vim.o.columns, vim.o.lines = 110, 36
internals.resize_ui()
assert(vim.api.nvim_win_get_config(filter.win).width == vim.api.nvim_win_get_width(state.sidebar_win))
mode.leave()
assert_editor()
assert(not state.filter and not vim.api.nvim_win_is_valid(filter.win))
print("ok - leaving with the filter open closes every overlay window")

internals.ensure_ui()
local old_sidebar, old_chat = state.sidebar_win, state.chat_win
vim.cmd("tabprevious")
assert(not state.tab and vim.o.showtabline == 2)
assert(not vim.api.nvim_win_is_valid(old_sidebar) and not vim.api.nvim_win_is_valid(old_chat))
vim.api.nvim_set_current_win(origin)
assert_editor()
internals.ensure_ui()
vim.api.nvim_win_close(state.chat_win, true)
assert(vim.wait(100, function() return state.tab == nil end))
assert_editor()
print("ok - switching tabs and closing an overlay window restore the editor")

internals.shutdown()
vim.fn.delete(history_path)
print("Passed Agent Mode UI regression tests")
