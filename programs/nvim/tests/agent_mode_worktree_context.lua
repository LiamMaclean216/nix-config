-- nvim --headless -u NONE -i NONE -l programs/nvim/tests/agent_mode_worktree_context.lua
local root = vim.fn.getcwd() .. "/programs/nvim/lua/"
for _, name in ipairs({ "backend", "history", "identity", "project", "sidebar", "docker" }) do
	package.preload["config.agent_mode." .. name] = function() return dofile(root .. "agent_mode/" .. name .. ".lua") end
end
local mode = dofile(root .. "agent_mode/init.lua")
package.loaded["config.agent_mode"] = mode
local function upvalue(fn, key, replacement)
	for index = 1, math.huge do
		local name, value = debug.getupvalue(fn, index)
		assert(name, "Missing upvalue: " .. key)
		if name == key then
			if replacement then debug.setupvalue(fn, index, replacement) end
			return value
		end
	end
end
local state = upvalue(mode.selected_worktree, "state")
local editor = vim.api.nvim_get_current_win()
local temp = vim.fn.tempname()
local main, branch, empty = temp .. "/main", temp .. "/feature", temp .. "/empty"
for _, path in ipairs({ main, branch, empty }) do vim.fn.mkdir(path .. "/.git", "p") end
vim.cmd.cd(main)
state.project = { current_worktree = main, worktrees = { { path = main }, { path = branch }, { path = empty } } }
state.sidebar_buf = vim.api.nvim_create_buf(false, true)
state.sidebar_win = vim.api.nvim_open_win(state.sidebar_buf, true, {
	relative = "editor", row = 0, col = 0, width = 40, height = 15,
})
state.sidebar_level, state.sidebar_worktree = "worktrees", branch
state.order = { { id = "old", cwd = main }, { id = "selected", cwd = branch .. "/src" } }
state.selected_id = "old"
assert(mode.selected_worktree() == branch, "highlighted worktree wins over a previously selected run")
state.sidebar_level, state.selected_id = "runs", "selected"
assert(mode.selected_worktree() == branch, "runs in subdirectories resolve to their worktree root")
state.sidebar_level, state.sidebar_worktree = "worktrees", empty
assert(mode.selected_worktree() == empty, "empty worktrees are selectable")
vim.api.nvim_set_current_win(editor)
assert(mode.selected_worktree() == nil, "sidebar selection must not override ordinary editor context")
print("ok - sidebar context follows worktrees and runs, and stays local to the sidebar")

local terminals = {}
package.preload["toggleterm.terminal"] = function()
	return { Terminal = { new = function(_, options)
		options.toggle = function(self) self.toggles = (self.toggles or 0) + 1 end
		table.insert(terminals, options)
		return options
	end } }
end
package.preload["config.keymaps.funcs"] = function() return {} end
dofile(root .. "keymaps/terminal.lua")
local function press(key) vim.fn.maparg(key, "n", false, true).callback() end
local function terminal(cmd, path)
	for _, term in ipairs(terminals) do
		if term.cmd == cmd and term.dir == path then return term end
	end
	error("Missing terminal for " .. cmd .. " in " .. path)
end
vim.api.nvim_set_current_win(state.sidebar_win)
for _, path in ipairs({ branch, empty, branch }) do
	state.sidebar_worktree = path
	press("<C-g>"); press("<C-v>")
end
for _, cmd in ipairs({ "lazygit", "lazydocker" }) do
	assert(terminal(cmd, branch).toggles == 2, "reuse the terminal for the same worktree")
	assert(terminal(cmd, empty).toggles == 1, "keep different worktrees separate")
end
vim.api.nvim_set_current_win(editor)
press("<C-g>"); press("<C-v>")
assert(terminal("lazygit", main).toggles == 1 and terminal("lazydocker", main).toggles == 1)
assert(vim.fn.getcwd() == main, "opening a worktree terminal must not change Neovim's cwd")
print("ok - both hotkeys use and reuse the selected worktree, with editor cwd fallback")

local enter = upvalue(mode.new_chat, "enter_agent_mode", function()
	-- Rediscovery may reorder worktrees and UI entry can move focus.
	state.project.worktrees = { { path = empty }, { path = main }, { path = branch } }
	vim.api.nvim_set_current_win(editor)
end)
local opened
local open = upvalue(mode.new_chat, "open_new_chat", function()
	opened = state.project.worktrees[state.new_target].path
end)
vim.api.nvim_set_current_win(state.sidebar_win)
state.sidebar_worktree = branch
state.new_target, state.new_worktree, state.new_worktree_name = 1, true, "previous-choice"
mode.new_chat()
assert(opened == branch and not state.new_worktree and state.new_worktree_name == nil,
	"new chats must capture the highlighted worktree before rediscovery and UI focus changes")
state.new_target = 1
mode.new_chat()
assert(opened == empty, "outside the sidebar, preserve the existing target")
vim.api.nvim_set_current_win(state.sidebar_win)
state.composer = { busy = true }
mode.new_chat()
assert(opened == empty, "do not retarget a chat while it is launching")
upvalue(mode.new_chat, "enter_agent_mode", enter)
upvalue(mode.new_chat, "open_new_chat", open)
print("ok - new chats inherit sidebar selection without retargeting pending launches")

local Docker = require("config.agent_mode.docker")
local Project = require("config.agent_mode.project")
local discover, supported = Project.discover, Docker.supported
Project.discover = function() return { common_dir = main .. "/.git" } end
Docker.supported = function() return true end
vim.fn.writefile({ "# Generated state", "COMPOSE_PROJECT_NAME=feature-12345678", "DEV_WEB_PORT=8100" }, branch .. "/.env.worktree")
vim.fn.writefile({}, main .. "/.env")
local env = Docker.lazydocker_env(branch)
assert(env.COMPOSE_PROJECT_NAME == "feature-12345678" and env.DEV_WEB_PORT == "8100")
assert(env.DEV_ENV_FILE == main .. "/.env" and env.COMPOSE_ENV_FILES == main .. "/.env")
vim.fn.writefile({}, branch .. "/.env")
assert(Docker.lazydocker_env(branch).DEV_ENV_FILE == branch .. "/.env")
assert(Docker.lazydocker_env(empty) == nil)
Project.discover, Docker.supported = discover, supported
print("ok - Lazydocker inherits saved Compose scope and the worktree's environment file")
vim.api.nvim_win_close(state.sidebar_win, true)
vim.cmd.cd(root)
vim.fn.delete(temp, "rf")
