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
	press("j")
	assert(state.selected_id == "feature-old", "run navigation must stay in the worktree")
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
	state.sidebar_level = "runs"
	press("r")
	assert(vim.deep_equal(actions[4], { "/branch", "restart" }))
	assert(vim.fn.maparg("<C-r>", "n", false, true).callback == mode.resync)
	Docker.supported, Docker.run = supported, run
end)

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

test("Docker restart runs down then up, preserves data, and reports either phase failing", function()
	local system, readable = vim.system, vim.fn.filereadable
	vim.fn.filereadable = function() return 1 end
	for _, failure in ipairs({ "none", "down", "up" }) do
		local calls, replies, cache, reported = {}, {}, {}, nil
		vim.system = function(argv, opts, callback)
			assert(opts.cwd == "/branch")
			assert(#argv == 3 and argv[1] == "python3" and argv[2] == "scripts/dev.py")
			table.insert(calls, argv[3]); table.insert(replies, callback)
		end
		local function restart()
			Docker.run("/branch", "restart", cache, function() end, function(err) reported = err end)
		end
		restart(); restart()
		assert(#calls == 1 and calls[1] == "down")
		assert(Docker.label(cache, "/branch") == "Docker restarting…")
		replies[1]({ code = failure == "down" and 1 or 0, stderr = "down failed" })
		if failure == "down" then
			assert(vim.wait(1000, function() return reported ~= nil end))
			assert(#calls == 1, "do not start after shutdown failed")
		else
			assert(vim.wait(1000, function() return #calls == 2 end))
			assert(calls[2] == "up")
			replies[2]({ code = failure == "up" and 1 or 0, stderr = "up failed" })
			assert(vim.wait(1000, function() return not cache.actions["/branch"] end))
			assert((reported ~= nil) == (failure == "up"))
		end
		assert(not cache.actions["/branch"] and not cache.checked)
	end
	vim.system, vim.fn.filereadable = system, readable
end)

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
