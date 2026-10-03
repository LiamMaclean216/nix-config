-- Run from the repository root:
-- nvim --headless -u NONE -i NONE -l programs/nvim/tests/agent_mode_worktrees.lua
local root = vim.fn.getcwd() .. "/programs/nvim/lua/agent_mode/"
for _, name in ipairs({ "backend", "history", "identity", "project", "sidebar", "docker" }) do
	package.preload["config.agent_mode." .. name] = function()
		return dofile(root .. name .. ".lua")
	end
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
for _, fn in pairs(mode) do
	if type(fn) == "function" then inspect(fn) end
end
local state = assert(internals.state)
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
local home, input, select, notify = vim.env.HOME, vim.ui.input, Sidebar.select_worktree, vim.notify
local function git(...)
	local args = { "git", "-C", directory }
	vim.list_extend(args, { ... })
	local result = vim.system(args, { text = true }):wait()
	assert(result.code == 0, result.stderr)
	return vim.trim(result.stdout)
end
local count = 0
local function test(name, fn)
	fn()
	count = count + 1
	print("ok " .. count .. " - " .. name)
end
local ok, err = pcall(function()
	vim.env.HOME = directory
	git("init", "-b", "main")
	git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "initial")
	state.project = Project.discover(directory)
	state.chat_win = vim.api.nvim_get_current_win()
	state.composer = { buf = vim.api.nvim_create_buf(false, true), background_buf = vim.api.nvim_create_buf(false, true) }
	vim.api.nvim_win_set_buf(state.chat_win, state.composer.background_buf)
	vim.api.nvim_buf_set_lines(state.composer.buf, 0, -1, false, { "keep this draft" })
	internals.render_composer()
	vim.api.nvim_set_current_win(state.composer.win)
	internals.composer_mappings(state.composer.buf)
	local warnings = {}
	vim.notify = function(message) table.insert(warnings, message) end
	local callback
	vim.ui.input = function(options, done)
		assert(options.prompt == "New worktree name: ")
		callback = done
	end

	test("Ctrl-T names a pending worktree without losing the draft", function()
		vim.fn.maparg("<C-t>", "i", false, true).callback()
		callback("feature-test")
		assert(state.new_worktree and state.new_worktree_name == "feature-test")
		assert(vim.api.nvim_buf_get_lines(state.composer.buf, 0, -1, false)[1] == "keep this draft")
		local frame = table.concat(vim.api.nvim_buf_get_lines(state.composer.background_buf, 0, -1, false), "\n")
		assert(frame:find("feature-test (new, from main)", 1, true))
		assert(frame:find("Ctrl-W select worktree", 1, true) and frame:find("Ctrl-T new worktree", 1, true))
		assert(#Project.discover(directory).worktrees == 1, "naming must defer creation until submit")
	end)

	test("cancel, empty input and invalid paths preserve the pending worktree", function()
		for _, value in ipairs({ false, "  ", "../escape", "a/b" }) do
			mode.new_worktree()
			callback(value or nil)
			assert(state.new_worktree and state.new_worktree_name == "feature-test")
		end
		assert(#warnings == 2)
	end)

	local created
	test("named creation checks out a new branch at the selected base HEAD and rejects duplicate paths", function()
		local complete, failure
		Project.create_worktree(state.project, directory, function(error, path)
			complete, failure, created = true, error, path
		end, "feature-test")
		assert(vim.wait(5000, function() return complete end))
		assert(not failure, failure)
		assert(vim.fs.basename(created) == "feature-test")
		assert(git("-C", created, "symbolic-ref", "--short", "HEAD") == "feature-test")
		assert(git("-C", created, "rev-parse", "HEAD") == git("rev-parse", "HEAD"))
		complete = false
		Project.create_worktree(state.project, directory, function(error)
			complete, failure = true, error
		end, "feature-test")
		assert(vim.wait(1000, function() return complete end))
		assert(failure:find("already exists", 1, true))
	end)

	test("Ctrl-W refreshes existing worktrees and selects the chat directory", function()
		assert(#state.project.worktrees == 1, "start with a stale worktree list")
		Sidebar.select_worktree = function(items, options, done)
			assert(#items == 2 and options.format_item(items[2]):find(created, 1, true))
			done(items[2], 2)
		end
		vim.fn.maparg("<C-w>", "i", false, true).callback()
		assert(internals.current_target().path == created)
		assert(not state.new_worktree and not state.new_worktree_name)
		assert(vim.api.nvim_buf_get_lines(state.composer.buf, 0, -1, false)[1] == "keep this draft")
	end)

	test("the real picker browses worktrees with arrows and Enter without editing the draft", function()
		Sidebar.select_worktree = select
		local origin = vim.api.nvim_get_current_win()
		mode.select_worktree()
		local picker = vim.api.nvim_get_current_win()
		assert(picker ~= origin and vim.bo.filetype == "agentmodeworktrees")
		assert(vim.api.nvim_win_get_cursor(picker)[1] == 2, "start on the current destination")
		local keys = vim.api.nvim_replace_termcodes("<Up><Down><Up><CR>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		assert(not vim.api.nvim_win_is_valid(picker))
		assert(vim.api.nvim_get_current_win() == origin)
		assert(internals.current_target().path == directory)
		assert(vim.api.nvim_buf_get_lines(state.composer.buf, 0, -1, false)[1] == "keep this draft")
		mode.select_worktree()
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Down><Esc>", true, false, true), "xt", false)
		assert(internals.current_target().path == directory, "cancel must preserve the destination")
		mode.select_worktree()
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab><CR>", true, false, true), "xt", false)
		assert(internals.current_target().path == created)
	end)

	test("cancelled and stale pickers do not change the destination", function()
		Sidebar.select_worktree = function(_, _, done) callback = done end
		mode.select_worktree()
		callback(nil)
		assert(internals.current_target().path == created)
		mode.select_worktree()
		local project = state.project
		state.project = { launch_cwd = "/other", common_dir = "/other/.git", worktrees = {} }
		callback(project.worktrees[1], 1)
		assert(#state.project.worktrees == 0 and state.new_target == 2)
		state.project = project
		mode.new_worktree()
		state.composer.busy = true
		callback("too-late")
		assert(not state.new_worktree)
		state.composer.busy = false
	end)

	test("submission creates the requested name from the selected worktree and launches there", function()
		git("-C", created, "-c", "user.name=Test", "-c", "user.email=test@example.com",
			"commit", "--allow-empty", "-m", "selected worktree commit")
		local launched
		local submit = internals.submit_composer
		local launch_index, real_launch
		for index = 1, math.huge do
			local name, value = debug.getupvalue(submit, index)
			if not name then break end
			if name == "launch_new_chat" then launch_index, real_launch = index, value; break end
		end
		assert(launch_index)
		debug.setupvalue(submit, launch_index, function(path, prompt)
			assert(prompt == "keep this draft")
			launched = path
		end)
		mode.new_worktree()
		callback("from-selected")
		submit()
		assert(vim.wait(5000, function() return launched ~= nil end))
		debug.setupvalue(submit, launch_index, real_launch)
		assert(vim.fs.basename(launched) == "from-selected")
		assert(git("-C", launched, "symbolic-ref", "--short", "HEAD") == "from-selected")
		assert(internals.current_target().path == launched)
		assert(internals.current_target().branch == "from-selected")
		assert(git("-C", launched, "rev-parse", "HEAD") == git("-C", created, "rev-parse", "HEAD"))
		assert(git("-C", launched, "rev-parse", "HEAD") ~= git("rev-parse", "HEAD"))
		assert(not state.new_worktree and not state.new_worktree_name)
		state.composer.busy = false -- The test launcher keeps the composer open.
	end)

	test("a creation failure restores the editable draft and pending name", function()
		mode.new_worktree()
		callback("feature-test")
		internals.submit_composer()
		assert(vim.wait(1000, function() return not state.composer.busy end))
		assert(vim.bo[state.composer.buf].modifiable)
		assert(state.new_worktree_name == "feature-test")
		assert(warnings[#warnings]:find("already exists", 1, true))
		assert(vim.api.nvim_buf_get_lines(state.composer.buf, 0, -1, false)[1] == "keep this draft")
	end)

	test("worktree shortcuts are available in normal mode and the sidebar", function()
		assert(vim.fn.maparg("<C-w>", "n", false, true).callback == mode.select_worktree)
		assert(vim.fn.maparg("<C-t>", "n", false, true).callback == mode.new_worktree)
		state.sidebar_buf = vim.api.nvim_create_buf(false, true)
		internals.sidebar_mappings()
		vim.api.nvim_win_set_buf(state.chat_win, state.sidebar_buf)
		vim.api.nvim_set_current_win(state.chat_win)
		assert(vim.fn.maparg("<C-w>", "n", false, true).callback == mode.select_worktree)
		assert(vim.fn.maparg("<C-t>", "n", false, true).callback == mode.new_worktree)
	end)

	test("Ctrl-T in Recents moves the selected chat from its own HEAD and preserves its ID", function()
		state.opts = vim.deepcopy(internals.defaults)
		local thread = { id = "saved-chat", cwd = created, preview = "Existing conversation", status = { type = "idle" } }
		state.threads = { [thread.id] = thread }
		state.selected_id, state.recents_tab = thread.id, "active"
		state.backend_ready = true
		state.refreshing = true -- Keep this test independent of the recents polling transport.
		local moved_path, move_done
		state.backend = { move_thread = function(_, id, path, done)
			assert(id == thread.id)
			moved_path, move_done = path, done
		end }
		local open_selected, reopened = mode.open_selected, nil
		mode.open_selected = function() reopened = state.threads[thread.id] end
		vim.fn.maparg("<C-t>", "n", false, true).callback()
		callback("moved-chat")
		assert(state.move_pending[thread.id])
		assert(vim.wait(5000, function() return moved_path ~= nil end))
		assert(git("-C", moved_path, "rev-parse", "HEAD") == git("-C", created, "rev-parse", "HEAD"))
		assert(git("-C", moved_path, "symbolic-ref", "--short", "HEAD") == "moved-chat")
		assert(state.threads[thread.id].cwd == created, "do not announce the move before Codex confirms it")
		move_done(nil, vim.tbl_extend("force", thread, { cwd = moved_path }))
		mode.open_selected = open_selected
		assert(reopened.id == thread.id and reopened.cwd == moved_path)
		assert(reopened.preview == "Existing conversation" and not state.move_pending[thread.id])
		assert(vim.api.nvim_buf_get_lines(state.composer.buf, 0, -1, false)[1] == "keep this draft")
		assert(state.new_worktree_name == "feature-test", "moving a recent must preserve the new-chat draft destination")
	end)

	test("cancelled and stale Recents prompts and busy chats do not create worktrees", function()
		local before = #Project.discover(directory).worktrees
		mode.new_worktree()
		callback(nil)
		mode.new_worktree()
		state.selected_id = "different-chat"
		callback("stale-move")
		state.selected_id = "saved-chat"
		state.threads["saved-chat"].status = { type = "active", activeFlags = {} }
		local old_callback = callback
		mode.new_worktree()
		assert(callback == old_callback, "busy chats must not open a naming prompt")
		assert(#Project.discover(directory).worktrees == before)
		state.threads["saved-chat"].status = { type = "idle" }
	end)

	test("a failed Recents move retains the original directory and reports the created worktree", function()
		local original = state.threads["saved-chat"].cwd
		state.backend.move_thread = function(_, _, _, done) done("writer conflict") end
		local open_selected = mode.open_selected
		mode.open_selected = function() end
		mode.new_worktree()
		callback("failed-move")
		assert(vim.wait(5000, function() return not state.move_pending["saved-chat"] end))
		mode.open_selected = open_selected
		assert(state.threads["saved-chat"].cwd == original)
		assert(warnings[#warnings]:find("writer conflict", 1, true))
		assert(warnings[#warnings]:find("failed-move", 1, true))
	end)

	local timestamp = os.time() + 100
	local function recent_git(...)
		timestamp = timestamp + 1
		local args = { "git", "-C", directory }
		vim.list_extend(args, { ... })
		local result = vim.system(args, { text = true, env = { GIT_COMMITTER_DATE = timestamp .. " +0000" } }):wait()
		assert(result.code == 0, result.stderr)
	end
	test("recent branches follow checkout activity, exclude deleted/checked-out branches and cap at ten", function()
		for index = 1, 12 do
			recent_git("checkout", "-b", "feature/" .. index)
			if index == 11 then
				recent_git("-c", "user.name=Test", "-c", "user.email=test@example.com",
					"commit", "--allow-empty", "-m", "branch-specific commit")
			end
		end
		recent_git("checkout", "feature/2") -- Old commit, most recently used branch.
		recent_git("checkout", "main")
		recent_git("branch", "-D", "feature/12")
		local branches = assert(Project.recent_branches(Project.discover(directory), 10))
		assert(#branches == 10)
		assert(branches[1] == "feature/2", vim.inspect(branches))
		assert(branches[2] == "feature/11", vim.inspect(branches))
		assert(not vim.tbl_contains(branches, "main") and not vim.tbl_contains(branches, "feature/12"))
		assert(#Project.recent_branches({}) == 0)
	end)

	local branch_choice, branch_index, picker_done
	Sidebar.select_worktree = function(items, options, done)
		local trees = #Project.discover(directory).worktrees
		assert(#items == trees + 10)
		for index = 1, trees do assert(items[index].path and not items[index].new_branch) end
		assert(items[trees + 1].new_branch == "feature/2")
		branch_index, branch_choice, picker_done = trees + 2, items[trees + 2], done
		assert(options.format_item(branch_choice):find("feature/11", 1, true))
		assert(options.format_item(branch_choice):find("create worktree", 1, true))
	end
	test("cancelled and stale recent-branch selections do not create a worktree", function()
		local before = #Project.discover(directory).worktrees
		mode.select_worktree()
		picker_done(nil)
		mode.select_worktree()
		local project = state.project
		state.project = { common_dir = "/other/.git", launch_cwd = "/other", worktrees = {} }
		picker_done(branch_choice, branch_index)
		state.project = project
		assert(#Project.discover(directory).worktrees == before)
	end)

	test("selecting a recent branch immediately creates and displays an empty worktree in Recents", function()
		state.sidebar_win = vim.api.nvim_open_win(state.sidebar_buf, true, {
			relative = "editor", row = 0, col = 0, width = 40, height = 20, style = "minimal",
		})
		local threads_before = vim.tbl_count(state.threads)
		local before = #Project.discover(directory).worktrees
		mode.select_worktree()
		picker_done(branch_choice, branch_index)
		assert(state.project.creating_worktree)
		assert(vim.wait(5000, function() return not state.project.creating_worktree end))
		assert(#state.project.worktrees == before + 1, warnings[#warnings])
		local tree = internals.current_target()
		assert(tree.branch == "feature/11" and tree.label == "feature/11")
		assert(git("-C", tree.path, "symbolic-ref", "--short", "HEAD") == "feature/11")
		assert(git("-C", tree.path, "rev-parse", "HEAD") == git("rev-parse", "refs/heads/feature/11"))
		assert(git("-C", tree.path, "rev-parse", "HEAD") ~= git("rev-parse", "HEAD"))
		assert(state.sidebar_worktree == tree.path and state.sidebar_level == "worktrees")
		assert(state.group_rows[tree.path], "empty worktree must appear immediately in Recents")
		local lines = table.concat(vim.api.nvim_buf_get_lines(state.sidebar_buf, 0, -1, false), "\n")
		assert(lines:find("feature/11", 1, true))
		assert(vim.tbl_count(state.threads) == threads_before, "no message or conversation should be created")
		assert(vim.api.nvim_buf_get_lines(state.composer.buf, 0, -1, false)[1] == "keep this draft")
		assert(not state.new_worktree and not state.new_worktree_name)
		assert(not vim.tbl_contains(Project.recent_branches(state.project), "feature/11"))
	end)

	test("a branch deleted after opening the picker leaves the destination and draft intact", function()
		local previous = internals.current_target().path
		Sidebar.select_worktree = function(items, _, done)
			for index, item in ipairs(items) do
				if item.new_branch == "feature/2" then
					git("branch", "-D", "feature/2")
					done(item, index)
					return
				end
			end
			error("missing recent branch")
		end
		mode.select_worktree()
		assert(vim.wait(5000, function() return not state.project.creating_worktree end))
		assert(internals.current_target().path == previous)
		assert(warnings[#warnings]:find("git worktree add failed", 1, true))
		assert(vim.api.nvim_buf_get_lines(state.composer.buf, 0, -1, false)[1] == "keep this draft")
	end)

	test("unnamed creation checks out an automatically named branch", function()
		local complete, failure, path
		Project.create_worktree(state.project, directory, function(error, created_path)
			complete, failure, path = true, error, created_path
		end)
		assert(vim.wait(5000, function() return complete end))
		assert(not failure, failure)
		assert(git("-C", path, "symbolic-ref", "--short", "HEAD") == vim.fs.basename(path))
		assert(git("-C", path, "rev-parse", "HEAD") == git("rev-parse", "HEAD"))
	end)

	test("an existing branch is preserved when a new worktree uses its name", function()
		git("branch", "existing-branch", "feature-test")
		local original = git("rev-parse", "existing-branch")
		local before = #Project.discover(directory).worktrees
		local complete, failure, path
		Project.create_worktree(state.project, directory, function(error, created_path)
			complete, failure, path = true, error, created_path
		end, "existing-branch")
		assert(vim.wait(5000, function() return complete end))
		assert(failure and failure:find("already exists", 1, true), failure)
		assert(not path)
		assert(#Project.discover(directory).worktrees == before)
		assert(git("rev-parse", "existing-branch") == original)
	end)
end)
vim.env.HOME, vim.ui.input, Sidebar.select_worktree, vim.notify = home, input, select, notify
vim.fn.delete(directory, "rf")
assert(ok, err)
print(string.format("Passed %d worktree regression tests", count))
