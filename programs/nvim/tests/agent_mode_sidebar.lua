-- nvim --headless -u NONE -i NONE -l programs/nvim/tests/agent_mode_sidebar.lua
local root = vim.fn.getcwd() .. "/programs/nvim/lua/agent_mode/"
for _, name in ipairs({ "backend", "history", "identity", "project", "sidebar", "docker" }) do
	package.preload["config.agent_mode." .. name] = function() return dofile(root .. name .. ".lua") end
end
local Project = require("config.agent_mode.project")
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
state.opts = { sidebar_width = 40 }
state.sidebar_buf = vim.api.nvim_create_buf(false, true)
state.sidebar_win = vim.api.nvim_open_win(state.sidebar_buf, true, {
	relative = "editor", row = 0, col = 0, width = 40, height = 20, style = "minimal",
})
local function press(key) vim.fn.maparg(key, "n", false, true).callback() end
local previews, opened = 0, nil
mode.preload_selected = function() previews = previews + 1 end
mode.open_selected = function() opened = state.selected_id end
local count = 0
local function test(name, fn)
	fn()
	count = count + 1
	print("ok " .. count .. " - " .. name)
end
local function setup(worktrees)
	state.project = { worktrees = worktrees, current_worktree = worktrees[1].path }
	state.sidebar_level, state.sidebar_worktree, state.sidebar_action = nil, nil, 1
	state.selected_id, state.threads, state.order = nil, {}, {}
	state.recents_tab = "active"
	state.search, state.search_term = nil, nil
	state.selected_ids = {}
	internals.sidebar_mappings()
end
local function add(id, cwd, time)
	state.threads[id] = { id = id, cwd = cwd, preview = id, updatedAt = time or 100 }
end

test("worktrees are the default, Enter drills into runs, and Esc returns", function()
	setup({ { path = "/repo", label = "main" }, { path = "/branch", label = "feature" }, { path = "/empty" } })
	add("main-run", "/repo", 300)
	add("feature-new", "/branch/subdir", 200)
	add("feature-old", "/branch", 100)
	internals.sort_threads()
	internals.render_sidebar()
	assert(state.sidebar_level == "worktrees" and vim.tbl_count(state.cursor_rows) == 3)
	for _, width in ipairs({ 24, 40 }) do
		vim.api.nvim_win_set_width(state.sidebar_win, width)
		internals.render_sidebar()
		local lines = vim.api.nvim_buf_get_lines(state.sidebar_buf, 0, -1, false)
		local inside, boxes = false, 0
		for _, line in ipairs(lines) do
			if line:find("╭", 1, true) == 1 then inside = true end
			if inside then assert(vim.fn.strdisplaywidth(line) == width, "borders must align") end
			if line:find("╰", 1, true) == 1 then inside, boxes = false, boxes + 1 end
		end
		assert(boxes == 3)
		for _, row in pairs(state.cursor_rows) do
			assert(lines[row]:find("│  ● ", 1, true) == 1, "runs must be indented inside their border")
		end
	end
	press("j")
	assert(state.sidebar_worktree == "/branch" and previews == 0)
	press("<CR>")
	assert(state.sidebar_level == "runs" and state.selected_id == "feature-new")
	assert(state.cursor_rows["feature-new"] and state.cursor_rows["main-run"])
	press("j")
	assert(state.selected_id == "feature-old")
	press("k")
	press("<CR>")
	assert(opened == "feature-new")
	press("<Esc>")
	assert(state.sidebar_level == "worktrees" and state.sidebar_worktree == "/branch")
	assert(vim.tbl_count(state.cursor_rows) == 3, "Esc must keep every worktree expanded")
	press("G")
	assert(state.sidebar_worktree == "/empty")
	press("<CR>")
	assert(state.sidebar_level == "runs" and state.selected_id == nil)
	internals.sort_threads(); internals.render_sidebar()
	assert(state.sidebar_worktree == "/empty" and state.selected_id == nil, "sync must preserve an empty worktree")
	press("<Esc>")
	press("gg")
	assert(state.sidebar_worktree == "/repo")
end)

for _, keys in ipairs({ { "k", "j" }, { "<Up>", "<Down>" } }) do
	for _, direction in ipairs({ -1, 1 }) do
		test("run boundaries return to worktree browsing with " .. keys[direction == -1 and 1 or 2], function()
			setup({ { path = "/repo" }, { path = "/branch" }, { path = "/last" } })
			add("main-run", "/repo", 400)
			add("feature-new", "/branch", 300); add("feature-old", "/branch", 200)
			add("last-run", "/last", 100)
			internals.sort_threads(); internals.render_sidebar()
			press("j"); press("<CR>")
			press(direction == -1 and "gg" or "G")
			local selected = direction == -1 and "feature-new" or "feature-old"
			assert(state.sidebar_level == "runs" and state.selected_id == selected)
			local before, previously_opened, target = previews, opened, state.new_target
			press(keys[direction == -1 and 1 or 2])
			local path = direction == -1 and "/repo" or "/last"
			assert(state.sidebar_level == "worktrees" and state.sidebar_worktree == path)
			assert(vim.api.nvim_win_get_cursor(state.sidebar_win)[1] == state.group_rows[path])
			assert(state.selected_id == selected and state.new_target == target)
			assert(previews == before and opened == previously_opened, "do not preview or open a neighboring run")
			assert(vim.api.nvim_get_current_win() == state.sidebar_win, "keep sidebar focus")
			press(keys[direction == -1 and 2 or 1])
			assert(state.sidebar_level == "worktrees" and state.sidebar_worktree == "/branch")
			assert(previews == before, "subsequent movement must browse worktrees")
			press("<CR>")
			assert(state.sidebar_level == "runs" and state.selected_id == "feature-new")
		end)
	end
end

test("outer and empty run boundaries return to clamped worktree selection", function()
	setup({ { path = "/repo" }, { path = "/empty" } })
	add("main-run", "/repo")
	internals.sort_threads(); internals.render_sidebar()
	press("<CR>"); press("k")
	assert(state.sidebar_level == "worktrees" and state.sidebar_worktree == "/repo")
	press("j"); press("<CR>"); press("j")
	assert(state.sidebar_level == "worktrees" and state.sidebar_worktree == "/empty")
	press("<CR>"); press("k")
	assert(state.sidebar_level == "worktrees" and state.sidebar_worktree == "/repo")
	setup({ { path = "/repo" } })
	add("only-run", "/repo")
	internals.sort_threads(); internals.render_sidebar()
	press("j")
	assert(state.sidebar_level == "worktrees" and state.sidebar_worktree == "/repo")
end)

test("single worktrees navigate runs immediately; hovering the header exposes controls", function()
	setup({ { path = "/repo" } })
	add("a", "/repo", 200); add("b", "/repo", 100)
	internals.sort_threads(); internals.render_sidebar()
	assert(state.sidebar_level == "runs")
	press("j")
	assert(state.selected_id == "b")
	internals.select_sidebar_row(state.group_rows["/repo"])
	assert(state.sidebar_level == "worktrees" and internals.selected_thread() == nil)
	press("<CR>")
	assert(state.sidebar_level == "runs")
end)

test("Docker actions cycle and target only the selected worktree", function()
	setup({ { path = "/repo" }, { path = "/branch" } })
	local supported, run = Docker.supported, Docker.run
	Docker.supported = function() return true end
	state.docker = { checked = os.time(), worktrees = {} }
	local actions = {}
	Docker.run = function(path, action) table.insert(actions, { path, action }) end
	internals.render_sidebar()
	press("j"); press("l"); press("<CR>")
	assert(vim.deep_equal(actions[1], { "/branch", "up" }))
	assert(state.sidebar_level == "worktrees")
	press("l"); press("<CR>")
	assert(vim.deep_equal(actions[2], { "/branch", "down" }))
	press("l"); assert(state.sidebar_action == 1)
	press("h"); assert(state.sidebar_action == 3)
	press("r")
	assert(vim.deep_equal(actions[3], { "/branch", "restart" }))
	press("d")
	assert(vim.deep_equal(actions[4], { "/branch", "down" }))
	state.project.removing_worktree = "/branch"
	press("d")
	assert(#actions == 4, "do not stop Docker while removing the worktree")
	state.project.removing_worktree = nil
	Docker.supported = function() return false end
	press("d")
	assert(#actions == 4, "Docker down is only available for supported projects")
	Docker.supported = function() return true end
	state.sidebar_level = "runs"
	press("r")
	assert(vim.deep_equal(actions[5], { "/branch", "restart" }))
	assert(vim.fn.maparg("<C-r>", "n", false, true).callback == mode.resync)
	Docker.supported, Docker.run = supported, run
end)

test("restart follows a selected chat row and the focused chat pane's own worktree", function()
	setup({ { path = "/repo" }, { path = "/branch" } })
	add("main-chat", "/repo", 200); add("branch-chat", "/branch/subdir", 100)
	local supported, run, resync = Docker.supported, Docker.run, mode.resync
	Docker.supported = function() return true end
	state.docker = { checked = os.time(), worktrees = {} }
	local actions = {}
	Docker.run = function(path, action) table.insert(actions, { path, action }) end
	internals.sort_threads(); internals.render_sidebar()
	internals.select_sidebar_row(state.cursor_rows["branch-chat"])
	press("r")
	assert(vim.deep_equal(actions[1], { "/branch", "restart" }))
	internals.select_sidebar_row(state.group_rows["/repo"])

	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor", row = 0, col = 42, width = 30, height = 10, style = "minimal",
	})
	local session = { buf = buf, cwd = "/branch/subdir", initial_load_complete = true }
	local timeout = state.opts.preview_loading_timeout
	state.opts.preview_loading_timeout = 1000
	internals.configure_terminal_buffer(session)
	state.opts.preview_loading_timeout = timeout
	press("r")
	assert(vim.deep_equal(actions[2], { "/branch", "restart" }), "use the chat's cwd, not the sidebar header")
	assert(vim.fn.maparg("r", "t") == "", "typing r in a chat must remain ordinary input")
	state.project.removing_worktree = "/branch"
	press("r"); assert(#actions == 2, "do not restart a worktree being removed")
	state.project.removing_worktree = nil
	session.cwd = "/unknown"
	press("r"); assert(#actions == 2, "do not fall back to an unrelated worktree")
	local synced = false
	Docker.supported = function() return false end
	mode.resync = function() synced = true end
	press("r"); assert(synced and #actions == 2)
	vim.api.nvim_win_close(win, true)
	vim.api.nvim_buf_delete(buf, { force = true })
	vim.api.nvim_set_current_win(state.sidebar_win)
	Docker.supported, Docker.run, mode.resync = supported, run, resync
end)

test("o opens the selected worktree from its header or a chat inside it", function()
	setup({ { path = "/repo" }, { path = "/branch" } })
	add("branch-chat", "/branch/subdir")
	local supported, open = Docker.supported, Docker.open
	Docker.supported = function() return true end
	state.docker = { checked = os.time(), worktrees = {} }
	local paths = {}
	Docker.open = function(_, path) table.insert(paths, path) end
	internals.sort_threads(); internals.render_sidebar()
	internals.select_sidebar_row(state.group_rows["/branch"])
	press("o")
	internals.select_sidebar_row(state.cursor_rows["branch-chat"])
	press("o")
	assert(vim.deep_equal(paths, { "/branch", "/branch" }))
	state.project.removing_worktree = "/branch"
	press("o"); assert(#paths == 2)
	state.project.removing_worktree = nil
	Docker.supported = function() return false end
	press("o"); assert(#paths == 2)
	Docker.supported, Docker.open = supported, open
end)

test("b rebuilds the selected worktree from its header or a chat inside it", function()
	setup({ { path = "/repo" }, { path = "/branch" } })
	add("branch-chat", "/branch/subdir")
	local supported, run = Docker.supported, Docker.run
	Docker.supported = function() return true end
	state.docker = { checked = os.time(), worktrees = {} }
	local paths = {}
	Docker.run = function(path, action, _, _, _, _, args)
		assert(action == "restart" and vim.deep_equal(args, { "--build" }))
		table.insert(paths, path)
	end
	internals.sort_threads(); internals.render_sidebar()
	internals.select_sidebar_row(state.group_rows["/branch"])
	press("b")
	internals.select_sidebar_row(state.cursor_rows["branch-chat"])
	press("b")
	assert(vim.deep_equal(paths, { "/branch", "/branch" }))
	state.project.removing_worktree = "/branch"
	press("b"); assert(#paths == 2)
	state.project.removing_worktree = nil
	Docker.supported = function() return false end
	press("b"); assert(#paths == 2)
	Docker.supported, Docker.run = supported, run
end)

for _, scenario in ipairs({ "running", "stopped", "partial", "startup failure", "query failure", "missing port" }) do
	test("browser opening handles " .. scenario, function()
		local system, readable, supported, open = vim.system, vim.fn.filereadable, Docker.supported, vim.ui.open
		Docker.supported = function() return true end
		vim.fn.filereadable = function() return 1 end
		local pending, opened, errors, cache = {}, {}, {}, {}
		vim.system = function(argv, opts, callback)
			table.insert(pending, { argv = argv, opts = opts, reply = callback })
		end
		vim.ui.open = function(url) table.insert(opened, url) end
		local function request()
			Docker.open({}, "/branch", cache, function() end, function(err) table.insert(errors, err) end)
		end
		local function runtime(port, partial)
			local output = vim.json.encode({ directory = "/branch", files = "docker-compose.override.yml",
				service = "web", state = "running", ports = "127.0.0.1:" .. port .. "->8000/tcp" })
			if partial then output = output .. "\n" .. vim.json.encode({ directory = "/branch",
				files = "docker-compose.override.yml", service = "db", state = "exited" }) end
			return output
		end
		request(); request()
		assert(#pending == 1 and pending[1].argv[1] == "docker", "coalesce open requests")
		pending[1].reply({ code = scenario == "query failure" and 1 or 0,
			stdout = scenario == "running" and runtime("8100") or scenario == "partial" and runtime("8100", true) or "" })
		assert(vim.wait(1000, function() return #pending == 2 or not cache.opening["/branch"] end))
		if scenario ~= "running" and scenario ~= "query failure" then
			assert(#opened == 0, "wait for startup")
			assert(vim.deep_equal(pending[2].argv, { "python3", "scripts/dev.py", "up" }))
			assert(pending[2].opts.cwd == "/branch")
			pending[2].reply({ code = scenario == "startup failure" and 1 or 0, stderr = "startup failed" })
			assert(vim.wait(1000, function() return #pending == 3 or not cache.opening["/branch"] end))
			if scenario ~= "startup failure" then
				pending[3].reply({ code = 0, stdout = scenario == "missing port" and "" or runtime("8101") })
			end
		end
		assert(vim.wait(1000, function() return not cache.opening["/branch"] end))
		if scenario == "running" or scenario == "stopped" or scenario == "partial" then
			assert(vim.deep_equal(opened, { "http://localhost:" .. (scenario == "running" and "8100" or "8101") }))
			assert(#errors == 0)
		else
			assert(#opened == 0 and #errors == 1)
		end
		vim.system, vim.fn.filereadable, Docker.supported, vim.ui.open = system, readable, supported, open
	end)
end

test("runtime Docker state distinguishes running, partial, down, and errors, and refreshes ports", function()
	local system, supported = vim.system, Docker.supported
	Docker.supported = function() return true end
	local calls, reply = 0
	vim.system = function(argv, opts, callback)
		calls = calls + 1
		assert(argv[1] == "docker" and argv[2] == "ps" and opts.timeout == 4000)
		reply = callback
	end
	local cache, updates = {}, 0
	local function refresh() Docker.refresh({}, cache, function() updates = updates + 1 end) end
	local function container(service, status, port, detail)
		return vim.json.encode({ directory = "/branch", files = "/branch/docker-compose.override.yml",
			service = service, state = status, status = detail, ports = port and "127.0.0.1:" .. port .. "->8000/tcp" or "" })
	end
	refresh(); refresh(); assert(calls == 1)
	reply({ code = 0, stdout = container("web", "running", "8100") .. "\n" .. container("db", "exited") })
	assert(vim.wait(1000, function() return updates == 1 end))
	assert(Docker.label(cache, "/branch") == "Docker partial · localhost:8100")
	refresh(); assert(calls == 1, "coalesce frequent redraws")
	cache.checked = 0; refresh()
	reply({ code = 0, stdout = container("web", "running", "8101") .. "\n"
		.. container("djangosetup", "exited", nil, "Exited (0) 2 minutes ago") })
	assert(vim.wait(1000, function() return updates == 2 end))
	assert(Docker.label(cache, "/branch") == "Docker running · localhost:8101")
	cache.checked = 0; refresh(); reply({ code = 0, stdout = "" })
	assert(vim.wait(1000, function() return updates == 3 end))
	assert(Docker.label(cache, "/branch") == "Docker down")
	cache.checked = 0; refresh(); reply({ code = 1, stderr = "no daemon" })
	assert(vim.wait(1000, function() return updates == 4 end))
	assert(Docker.label(cache, "/branch") == "Docker unavailable", "failure must not imply down")
	vim.system, Docker.supported = system, supported
end)

test("Docker launcher is asynchronous, preserves data, and allows retry after failure", function()
	local system, readable = vim.system, vim.fn.filereadable
	local reply, calls, reported = nil, 0, nil
	vim.fn.filereadable = function() return 1 end
	vim.system = function(argv, opts, callback)
		assert(vim.deep_equal(argv, { "python3", "scripts/dev.py", "down" }))
		assert(opts.cwd == "/branch")
		calls, reply = calls + 1, callback
	end
	local cache = {}
	local function run() Docker.run("/branch", "down", cache, function() end, function(err) reported = err end) end
	run(); run(); assert(calls == 1)
	assert(Docker.label(cache, "/branch") == "Docker stopping…")
	reply({ code = 1, stderr = "failed" })
	assert(vim.wait(1000, function() return reported ~= nil end))
	assert(not cache.actions["/branch"] and not cache.checked)
	run(); assert(calls == 2)
	reply({ code = 0 })
	assert(vim.wait(1000, function() return cache.actions["/branch"] == nil end))
	vim.system, vim.fn.filereadable = system, readable
end)

for _, variant in ipairs({ { true, false }, { false, false }, { true, true }, { false, true } }) do
	local initialized, build = unpack(variant)
	test("Docker restart delegates to the launcher and permits retry (saved state: " .. tostring(initialized)
		.. ", build: " .. tostring(build) .. ")", function()
		local system, readable = vim.system, vim.fn.filereadable
		vim.fn.filereadable = function(path)
			assert(path == "/branch/scripts/dev.py" or path == "/branch/.env.worktree")
			return (path == "/branch/scripts/dev.py" or initialized) and 1 or 0
		end
		local calls, reply, cache, reported = 0, nil, {}, nil
		vim.system = function(argv, opts, callback)
			local expected = { "python3", "scripts/dev.py", "restart" }
			if build then table.insert(expected, "--build") end
			assert(vim.deep_equal(argv, expected))
			assert(opts.cwd == "/branch")
			calls, reply = calls + 1, callback
		end
		local function restart()
			Docker.run("/branch", "restart", cache, function() end, function(err) reported = err end,
				nil, build and { "--build" } or nil)
		end
		restart(); restart()
		assert(calls == 1 and Docker.label(cache, "/branch") == "Docker restarting…")
		reply({ code = 1, stderr = "port is already allocated" })
		assert(vim.wait(1000, function() return reported ~= nil end))
		assert(reported:find("port is already allocated", 1, true))
		assert(not cache.actions["/branch"] and not cache.checked)
		reported = nil
		restart(); assert(calls == 2)
		reply({ code = 0 })
		assert(vim.wait(1000, function() return not cache.actions["/branch"] end))
		assert(not reported and not cache.checked)
		vim.system, vim.fn.filereadable = system, readable
	end)
end

test("auto-sync discovers added/removed worktrees and branch changes while preserving selection", function()
	local directory = vim.fn.tempname()
	vim.fn.mkdir(directory, "p")
	local function git(...)
		local result = vim.system(vim.list_extend({ "git", "-C", directory }, { ... }), { text = true }):wait()
		assert(result.code == 0, result.stderr)
	end
	git("init", "-b", "main")
	git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "test")
	state.project = Project.discover(directory)
	state.sidebar_level, state.sidebar_worktree = nil, nil
	state.threads, state.order = {}, {}
	state.backend_ready = false
	state.selected_ids = {}
	local branch = directory .. "-branch"
	git("worktree", "add", "-b", "feature", branch)
	local function sync()
		internals.refresh_project_state()
		assert(vim.wait(1000, function() return not state.project.worktrees_refreshing end))
	end
	sync()
	assert(#state.project.worktrees == 2 and state.sidebar_level == "worktrees")
	state.sidebar_worktree, state.new_target = branch, 2
	state.threads.a = { id = "a", cwd = branch, updatedAt = 1 }
	state.selected_id = "a"
	sync()
	assert(state.sidebar_worktree == branch and state.new_target == 2 and state.selected_id == "a")
	git("branch", "-m", "feature", "renamed")
	sync()
	assert(state.project.worktrees[2].label == "renamed")
	git("worktree", "remove", branch)
	sync()
	assert(#state.project.worktrees == 1 and state.sidebar_level == "runs")
	assert(state.sidebar_worktree == directory and state.new_target == 1 and #state.order == 0)
	vim.fn.delete(directory, "rf")
end)

test("late worktree sync replies cannot overwrite another project, and errors retain the last list", function()
	setup({ { path = "/repo" }, { path = "/branch" } })
	local refresh = Project.refresh_worktrees
	local reply
	Project.refresh_worktrees = function(_, callback) reply = callback end
	internals.refresh_project_state()
	state.project = { worktrees = { { path = "/elsewhere" } } }
	reply({ { path = "/stale" } })
	assert(state.project.worktrees[1].path == "/elsewhere")
	internals.refresh_project_state()
	reply(nil, "failed")
	assert(state.project.worktrees[1].path == "/elsewhere" and state.worktree_sync_error == "failed")
	Project.refresh_worktrees = refresh
end)
print("Passed " .. count .. " sidebar regression tests")
