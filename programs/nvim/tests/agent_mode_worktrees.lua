-- Run from the repository root:
-- nvim --headless -u NONE -i NONE -l programs/nvim/tests/agent_mode_worktrees.lua
local root = vim.fn.getcwd() .. "/programs/nvim/lua/agent_mode/"
for _, name in ipairs({ "backend", "history", "identity", "project", "sidebar", "docker" }) do
	package.preload["config.agent_mode." .. name] = function()
		return dofile(root .. name .. ".lua")
	end
end
local Project = require("config.agent_mode.project")
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
local home, input, select, notify = vim.env.HOME, vim.ui.input, vim.ui.select, vim.notify
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
	test("named creation uses the selected base HEAD and rejects duplicate paths", function()
		local complete, failure
		Project.create_worktree(state.project, directory, function(error, path)
			complete, failure, created = true, error, path
		end, "feature-test")
		assert(vim.wait(5000, function() return complete end))
		assert(not failure, failure)
		assert(vim.fs.basename(created) == "feature-test")
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
		vim.ui.select = function(items, options, done)
			assert(#items == 2 and options.format_item(items[2]):find(created, 1, true))
			done(items[2], 2)
		end
		vim.fn.maparg("<C-w>", "i", false, true).callback()
		assert(internals.current_target().path == created)
		assert(not state.new_worktree and not state.new_worktree_name)
		assert(vim.api.nvim_buf_get_lines(state.composer.buf, 0, -1, false)[1] == "keep this draft")
	end)

	test("cancelled and stale pickers do not change the destination", function()
		vim.ui.select = function(_, _, done) callback = done end
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
end)
vim.env.HOME, vim.ui.input, vim.ui.select, vim.notify = home, input, select, notify
vim.fn.delete(directory, "rf")
assert(ok, err)
print(string.format("Passed %d worktree regression tests", count))
