-- nvim --headless -u NONE -i NONE -l programs/nvim/tests/agent_mode_remove_worktree.lua
local root = vim.fn.getcwd() .. "/programs/nvim/lua/agent_mode/"
for _, name in ipairs({ "backend", "history", "identity", "project", "sidebar", "docker" }) do
	package.preload["config.agent_mode." .. name] = function() return dofile(root .. name .. ".lua") end
end
local Project = require("config.agent_mode.project")
local Sidebar = require("config.agent_mode.sidebar")
local Docker = require("config.agent_mode.docker")
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
local function remove(project, tree)
	local finished, err, branch = false
	Project.remove_worktree(project, tree, function(error, kept) finished, err, branch = true, error, kept end)
	assert(vim.wait(3000, function() return finished end), "removal callback timed out")
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

	test("main worktree cannot be removed", function()
		local project = Project.discover(repo)
		assert(remove(project, project.worktrees[1]):find("main worktree"))
		assert(vim.fn.isdirectory(repo) == 1)
	end)

	test("dirty and locked worktrees are refused without deleting their branch", function()
		local project = Project.discover(repo)
		local tree = Project.worktree_for(project, feature)
		vim.fn.writefile({ "keep me" }, feature .. "/draft.txt")
		assert(remove(project, tree))
		assert(vim.fn.readfile(feature .. "/draft.txt")[1] == "keep me")
		assert(git("rev-parse", "feature") == tree.head)
		vim.fn.delete(feature .. "/draft.txt")
		git("worktree", "lock", feature)
		assert(remove(project, tree))
		assert(vim.fn.isdirectory(feature) == 1)
		git("worktree", "unlock", feature)
	end)

	test("a changed branch invalidates the confirmed snapshot", function()
		local project = Project.discover(repo)
		local tree = Project.worktree_for(project, feature)
		git("branch", "-m", "feature", "renamed")
		assert(remove(project, tree):find("worktree changed"))
		assert(vim.fn.isdirectory(feature) == 1)
		git("branch", "-m", "renamed", "feature")
	end)

	test("confirmation defaults to cancel and handles escape and window closure", function()
		for _, action in ipairs({ "<CR>", "<Esc>", "close" }) do
			local result, calls
			calls = 0
			Sidebar.confirm_remove({ path = feature, branch = "feature" }, function(value) result, calls = value, calls + 1 end)
			local win = vim.api.nvim_get_current_win()
			if action == "close" then vim.api.nvim_win_close(win, true) else press(action) end
			assert(result == false and calls == 1 and not vim.api.nvim_win_is_valid(win))
		end
	end)

	test("confirmation requires explicitly selecting Delete before Enter", function()
		local result
		Sidebar.confirm_remove({ path = feature, branch = "feature" }, function(value) result = value end)
		press("l"); press("<CR>")
		assert(result == true)
	end)

	state.opts = { sidebar_width = 40, preview_loading_timeout = 5000 }
	state.sidebar_buf = vim.api.nvim_create_buf(false, true)
	state.sidebar_win = vim.api.nvim_open_win(state.sidebar_buf, true, {
		relative = "editor", row = 0, col = 0, width = 40, height = 20, style = "minimal",
	})
	state.project = Project.discover(repo)
	state.sidebar_worktree, state.sidebar_level = feature, "worktrees"
	state.backend_ready = false
	state.backend = { start = function() end, list_threads = function(_, _, callback) callback(nil, {}) end }
	internals.sidebar_mappings()
	internals.render_sidebar()

	test("D on a run neither removes its worktree nor dismisses runs", function()
		state.threads.idle = { id = "idle", cwd = feature, status = { type = "idle" } }
		state.sidebar_level = "runs"
		press("D")
		assert(vim.api.nvim_get_current_win() == state.sidebar_win)
		assert(not state.project.removing_worktree and vim.fn.isdirectory(feature) == 1)
		assert(state.threads.idle and not state.threads.idle._dismissed)
		state.threads, state.sidebar_level = {}, "worktrees"
	end)

	test("D cancels without touching disk and ignores a confirmation from another project", function()
		press("D"); press("<Esc>")
		assert(vim.fn.isdirectory(feature) == 1 and not state.project.removing_worktree)
		local project = state.project
		press("D")
		state.project = Project.discover(repo)
		press("l"); press("<CR>")
		assert(vim.fn.isdirectory(feature) == 1 and not project.removing_worktree)
	end)

	test("D confirms a worktree containing a working run and cancellation leaves it alone", function()
		state.threads.busy = { id = "busy", cwd = feature, status = { type = "active" } }
		press("D")
		assert(vim.api.nvim_get_current_win() ~= state.sidebar_win)
		local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
		assert(text:find("Stop and dismiss all Codex sessions", 1, true))
		press("<Esc>")
		assert(not state.project.removing_worktree and vim.fn.isdirectory(feature) == 1)
		assert(state.threads.busy and not state.threads.busy._dismissed)
		state.threads = {}
	end)

	for _, failure in ipairs({ "list", "interrupt", "archive" }) do
		test("session " .. failure .. " failure leaves the checkout intact", function()
			local backend = state.backend
			state.backend = {
				list_threads = function(_, _, callback)
					callback(failure == "list" and "list failed" or nil, { { id = "busy", cwd = feature } })
				end,
				interrupt_thread = function(_, _, callback)
					callback(failure == "interrupt" and "interrupt failed" or nil)
				end,
				archive_thread = function(_, _, callback)
					assert(failure == "archive")
					callback("archive failed")
				end,
			}
			press("D"); press("l"); press("<CR>")
			assert(vim.wait(3000, function() return not state.project.removing_worktree end))
			assert(vim.fn.isdirectory(feature) == 1 and not state.dismiss_pending.busy)
			assert(messages[#messages]:find(failure .. " failed", 1, true))
			state.backend = backend
		end)
	end

	test("Docker wipe requires confirmation, checks Git first, and aborts checkout deletion on failure", function()
		local supported, destroy = Docker.supported, Docker.destroy
		Docker.supported = function() return true end
		local calls = 0
		Docker.destroy = function(path, _, _, callback)
			calls = calls + 1
			assert(path == feature and vim.fn.isdirectory(feature) == 1)
			callback("volume removal failed")
		end
		press("D"); press("<Esc>")
		assert(calls == 0)
		vim.fn.writefile({ "unsaved work" }, feature .. "/draft.txt")
		press("D"); press("l"); press("<CR>")
		assert(vim.wait(3000, function() return not state.project.removing_worktree end))
		assert(calls == 0, "dirty checkout must fail before wiping Docker data")
		vim.fn.delete(feature .. "/draft.txt")
		press("D"); press("l"); press("<CR>")
		assert(vim.wait(3000, function() return not state.project.removing_worktree end))
		assert(calls == 1 and vim.fn.isdirectory(feature) == 1)
		assert(git("rev-parse", "refs/heads/feature") ~= "")
		Docker.supported, Docker.destroy = supported, destroy
	end)

	test("confirmed D removes the checkout, keeps the local branch and updates the sidebar", function()
		local head = git("rev-parse", "feature")
		local backend = state.backend
		local interrupted, archived = {}, {}
		local rows = {
			{ id = "busy", cwd = feature, status = { type = "active" } },
			{ id = "approval", cwd = feature .. "/src", status = { type = "waitingOnApproval" } },
			{ id = "input", cwd = feature, status = { type = "waitingOnUserInput" } },
			{ id = "idle", cwd = feature, status = { type = "idle" } },
			{ id = "unseen", cwd = feature, status = { type = "active" } },
			{ id = "other", cwd = repo, status = { type = "active" } },
			{ id = "sibling", cwd = feature .. "-other", status = { type = "active" } },
		}
		state.threads.busy = rows[1]
		state.threads.other = rows[6]
		state.chat_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
			relative = "editor", row = 0, col = 41, width = 30, height = 10, style = "minimal",
		})
		state.opts.command = { vim.fn.exepath("sh"), "-c", "sleep 30" }
		local session = internals.create_terminal("busy", feature, "busy", "busy")
		local pending = internals.create_terminal(nil, feature, "pending-1", nil, true)
		local other = internals.create_terminal("other", repo, "other", "other")
		state.threads["pending-1"] = { id = "pending-1", cwd = feature }
		local jobs = { session.job_id, pending.job_id }
		state.backend = {
			start = function() end,
			list_threads = function(_, params, callback)
				assert(params.archived == false)
				assert(not state.sessions.busy and not state.sessions["pending-1"])
				assert(not state.threads["pending-1"])
				for _, result in ipairs(vim.fn.jobwait(jobs, 0)) do assert(result ~= -1) end
				callback(nil, rows)
			end,
			interrupt_thread = function(_, id, callback)
				assert(id ~= "other" and id ~= "sibling")
				assert(vim.fn.isdirectory(feature) == 1)
				interrupted[id] = true
				callback(nil)
			end,
			archive_thread = function(_, id, callback)
				assert(interrupted[id] and vim.fn.isdirectory(feature) == 1)
				archived[id] = true
				callback(nil)
			end,
		}
		local supported, destroy = Docker.supported, Docker.destroy
		Docker.supported = function() return true end
		local cleanup_done
		Docker.destroy = function(path, _, _, callback)
			assert(path == feature and vim.fn.isdirectory(feature) == 1)
			assert(vim.tbl_count(archived) == 5)
			cleanup_done = callback
		end
		press("D"); press("l"); press("<CR>")
		assert(vim.wait(3000, function() return cleanup_done ~= nil end))
		assert(vim.fn.isdirectory(feature) == 1, "checkout must remain until Docker cleanup completes")
		cleanup_done(nil)
		Docker.supported, Docker.destroy = supported, destroy
		assert(vim.wait(3000, function() return not state.project.removing_worktree and #state.project.worktrees == 1 end))
		assert(vim.fn.isdirectory(feature) == 0)
		assert(git("rev-parse", "refs/heads/feature") == head)
		assert(not state.group_rows[feature] and state.sidebar_worktree == repo)
		assert(not state.sessions.busy and not state.session_tokens[session.notify_token])
		assert(not vim.api.nvim_buf_is_valid(session.buf) and not vim.api.nvim_buf_is_valid(pending.buf))
		assert(state.sessions.other == other and vim.fn.jobwait({ other.job_id }, 0)[1] == -1)
		for id in pairs(archived) do assert(not state.threads[id] and state.dismissed_threads[id]) end
		local closed = false
		internals.close_session(other, function(err) assert(not err); closed = true end)
		assert(vim.wait(3000, function() return closed end))
		state.backend = backend
		assert(vim.wait(3000, function() return not state.project.worktrees_refreshing end))
	end)

	test("removing a detached worktree preserves its tip on a local branch", function()
		local detached = directory .. "/detached"
		git("worktree", "add", "--detach", detached, "HEAD")
		git("-C", detached, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "detached work")
		local project = Project.discover(repo)
		local tree = Project.worktree_for(project, detached)
		local err, branch = remove(project, tree)
		assert(not err, err)
		assert(branch:find("worktree/detached-", 1, true) == 1)
		assert(git("rev-parse", "refs/heads/" .. branch) == tree.head)
		assert(vim.fn.isdirectory(detached) == 0)
	end)
end)
vim.notify = notify
vim.fn.delete(directory, "rf")
assert(ok, error)
print("Passed " .. count .. " worktree removal regression tests")
