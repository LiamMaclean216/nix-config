-- nvim --headless -u NONE -i NONE -l programs/nvim/tests/agent_mode_rename_worktree.lua
local root = vim.fn.getcwd() .. "/programs/nvim/lua/agent_mode/"
for _, name in ipairs({ "backend", "history", "identity", "project", "sidebar", "docker" }) do
	package.preload["config.agent_mode." .. name] = function() return dofile(root .. name .. ".lua") end
end
local Project = require("config.agent_mode.project")
local Sidebar = require("config.agent_mode.sidebar")
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
for _, fn in pairs(mode) do if type(fn) == "function" then inspect(fn) end end
local state = internals.state
local directory = vim.fn.tempname()
local repo, feature = directory .. "/repo", directory .. "/feature"
vim.fn.mkdir(repo, "p")
local function git(...)
	local result = vim.system(vim.list_extend({ "git", "-C", repo }, { ... }), { text = true }):wait()
	assert(result.code == 0, result.stderr)
	return vim.trim(result.stdout)
end
local function rename(project, tree, name)
	local finished, err, branch = false
	Project.rename_worktree(project, tree, name, function(error, value) finished, err, branch = true, error, value end)
	assert(vim.wait(3000, function() return finished end))
	return err, branch
end
local function press(key) vim.fn.maparg(key, "n", false, true).callback() end
local count = 0
local function test(name, fn) fn(); count = count + 1; print("ok " .. count .. " - " .. name) end
local notify = vim.notify
local messages = {}
vim.notify = function(message) table.insert(messages, message) end
local ok, error = pcall(function()
	git("init", "-b", "main")
	git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "initial")
	git("worktree", "add", "-b", "feature", feature)

	test("branch rename preserves checkout, commits and uncommitted files", function()
		local project = Project.discover(repo)
		local tree = Project.worktree_for(project, feature)
		vim.fn.writefile({ "keep me" }, feature .. "/draft.txt")
		local err, name = rename(project, tree, "feature/renamed")
		assert(not err, err)
		assert(name == "feature/renamed" and git("rev-parse", "refs/heads/feature/renamed") == tree.head)
		assert(git("-C", feature, "symbolic-ref", "--short", "HEAD") == name)
		assert(vim.fn.readfile(feature .. "/draft.txt")[1] == "keep me")
		assert(Project.worktree_for(Project.discover(repo), feature).label == name)
	end)

	test("invalid and existing branch names never overwrite refs", function()
		local project = Project.discover(repo)
		local tree = Project.worktree_for(project, feature)
		for _, name in ipairs({ "bad name", "-bad", "../bad", "main", "@{-1}" }) do
			assert(rename(project, tree, name), "must reject " .. name)
			assert(git("-C", feature, "symbolic-ref", "--short", "HEAD") == "feature/renamed")
		end
		assert(not rename(project, tree, "feature/renamed"), "same name is a no-op")
	end)

	test("an externally renamed branch invalidates the pending prompt", function()
		local project = Project.discover(repo)
		local tree = Project.worktree_for(project, feature)
		git("branch", "-m", "feature/renamed", "external")
		assert(rename(project, tree, "stale"):find("branch changed"))
		assert(git("-C", feature, "symbolic-ref", "--short", "HEAD") == "external")
	end)

	test("a detached worktree gets a named branch without moving its checkout", function()
		local detached = directory .. "/detached"
		git("worktree", "add", "--detach", detached, "HEAD")
		vim.fn.writefile({ "detached draft" }, detached .. "/draft.txt")
		local project = Project.discover(repo)
		local tree = Project.worktree_for(project, detached)
		assert(not rename(project, tree, "detached-name"))
		assert(git("-C", detached, "symbolic-ref", "--short", "HEAD") == "detached-name")
		assert(git("rev-parse", "detached-name") == tree.head)
		assert(vim.fn.readfile(detached .. "/draft.txt")[1] == "detached draft")
	end)

	state.opts = { sidebar_width = 40 }
	state.sidebar_buf = vim.api.nvim_create_buf(false, true)
	state.sidebar_win = vim.api.nvim_open_win(state.sidebar_buf, true, {
		relative = "editor", row = 0, col = 0, width = 40, height = 20, style = "minimal",
	})
	state.project = Project.discover(repo)
	state.sidebar_worktree, state.sidebar_level = feature, "worktrees"
	state.backend_ready = false
	internals.sidebar_mappings()
	internals.render_sidebar()
	local input, reply = vim.ui.input
	vim.ui.input = function(options, callback)
		assert(options.prompt == "Rename worktree / branch: " and options.default == "external")
		reply = callback
	end

	test("a cancels cleanly and ignores stale prompts and individual runs", function()
		press("a"); reply(nil)
		assert(not state.project.renaming_worktree)
		press("a"); reply("  ")
		assert(not state.project.renaming_worktree)
		local project = state.project
		press("a"); state.project = Project.discover(repo); reply("ignored")
		assert(not project.renaming_worktree and git("-C", feature, "symbolic-ref", "--short", "HEAD") == "external")
		state.sidebar_level = "runs"
		reply = nil; press("a"); assert(reply == nil)
		state.sidebar_level = "worktrees"
	end)

	test("a immediately refreshes the branch label and retains worktree selection", function()
		press("a"); reply("from-sidebar")
		assert(vim.wait(3000, function() return not state.project.renaming_worktree end))
		assert(state.sidebar_worktree == feature)
		assert(Project.worktree_for(state.project, feature).label == "from-sidebar")
		assert(git("-C", feature, "symbolic-ref", "--short", "HEAD") == "from-sidebar")
		assert(vim.wait(3000, function() return not state.project.worktrees_refreshing end))
	end)
	vim.ui.input = input

end)
vim.notify = notify
vim.fn.delete(directory, "rf")
assert(ok, error)
print("Passed " .. count .. " worktree rename regression tests")
