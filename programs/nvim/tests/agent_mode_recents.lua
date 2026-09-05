-- Run from the repository root:
-- nvim --headless -u NONE -i NONE -l programs/nvim/tests/agent_mode_recents.lua
local root = vim.fn.getcwd() .. "/programs/nvim/lua/agent_mode/"
for _, name in ipairs({ "backend", "history", "identity", "project" }) do
	package.preload["config.agent_mode." .. name] = function()
		return dofile(root .. name .. ".lua")
	end
end
local Backend = require("config.agent_mode.backend")
local Identity = require("config.agent_mode.identity")
local mode = dofile(root .. "init.lua")

-- Reach the event handlers without starting a real CLI or exporting test APIs.
local internals, visited = {}, {}
local function inspect(fn)
	if visited[fn] then
		return
	end
	visited[fn] = true
	for index = 1, math.huge do
		local name, value = debug.getupvalue(fn, index)
		if not name then
			break
		end
		internals[name] = value
		if type(value) == "function" then
			inspect(value)
		end
	end
end
for _, fn in pairs(mode) do
	if type(fn) == "function" then
		inspect(fn)
	end
end
local state = assert(internals.state)
local refresh = assert(internals.refresh_threads)
local notify = assert(internals.process_notification)
local initial = vim.deepcopy(state)
local real_defer = vim.defer_fn
vim.defer_fn = function() end -- Each test explicitly drives refreshes.

local function reset()
	if state.composer then
		internals.hide_composer()
		for _, buf in ipairs({ state.composer.buf, state.composer.background_buf }) do
			if vim.api.nvim_buf_is_valid(buf) then
				vim.api.nvim_buf_delete(buf, { force = true })
			end
		end
	end
	for _, session in pairs(state.sessions) do
		for _, name in ipairs({ "quiet_timer", "status_timer", "startup_timer" }) do
			if session[name] then
				session[name]:stop()
				session[name]:close()
			end
		end
		if session.buf and vim.api.nvim_buf_is_valid(session.buf) then
			vim.api.nvim_buf_delete(session.buf, { force = true })
		end
	end
	for key in pairs(state) do
		state[key] = nil
	end
	for key, value in pairs(vim.deepcopy(initial)) do
		state[key] = value
	end
	state.opts = { preview_loading_timeout = 5000 }
	state.project = { launch_cwd = "/repo", worktrees = { { path = "/repo" } } }
	state.backend_ready = true
end

local function thread(id, preview, extra)
	return vim.tbl_extend("force", {
		id = id, preview = preview or "hello", cwd = "/repo", source = "cli",
		threadSource = "user", createdAt = 100, updatedAt = 101,
	}, extra or {})
end

local function pending(key, prompt)
	local session = {
		key = key, initial_prompt = prompt or "hello", cwd = "/repo",
		started_at = 100, known_ids = {}, notify_token = key,
		local_status = "working", display_status = "working", activity_at = 123,
	}
	state.sessions[key] = session
	state.session_tokens[key] = session
	state.threads[key] = thread(key, prompt, { _activity_at = 123 })
	return session
end

local function listing(threads)
	state.backend = {
		list_threads = function(_, params, callback)
			assert(params.searchTerm == nil, "UI search must not restrict identity discovery")
			callback(nil, vim.deepcopy(threads))
		end,
	}
end

local function completion(id, token)
	notify({ type = "agent-turn-complete", ["thread-id"] = id, cwd = "/repo" }, token)
end

local count = 0
local function test(name, fn)
	reset()
	fn()
	count = count + 1
	print("ok " .. count .. " - " .. name)
end

for _, scenario in ipairs({
	{ name = "normal mode with an older selection", mapping = "n", selected = "older" },
	{ name = "insert mode with the first row already selected", mapping = "i", selected = "first" },
	{ name = "an empty recents list", mapping = "n", empty = true },
	{ name = "an existing chat with a saved draft", existing = true, selected = "older" },
}) do
	test("Escape focuses recents from " .. scenario.name, function()
		vim.cmd("tabnew")
		state.chat_win = vim.api.nvim_get_current_win()
		local buffers = {}
		local function buffer()
			local buf = vim.api.nvim_create_buf(false, true)
			table.insert(buffers, buf)
			return buf
		end
		state.composer = { buf = buffer(), background_buf = buffer() }
		vim.api.nvim_buf_set_lines(state.composer.buf, 0, -1, false, { "unfinished draft" })
		vim.api.nvim_win_set_buf(state.chat_win, state.composer.background_buf)
		vim.cmd("vsplit")
		state.sidebar_win = vim.api.nvim_get_current_win()
		state.sidebar_buf = buffer()
		vim.api.nvim_win_set_buf(state.sidebar_win, state.sidebar_buf)
		if not scenario.empty then
			state.threads = { first = thread("first", nil, { updatedAt = 200 }), older = thread("older") }
			state.selected_id = scenario.selected
			internals.sort_threads()
			for id in pairs(state.threads) do
				state.sessions[id] = { id = id, buf = buffer(), job_id = 123, initial_load_complete = true }
			end
		end
		internals.render_sidebar()
		if scenario.existing then
			state.active_id = "older"
			vim.api.nvim_win_set_buf(state.chat_win, state.sessions.older.buf)
			vim.api.nvim_set_current_win(state.chat_win)
		else
			state.composer.win = vim.api.nvim_open_win(state.composer.buf, true, {
				relative = "editor", row = 2, col = 2, width = 20, height = 2, style = "minimal",
			})
			internals.composer_mappings(state.composer.buf)
		end
		local jobwait = vim.fn.jobwait
		vim.fn.jobwait = function() return { -1 } end
		local ok, err = pcall(function()
			if scenario.existing then
				mode.focus_recents()
			else
				local mapping = vim.fn.maparg("<Esc>", scenario.mapping, false, true)
				mapping.callback()
			end
			assert(vim.wait(1000, function() return vim.api.nvim_get_current_win() == state.sidebar_win end))
			if not scenario.empty then
				local expected = scenario.existing and "older" or "first"
				assert(state.selected_id == expected and state.active_id == expected)
				assert(vim.api.nvim_win_get_buf(state.chat_win) == state.sessions[expected].buf)
				assert(not state.composer.win, "the new-chat prompt must be hidden")
				assert(vim.api.nvim_win_get_cursor(state.sidebar_win)[1] == state.cursor_rows[expected])
			end
			assert(vim.api.nvim_buf_get_lines(state.composer.buf, 0, -1, false)[1] == "unfinished draft")
		end)
		vim.fn.jobwait = jobwait
		vim.cmd("tabclose!")
		for _, buf in ipairs(buffers) do
			if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
		end
		assert(ok, err)
	end)
end

test("remote terminals receive their own project directory for new and resumed chats", function()
	local directory = vim.fn.tempname()
	vim.fn.mkdir(directory, "p")
	local cli = directory .. "/cli.sh"
	vim.fn.writefile({
		'cwd=/shared-daemon-project',
		'while [ "$#" -gt 0 ]; do',
		'  case "$1" in --cd) cwd=$2; shift;; esac',
		'  shift',
		'done',
		'printf "%s\\n" "$cwd" > received-cwd',
		"printf '› Ask Codex to do anything\\n'",
		'sleep 2',
	}, cli)
	state.opts.command = { vim.fn.exepath("sh"), cli }
	state.chat_win = vim.api.nvim_get_current_win()
	local sessions = {}
	local ok, err = pcall(function()
		for _, project in ipairs({ "project a", "project b" }) do
			for _, kind in ipairs({ "new", "resume" }) do
				local cwd = directory .. "/" .. project .. "/" .. kind
				vim.fn.mkdir(cwd, "p")
				local key = project .. kind
				local id = kind == "resume" and key or nil
				local session = internals.create_terminal(id, cwd, key, id, kind == "new")
				table.insert(sessions, session)
				assert(vim.wait(1000, function() return vim.fn.filereadable(cwd .. "/received-cwd") == 1 end))
				assert(vim.fn.readfile(cwd .. "/received-cwd")[1] == cwd,
					"remote " .. kind .. " must use " .. project .. ", not the daemon's directory")
			end
		end
	end)
	for _, session in ipairs(sessions) do
		state.session_tokens[session.notify_token] = nil
		vim.fn.jobstop(session.job_id)
		vim.fn.jobwait({ session.job_id }, 1000)
	end
	vim.fn.delete(directory, "rf")
	assert(ok, err)
end)

test("both recents tabs exclude rows from another project even between refreshes", function()
	state.threads.local_chat = thread("local_chat")
	state.threads.foreign = thread("foreign", nil, { cwd = "/other-project" })
	state.dismissed_threads.local_old = thread("local_old")
	state.dismissed_threads.foreign_old = thread("foreign_old", nil, { cwd = "/other-project" })
	state.selected_id = "foreign"
	internals.sort_threads()
	assert(#state.active_order == 1 and state.active_order[1].id == "local_chat")
	assert(#state.dismissed_order == 1 and state.dismissed_order[1].id == "local_old")
	assert(state.selected_id == "local_chat")
end)

test("a delayed restore from another project cannot select or open its chat", function()
	local reply
	state.backend = { unarchive_thread = function(_, _, callback) reply = callback end }
	local old = thread("old")
	state.dismissed_threads.old = old
	local opened = false
	internals.restore_thread(old, function() opened = true end)
	state.project = { launch_cwd = "/other-project", worktrees = { { path = "/other-project" } } }
	state.threads = { current = thread("current", nil, { cwd = "/other-project" }) }
	state.dismissed_threads = {}
	state.selected_id = "current"
	reply(nil, { thread = old })
	assert(not state.threads.old and not opened)
	assert(state.selected_id == "current")
end)

local ui_status = assert(internals.terminal_ui_status)
local finish_load = assert(internals.finish_initial_load)
local attach_activity = assert(internals.attach_terminal_activity)
local status_name = assert(internals.status_name)

for _, fresh in ipairs({ true, false }) do
	test((fresh and "new chats default to working" or "existing chats default to ready") .. " through startup", function()
		state.chat_win = vim.api.nvim_get_current_win()
		state.opts.command = { vim.fn.exepath("sh"), "-c", "printf '› Ask Codex to do anything\\n'; sleep 2" }
		local key = fresh and "pending-1" or "chat"
		state.threads[key] = thread(key)
		local resume_id
		if not fresh then resume_id = "chat" end
		local session = internals.create_terminal(resume_id, vim.fn.getcwd(), key, resume_id, fresh)
		local ok, err = pcall(function()
			assert(session.job_id > 0)
			local expected = fresh and "working" or "ready"
			assert(status_name(state.threads[key]) == expected)
			assert(vim.wait(1000, function() return session.initial_load_complete end))
			assert(status_name(state.threads[key]) == expected, "revealing the prompt must preserve the default")
			if fresh then
				local saved = thread("saved", nil, { status = { type = "notLoaded" } })
				state.threads.saved = saved
				internals.bind_session(session, saved, true)
				assert(status_name(saved) == "working", "identity discovery must preserve the default")
				internals.handle_backend_notification("thread/status/changed", {
					threadId = "saved", status = { type = "idle" },
				})
				assert(status_name(saved) == "ready")
				listing({ thread("saved", nil, { status = { type = "notLoaded" } }) })
				refresh()
				assert(status_name(state.threads.saved) == "ready", "completion must retire the working default")
			end
		end)
		state.session_tokens[session.notify_token] = nil
		vim.fn.jobstop(session.job_id)
		vim.fn.jobwait({ session.job_id }, 1000)
		assert(ok, err)
	end)
end

test("empty recents stay stable during refreshes of either tab", function()
	state.opts.sidebar_width = 40
	state.sidebar_buf = vim.api.nvim_create_buf(false, true)
	local callbacks = {}
	state.backend = { list_threads = function(_, params, callback)
		callbacks[params.archived and "dismissed" or "active"] = callback
	end }
	local ok, err = pcall(function()
		for _, tab in ipairs({ "active", "dismissed" }) do
			for _, search in ipairs({ false, "missing" }) do
				state.recents_tab = tab
				state.search_term = search or nil
				internals.render_sidebar()
				local before = vim.api.nvim_buf_get_lines(state.sidebar_buf, 0, -1, false)
				assert(before[search and 6 or 4] == "  No " .. (search and "matching " or "") .. tab .. " conversations")
				local function unchanged()
					internals.render_sidebar()
					assert(vim.deep_equal(before, vim.api.nvim_buf_get_lines(state.sidebar_buf, 0, -1, false)))
				end
				refresh()
				unchanged()
				internals.refresh_dismissed_threads()
				unchanged()
				callbacks.active(nil, {})
				unchanged()
				callbacks.dismissed(nil, {})
				unchanged()
			end
		end
	end)
	vim.api.nvim_buf_delete(state.sidebar_buf, { force = true })
	assert(ok, err)
end)

local function terminal_session(lines)
	local session = pending("chat")
	session.id = "chat"
	session.frontend_status = "loading"
	session.initial_load_complete = false
	session.buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, lines)
	state.threads.chat._local_status = "loading"
	state.threads.chat.status = { type = "idle" }
	return session
end

test("restoration clears loading and preserves authoritative runtime status", function()
	for _, status in ipairs({
		{ type = "idle" },
		{ type = "active", activeFlags = {} },
		{ type = "active", activeFlags = { "waitingOnApproval" } },
	}) do
		local session = terminal_session({ "› Ask Codex to do anything" })
		state.threads.chat.status = status
		finish_load(session)
		assert(session.initial_load_complete and session.frontend_status == nil)
		assert(state.threads.chat._local_status == nil)
		local expected = status.type == "idle" and "ready"
			or (#status.activeFlags > 0 and "approval" or "working")
		assert(status_name(state.threads.chat) == expected)
		assert(not session.unread and state.threads.chat._activity_at == 123)
		vim.api.nvim_buf_delete(session.buf, { force = true })
	end
end)

test("finishing startup preserves terminal failure status", function()
	local session = terminal_session({ "startup failed" })
	session.frontend_status, state.threads.chat._local_status = "error", "error"
	finish_load(session)
	assert(status_name(state.threads.chat) == "error")
end)

test("terminal prompt detection ignores approval prose in completed history", function()
	local session = terminal_session({
		"Would you like to run the following command?", "› 1. Yes, proceed (y)",
		"  Press enter to confirm or esc to cancel", "Finished successfully.",
		"› Ask Codex to do anything", "  ? for shortcuts",
	})
	assert(ui_status(session) == "ready")
end)

test("native approval and input menus are recognized for preview reveal", function()
	local session = terminal_session({
		"› 1. Yes, grant these permissions for this turn (y)",
		"  Press enter to confirm or esc to cancel", "",
	})
	assert(ui_status(session) == "approval")
	vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, {
		"› First option", "  Use tab / ↑ ↓ to move, enter to select, esc to close",
	})
	assert(ui_status(session) == "input")
end)

test("preview detects a prompt that arrived before its listener attached", function()
	local session = terminal_session({ "› Ask Codex to do anything" })
	attach_activity(session)
	assert(vim.wait(1000, function() return session.initial_load_complete end))
	assert(status_name(state.threads.chat) == "ready")
end)

test("preview reveals a prompt arriving after its listener attached", function()
	local session = terminal_session({ "Starting…" })
	attach_activity(session)
	vim.wait(20, function() return session.initial_load_complete end)
	assert(not session.initial_load_complete)
	vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, { "› Ask Codex to do anything" })
	assert(vim.wait(1000, function() return session.initial_load_complete end))
end)

local function with_startup_timeout(callback)
	local timeout
	vim.defer_fn = function(fn, delay)
		assert(delay == state.opts.preview_loading_timeout)
		timeout = fn
	end
	local ok, err = pcall(function()
		local session = terminal_session({ "Please sign in to continue" })
		attach_activity(session)
		assert(timeout)
		callback(session, timeout)
	end)
	vim.defer_fn = function() end
	assert(ok, err)
end

test("unrecognized startup screens become accessible after the timeout", function()
	with_startup_timeout(function(session, timeout)
		state.chat_win = vim.api.nvim_get_current_win()
		state.active_id = "chat"
		timeout()
		assert(session.initial_load_complete and status_name(state.threads.chat) == "ready")
		assert(vim.api.nvim_win_get_buf(state.chat_win) == session.buf)
	end)
end)

test("late startup completion does not replace a different hovered conversation", function()
	with_startup_timeout(function(session, timeout)
		state.chat_win = vim.api.nvim_get_current_win()
		state.active_id = "another-chat"
		local visible = vim.api.nvim_win_get_buf(state.chat_win)
		timeout()
		assert(session.initial_load_complete)
		assert(vim.api.nvim_win_get_buf(state.chat_win) == visible)
	end)
end)

test("startup callbacks ignore replaced sessions and shutdown", function()
	with_startup_timeout(function(session, timeout)
		state.session_tokens[session.notify_token] = nil
		timeout()
		assert(not session.initial_load_complete)
		state.session_tokens[session.notify_token] = session
		state.shutting_down = true
		timeout()
		assert(not session.initial_load_complete)
	end)
end)

test("metadata refresh cannot restore the loading override after preview readiness", function()
	local session = terminal_session({ "› Ask Codex to do anything" })
	finish_load(session)
	local jobwait = vim.fn.jobwait
	session.job_id = 123
	vim.fn.jobwait = function() return { -1 } end
	listing({ thread("chat", "hello", { status = { type = "active", activeFlags = {} } }) })
	local ok, err = pcall(refresh)
	vim.fn.jobwait = jobwait
	assert(ok, err)
	assert(status_name(state.threads.chat) == "working")
end)

local function notification_backend()
	local start = Backend.start
	Backend.start = function() end -- Capture production wiring without a daemon.
	local ok, err = pcall(internals.start_backend)
	Backend.start = start
	assert(ok, err)
	assert(type(state.backend.on_notification) == "function", "backend status handler must be wired")
	return state.backend
end

local function runtime_status(backend, id, status)
	backend:_handle_message({ method = "thread/status/changed", params = { threadId = id, status = status } })
	local delivered = false
	vim.schedule(function() delivered = true end)
	assert(vim.wait(1000, function() return delivered end))
	assert(not backend.last_error, backend.last_error)
end

test("live completion changes working to ready in normal and plan mode", function()
	local backend = notification_backend()
	for _, plan_mode in ipairs({ false, true }) do
		local session = terminal_session({ "› Ask Codex to do anything" })
		session.plan_mode = plan_mode
		finish_load(session)
		runtime_status(backend, "chat", { type = "active", activeFlags = {} })
		assert(status_name(state.threads.chat) == "working")
		completion("chat", session.notify_token)
		assert(status_name(state.threads.chat) == "working", "a turn hook alone cannot finish an agent run")
		runtime_status(backend, "chat", { type = "idle" })
		assert(status_name(state.threads.chat) == "ready")
		assert(session.unread and state.threads.chat._unread)
		assert(session.activity_at == state.threads.chat._activity_at and session.activity_at > 123)
		local activity = session.activity_at
		runtime_status(backend, "chat", { type = "idle" })
		assert(session.activity_at == activity, "duplicate idle events must not reorder recents")
		vim.api.nvim_buf_delete(session.buf, { force = true })
	end
end)

test("live approval and input statuses follow the backend through completion", function()
	local backend = notification_backend()
	state.threads.chat = thread("chat", nil, { status = { type = "active", activeFlags = {} } })
	for _, entry in ipairs({
		{ { type = "active", activeFlags = { "waitingOnApproval" } }, "approval" },
		{ { type = "active", activeFlags = { "waitingOnUserInput" } }, "input" },
		{ { type = "active", activeFlags = {} }, "working" },
		{ { type = "idle" }, "ready" },
		{ { type = "systemError" }, "error" },
	}) do
		runtime_status(backend, "chat", entry[1])
		assert(status_name(state.threads.chat) == entry[2])
	end
end)

test("completion keeps the focused chat read and preserves frontend failure labels", function()
	local backend = notification_backend()
	local session = terminal_session({ "› Ask Codex to do anything" })
	finish_load(session)
	state.chat_win, state.active_id = vim.api.nvim_get_current_win(), "chat"
	runtime_status(backend, "chat", { type = "active", activeFlags = {} })
	runtime_status(backend, "chat", { type = "idle" })
	assert(not session.unread and not state.threads.chat._unread)
	session.frontend_status, state.threads.chat._local_status = "error", "error"
	runtime_status(backend, "chat", { type = "idle" })
	assert(status_name(state.threads.chat) == "error")
end)

test("status events ignore unknown and dismissed chats and shutdown", function()
	local backend = notification_backend()
	state.threads.chat = thread("chat", nil, { status = { type = "active", activeFlags = {} } })
	runtime_status(backend, "helper", { type = "idle" })
	assert(not state.threads.helper)
	state.dismiss_pending.chat = true
	runtime_status(backend, "chat", { type = "idle" })
	assert(status_name(state.threads.chat) == "working")
	state.dismiss_pending.chat = nil
	state.shutting_down = true
	runtime_status(backend, "chat", { type = "idle" })
	assert(status_name(state.threads.chat) == "working")
end)

test("switching threads in an initialized terminal cannot leave a loading override", function()
	local session = terminal_session({ "› Ask Codex to do anything" })
	finish_load(session)
	internals.detach_session_for_switch(session, "resume")
	assert(session.initial_load_complete and session.frontend_status == nil)
	assert(status_name(state.threads[session.key]) ~= "loading")
end)

test("a resumed terminal reveals its prompt and clears the recent loading label", function()
	state.chat_win = vim.api.nvim_get_current_win()
	state.placeholder_buf = vim.api.nvim_create_buf(false, true)
	state.threads.chat = thread("chat", "hello", {
		cwd = vim.fn.getcwd(), status = { type = "idle" },
	})
	state.selected_id = "chat"
	state.opts.command = { vim.fn.exepath("sh"), "-c", "printf '› Ask Codex to do anything\\n'; sleep 2" }
	mode.open_selected(false)
	local session = assert(state.sessions.chat)
	local ok, err = pcall(function()
		assert(session.job_id > 0)
		assert(vim.wait(1000, function() return session.initial_load_complete end))
		assert(vim.api.nvim_win_get_buf(state.chat_win) == session.buf)
		assert(status_name(state.threads.chat) == "ready")
	end)
	state.session_tokens[session.notify_token] = nil
	vim.fn.jobstop(session.job_id)
	vim.fn.jobwait({ session.job_id }, 1000)
	vim.api.nvim_buf_delete(state.placeholder_buf, { force = true })
	assert(ok, err)
end)

test("one refresh cannot bind the same terminal twice", function()
	local session = pending("pending-1")
	state.active_id, state.selected_id = "pending-1", "pending-1"
	state.selected_ids.active = "pending-1"
	listing({ thread("root"), thread("unrelated", "different prompt") })
	refresh()
	assert(session.id == "root")
	assert(state.sessions.root == session and state.sessions.unrelated == nil)
	assert(state.threads["pending-1"] == nil and #state.order == 2)
	assert(state.active_id == "root" and state.selected_ids.active == "root")
	assert(state.threads.root._activity_at == 123)
end)

test("a follow-up before identity discovery still replaces the original temporary row", function()
	local session = pending("pending-1", "original request")
	session.initial_load_complete = true
	session.buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_current_buf(session.buf)
	local prompt = "› follow-up request"
	vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, { prompt })
	vim.api.nvim_win_set_cursor(0, { 1, #prompt - 1 })
	internals.configure_terminal_buffer(session)
	local enter
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(session.buf, "t")) do
		if mapping.lhs == "<CR>" then
			enter = mapping.callback
		end
	end
	assert(enter)()
	listing({ thread("saved", "original request", { status = { type = "active" } }) })
	refresh()
	assert(session.id == "saved", "a follow-up must not erase the original identity evidence")
	assert(#state.order == 1 and not state.threads["pending-1"])
	assert(status_name(state.order[1]) == "working")
end)

test("a reopened saved chat retains one row across follow-ups and delayed refreshes", function()
	local session = terminal_session({ "› Ask Codex to do anything" })
	session.identity_confirmed = true
	finish_load(session)
	state.active_id, state.selected_id = "chat", "chat"
	state.selected_ids.active = "chat"
	for _, kind in ipairs({ "active", "idle", "active", "idle" }) do
		listing({ thread("chat", "original request", { status = { type = kind } }) })
		refresh()
		completion("chat", session.notify_token)
		assert(#state.order == 1 and state.order[1].id == "chat")
		assert(state.sessions.chat == session and session.identity_confirmed)
		assert(status_name(state.order[1]) == (kind == "active" and "working" or "ready"))
	end
end)

test("title changes update the existing row after switching away", function()
	local session = pending("pending-1")
	state.active_id = "another-chat"
	state.search_term = "Generated title"
	listing({ thread("root", "hello", { name = "Generated title" }) })
	refresh()
	assert(session.id == "root" and #state.order == 1)
	assert(state.active_id == "another-chat")
	listing({ thread("root", "hello", { name = "Generated title changed" }) })
	refresh()
	assert(#state.order == 1 and state.order[1].name == "Generated title changed")
	assert(state.sessions.root == session)
end)

test("identical simultaneous prompts wait for verified identity without duplicate rows", function()
	local first = pending("pending-1")
	local second = pending("pending-2")
	local threads = { thread("first"), thread("second") }
	listing(threads)
	refresh()
	assert(not first.id and not second.id and #state.order == 2)
	assert(not state.threads.first and not state.threads.second)
	state.backend.read_thread = function(_, id, callback, options)
		assert(options.summary_only)
		callback(nil, { thread = thread(id) })
	end
	completion("second", "pending-1")
	refresh()
	assert(first.id == "second" and second.id == "first")
	assert(#state.order == 2 and state.threads["pending-1"] == nil and state.threads["pending-2"] == nil)
end)

test("helper finishing first never creates or claims a recent", function()
	local session = pending("pending-1")
	local callback
	state.backend = { read_thread = function(_, _, cb, options)
		assert(options.summary_only)
		callback = cb
	end }
	completion("title-helper", "pending-1")
	assert(not session.id and not state.threads["title-helper"])
	callback(nil, { thread = thread("title-helper", "hello", { ephemeral = true }) })
	assert(not session.id and not state.threads["title-helper"])
	completion("root", "pending-1")
	callback(nil, { thread = thread("root") })
	assert(session.id == "root" and state.threads["pending-1"] == nil)
	completion("title-helper", "pending-1")
	assert(session.id == "root" and not state.threads["title-helper"])
end)

test("failed helper lookup and untagged notifications cannot invent chats", function()
	local session = pending("pending-1")
	state.backend = { read_thread = function(_, _, callback)
		callback("not persisted")
	end }
	completion("helper", "pending-1")
	completion("unknown", nil)
	assert(not session.id and vim.tbl_count(state.threads) == 1)
end)

test("late lookup cannot overwrite a newer association", function()
	local session = pending("pending-1")
	local callback
	listing({ thread("root") })
	state.backend.read_thread = function(_, _, cb) callback = cb end
	completion("older-root", "pending-1")
	refresh()
	callback(nil, { thread = thread("older-root") })
	assert(session.id == "root" and not state.threads["older-root"])
end)

test("a title or timestamp alone cannot identify a terminal", function()
	local session = pending("pending-1", "my actual prompt")
	local matches = Identity.matches(state.sessions, {
		thread("other", "another prompt", { name = session.initial_prompt }),
	})
	assert(#matches == 0)
end)

test("source filtering also excludes CLI helpers and subagents", function()
	assert(Backend.user_visible_thread(thread("root")))
	assert(Backend.user_visible_thread(thread("legacy", nil, { threadSource = vim.NIL })))
	for _, extra in ipairs({
		{ ephemeral = true }, { parentThreadId = "root" },
		{ threadSource = "title_generation" }, { source = { subAgent = "review" } },
		{ source = "appServer", threadSource = vim.NIL },
	}) do
		assert(not Backend.user_visible_thread(thread("helper", nil, extra)))
	end
end)

test("pagination deduplicates canonical IDs", function()
	local backend = Backend.new()
	backend.start = function(_, callback) callback() end
	backend._defer = function(_, callback, ...) callback(...) end
	backend._request = function(_, method, params, callback)
		assert(method == "thread/list")
		if not params.cursor then
			callback(nil, { data = { thread("root") }, nextCursor = "next" })
		else
			callback(nil, { data = { thread("root"), thread("helper", nil, { ephemeral = true }) } })
		end
	end
	backend:list_threads(function(err, threads)
		assert(not err and #threads == 1 and threads[1].id == "root")
	end)
end)


test("list delivery preserves status events received during pagination or callback deferral", function()
	for _, timing in ipairs({ "pagination", "delivery" }) do
		local backend = Backend.new()
		backend.start = function(_, callback) callback() end
		local pages, deferred = {}, {}
		backend._request = function(_, _, _, callback) table.insert(pages, callback) end
		backend._defer = function(_, callback, ...)
			if callback then
				local args = { ... }
				table.insert(deferred, function() callback(unpack(args, 1, 2)) end)
			end
		end
		local result
		backend:list_threads(function(err, threads)
			assert(not err)
			result = threads
		end)
		pages[1](nil, { data = { thread("chat", nil, { status = { type = "active", activeFlags = {} } }) }, nextCursor = "next" })
		local function complete()
			backend:_handle_message({ method = "thread/status/changed", params = { threadId = "chat", status = { type = "idle" } } })
		end
		if timing == "pagination" then complete() end
		pages[2](nil, { data = {} })
		if timing == "delivery" then complete() end
		for _, callback in ipairs(deferred) do callback() end
		assert(result and result[1].status.type == "idle", timing .. " must preserve the newer ready status")

		-- A later poll can recover from a missed event; old cached events must
		-- not mask a snapshot requested after them.
		backend:list_threads(function(err, threads)
			assert(not err)
			result = threads
		end)
		pages[3](nil, { data = { thread("chat", nil, { status = { type = "active", activeFlags = {} } }) } })
		deferred[#deferred]()
		assert(result[1].status.type == "active")
	end
end)

for _, scenario in ipairs({
	{ name = "the last conversation", ids = { "last" } },
	{ name = "all conversations", ids = { "first", "last" }, all = true },
	{ name = "all idle conversations while work continues", ids = { "idle", "working" }, all = true, working = true },
	{ name = "the last conversation with a saved draft", ids = { "last" }, draft = true },
}) do
	test("dismissing " .. scenario.name .. " focuses the centered new-chat prompt", function()
		state.opts.sidebar_width = 24
		state.opts.preview_delay = 1
		internals.create_ui()
		local buffers = { state.placeholder_buf, state.sidebar_buf }
		local ok, err = pcall(function()
			if scenario.draft then
				internals.open_new_chat()
				vim.api.nvim_buf_set_lines(state.composer.buf, 0, -1, false, { "saved draft" })
				internals.hide_composer()
			end
			for _, id in ipairs(scenario.ids) do
				state.threads[id] = thread(id, nil, { status = { type = id == "working" and "active" or "idle" } })
				local buf = vim.api.nvim_create_buf(false, true)
				table.insert(buffers, buf)
				state.sessions[id] = { id = id, key = id, buf = buf, initial_load_complete = true }
			end
			state.selected_id = scenario.ids[1]
			state.active_id = state.selected_id
			vim.api.nvim_win_set_buf(state.chat_win, state.sessions[state.active_id].buf)
			internals.sort_threads()
			internals.render_sidebar()
			local archived = 0
			state.backend = {
				interrupt_thread = function(_, _, callback) callback(nil) end,
				archive_thread = function(_, _, callback) archived = archived + 1; callback(nil) end,
			}
			mode.preload_selected()
			if scenario.all then
				internals.dismiss_all()
			else
				internals.dismiss_thread(state.threads[state.selected_id])
			end
			local expected = #scenario.ids - (scenario.working and 1 or 0)
			assert(vim.wait(1000, function() return archived == expected end))
			vim.wait(20, function() return false end)
			local composer = assert(state.composer)
			assert(state.active_id == nil and not state.auto_open_latest)
			assert(vim.api.nvim_get_current_win() == composer.win)
			assert(vim.api.nvim_win_get_buf(state.chat_win) == composer.background_buf)
			local config = vim.api.nvim_win_get_config(composer.win)
			assert(config.relative == "win" and config.win == state.chat_win)
			assert(config.col == math.max(0, math.floor((vim.api.nvim_win_get_width(state.chat_win) - config.width - 2) / 2)))
			assert(config.row > 0)
			assert(vim.api.nvim_buf_get_lines(composer.buf, 0, -1, false)[1] == (scenario.draft and "saved draft" or ""))
			if scenario.working then assert(state.threads.working) end
		end)
		if state.preview_timer then
			state.preview_timer:stop()
			state.preview_timer:close()
			state.preview_timer = nil
		end
		vim.cmd("stopinsert")
		internals.hide_composer()
		vim.cmd("tabclose!")
		internals.restore_sidebar_cursor()
		for _, buf in ipairs(buffers) do
			if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
		end
		assert(ok, err)
	end)
end

local preload = assert(internals.preload_active_threads)
local function with_preload_spy(callback)
	local slot, original
	for index = 1, math.huge do
		local name, value = debug.getupvalue(preload, index)
		assert(name, "preload must use create_terminal")
		if name == "create_terminal" then
			slot, original = index, value
			break
		end
	end
	local started, scheduled = {}, {}
	local jobwait, defer = vim.fn.jobwait, vim.defer_fn
	vim.fn.jobwait = function() return { -1 } end
	vim.defer_fn = function(fn, delay)
		assert(delay == 250)
		table.insert(scheduled, fn)
	end
	debug.setupvalue(preload, slot, function(id, cwd, key, thread_id)
		assert(id == key and key == thread_id)
		table.insert(started, id)
		local session = { id = id, key = key, cwd = cwd, job_id = 123,
			buf = vim.api.nvim_create_buf(false, true), initial_load_complete = false }
		state.sessions[id] = session
		return session
	end)
	-- Compiled traces can retain the previous test's replaced upvalue.
	jit.flush()
	state.opts.preload_concurrency = 2
	state.chat_win = vim.api.nvim_get_current_win()
	local ok, err = pcall(callback, started, scheduled)
	debug.setupvalue(preload, slot, original)
	jit.flush()
	vim.fn.jobwait, vim.defer_fn = jobwait, defer
	assert(ok, err)
end

local function preload_thread(id, extra)
	local item = thread(id, "saved chat", vim.tbl_extend("force", {
		cwd = vim.fn.getcwd(), status = { type = "notLoaded" },
	}, extra or {}))
	state.threads[id] = item
	table.insert(state.active_order, item)
	return item
end

test("preloading drains the full Active list with bounded startup concurrency", function()
	with_preload_spy(function(started, scheduled)
		for index = 1, 12 do preload_thread("saved-" .. index) end
		state.selected_id, state.active_id = "saved-12", "saved-12"
		local visible = vim.api.nvim_win_get_buf(state.chat_win)
		preload()
		assert(#started == 2 and started[1] == "saved-12")
		assert(#scheduled == 1)
		preload()
		assert(#started == 2 and #scheduled == 1, "only one continuation may be queued")
		for _ = 1, 5 do
			for _, session in pairs(state.sessions) do session.initial_load_complete = true end
			table.remove(scheduled, 1)()
		end
		assert(#started == 12 and #scheduled == 0)
		preload()
		assert(#started == 12, "warm sessions must be reused")
		assert(state.selected_id == "saved-12" and state.active_id == "saved-12")
		assert(vim.api.nvim_win_get_buf(state.chat_win) == visible)
	end)
end)

test("preloading skips loaded, dismissed, missing-directory and failed sessions", function()
	with_preload_spy(function(started)
		preload_thread("working", { status = { type = "active" } })
		preload_thread("external-idle", { status = { type = "idle" } })
		preload_thread("dismissed", { _dismissed = true })
		preload_thread("dismissing")
		state.dismiss_pending.dismissing = true
		preload_thread("missing", { cwd = "/nonexistent-agent-mode-preload-test" })
		preload_thread("failed")
		state.sessions.failed = { id = "failed", initial_load_complete = true }
		preload_thread("saved")
		preload()
		assert(vim.deep_equal(started, { "saved" }))
	end)
end)

test("preloading waits for UI and identity and stops when disabled or shutting down", function()
	with_preload_spy(function(started)
		preload_thread("saved")
		local win = state.chat_win
		state.chat_win = nil
		preload()
		state.chat_win = win
		local session = pending("pending-1")
		preload()
		session.id = "new-id"
		state.recents_tab = "dismissed"
		preload()
		state.recents_tab = "active"
		state.opts.preload_concurrency = 0
		preload()
		state.opts.preload_concurrency = 2
		state.shutting_down = true
		preload()
		assert(#started == 0)
		state.shutting_down = false
		preload()
		assert(vim.deep_equal(started, { "saved" }))
	end)
end)

test("a real background terminal stays hidden and is reused when selected", function()
	state.chat_win = vim.api.nvim_get_current_win()
	state.placeholder_buf = vim.api.nvim_create_buf(false, true)
	state.opts.preload_concurrency = 2
	state.opts.command = { vim.fn.exepath("sh"), "-c", "printf '› Ask Codex to do anything\\n'; sleep 2" }
	preload_thread("background")
	state.active_id = "foreground"
	local visible = vim.api.nvim_win_get_buf(state.chat_win)
	preload()
	local session = assert(state.sessions.background)
	local job = session.job_id
	local ok, err = pcall(function()
		assert(job > 0)
		assert(vim.wait(1000, function() return session.initial_load_complete end))
		assert(vim.api.nvim_win_get_buf(state.chat_win) == visible)
		assert(state.active_id == "foreground" and state.selected_id == nil)
		state.selected_id = "background"
		mode.open_selected(false)
		assert(state.sessions.background == session and session.job_id == job)
		assert(vim.api.nvim_win_get_buf(state.chat_win) == session.buf)
	end)
	state.session_tokens[session.notify_token] = nil
	vim.fn.jobstop(job)
	vim.fn.jobwait({ job }, 1000)
	vim.api.nvim_buf_delete(state.placeholder_buf, { force = true })
	assert(ok, err)
end)

test("interrupt requests stop the live turn and tolerate completion races", function()
	for _, scenario in ipairs({ "working", "idle", "completed", "failed", "read-error", "invalid" }) do
		local backend = Backend.new()
		backend.start = function(_, callback) callback() end
		backend._defer = function(_, callback, ...) callback(...) end
		local reads, interrupts = 0, 0
		backend._request = function(_, method, params, callback)
			assert(params.threadId == "chat")
			if method == "thread/read" then
				assert(params.includeTurns)
				reads = reads + 1
				if scenario == "read-error" then callback("read failed"); return end
				if scenario == "invalid" then callback(nil, {}); return end
				local active = scenario ~= "idle" and not (scenario == "completed" and reads == 2)
				callback(nil, { thread = { turns = {
					{ id = "previous", status = "completed" },
					{ id = "current", status = active and "inProgress" or "completed" },
				} } })
			elseif method == "turn/interrupt" then
				assert(params.turnId == "current")
				interrupts = interrupts + 1
				callback(scenario ~= "working" and "interrupt failed" or nil)
			else
				error("Unexpected request: " .. method)
			end
		end
		local called, failure
		backend:interrupt_thread("chat", function(err) called, failure = true, err end)
		assert(called)
		assert((failure ~= nil) == (scenario == "failed" or scenario == "read-error" or scenario == "invalid"), scenario)
		assert(interrupts == ((scenario == "idle" or scenario == "read-error" or scenario == "invalid") and 0 or 1))
	end
end)

test("individual dismissal interrupts before closing the terminal and archiving", function()
	state.chat_win = vim.api.nvim_get_current_win()
	state.opts.command = { vim.fn.exepath("sh"), "-c", "sleep 30" }
	local chat = thread("chat", nil, { status = { type = "active" } })
	state.threads.chat = chat
	local session = internals.create_terminal("chat", vim.fn.getcwd(), "chat", "chat")
	local job = session.job_id
	local interrupt_reply, archived
	state.backend = {
		interrupt_thread = function(_, id, callback)
			assert(id == "chat" and vim.fn.jobwait({ job }, 0)[1] == -1)
			interrupt_reply = callback
		end,
		archive_thread = function(_, id, callback)
			assert(id == "chat" and state.sessions.chat == nil)
			assert(vim.fn.jobwait({ job }, 0)[1] ~= -1)
			archived = true
			callback(nil)
		end,
	}
	local ok, err = pcall(function()
		internals.dismiss_thread(chat)
		assert(interrupt_reply and not archived and not session.closing)
		assert(state.dismiss_pending.chat)
		interrupt_reply(nil)
		assert(vim.wait(2000, function() return archived end))
		assert(state.dismissed_threads.chat == chat and not state.dismiss_pending.chat)
	end)
	pcall(vim.fn.jobstop, job)
	assert(ok, err)
end)

test("failed interruption restores the active row without closing or archiving", function()
	local chat = thread("chat", nil, { status = { type = "active" } })
	state.threads.chat = chat
	state.backend = {
		interrupt_thread = function(_, _, callback) callback("could not interrupt") end,
		archive_thread = function() error("must not archive running work") end,
	}
	internals.dismiss_thread(chat)
	assert(state.threads.chat == chat and not state.dismissed_threads.chat)
	assert(not state.dismiss_pending.chat and not chat._dismissed)
end)

test("dismiss all continues to skip working tasks", function()
	local working = thread("working", nil, { status = { type = "active" } })
	local idle = thread("idle", nil, { status = { type = "idle" } })
	state.threads = { working = working, idle = idle }
	state.active_order = { working, idle }
	local archived
	state.backend = {
		interrupt_thread = function(_, id, callback) assert(id == "idle"); callback(nil) end,
		archive_thread = function(_, id, callback) archived = id; callback(nil) end,
	}
	local new_chat = mode.new_chat
	mode.new_chat = function() end
	local ok, err = pcall(internals.dismiss_all)
	mode.new_chat = new_chat
	assert(ok, err)
	assert(vim.wait(1000, function() return archived == "idle" end))
	assert(state.threads.working == working and not state.dismissed_threads.working)
end)

test("a dismissed pending task is interrupted as soon as its identity binds", function()
	local session = pending("pending-1")
	local interrupted, archived
	state.backend = {
		interrupt_thread = function(_, id, callback) interrupted = id; callback(nil) end,
		archive_thread = function(_, id, callback) archived = id; callback(nil) end,
	}
	internals.dismiss_thread(state.threads[session.key])
	assert(session.dismiss_when_bound and not interrupted)
	internals.bind_session(session, thread("canonical"), true)
	assert(interrupted == "canonical")
	assert(vim.wait(1000, function() return archived == "canonical" end))
	assert(not state.sessions.canonical and state.dismissed_threads.canonical)
end)

reset()
vim.defer_fn = real_defer
print(string.format("Passed %d recents regression tests", count))
