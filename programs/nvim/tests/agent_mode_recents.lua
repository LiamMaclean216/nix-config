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
	state.opts = { status_debounce_ms = 0 }
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

local infer_status = assert(internals.infer_terminal_status)
local reports_ready = assert(internals.terminal_reports_ready)
local function terminal_session(lines, status)
	local session = pending("chat")
	session.id = "chat"
	session.local_status = status or "ready"
	session.display_status = session.local_status
	session.initial_load_complete = true
	session.buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, lines)
	return session
end

test("approval prose in a completed answer does not override the composer", function()
	local lines = {
		"The command said approval required, but it is finished now.",
		"Would you like to continue? Yes, proceed will allow it.",
		"Do you want to proceed is the old prompt text.",
		"› Ask Codex to do anything", "  ? for shortcuts", "",
	}
	local session = terminal_session(lines, "approval")
	infer_status(session)
	assert(session.display_status == "ready" and reports_ready(lines))
end)

test("a live approval footer blocks ready even when its selection uses a prompt marker", function()
	local lines = {
		"Would you like to grant these permissions?",
		"› 1. Yes, grant these permissions for this turn (y)",
		"  2. No, continue without permissions (d)",
		"  Press enter to confirm or esc to cancel", "", "",
	}
	local session = terminal_session(lines)
	infer_status(session)
	assert(session.display_status == "approval" and not reports_ready(lines))
end)

test("a resolved approval in history cannot hide a completed turn", function()
	local lines = {
		"Would you like to run the following command?", "› 1. Yes, proceed (y)",
		"  Press enter to confirm or esc to cancel", "Finished successfully.",
		"› Ask Codex to do anything", "  ? for shortcuts",
	}
	local session = terminal_session(lines, "approval")
	session.awaiting_completion, session.completion_pending, session.active_seen = true, true, true
	infer_status(session)
	assert(session.display_status == "ready" and reports_ready(lines))
	assert(not session.awaiting_completion and not session.completion_pending)
end)

test("approval returns to working when the native active footer appears", function()
	local session = terminal_session({
		"The previous command had approval required.",
		"• Working (1s • esc to interrupt)", "› Ask Codex to do anything",
		"  ? for shortcuts",
	}, "approval")
	infer_status(session)
	assert(session.display_status == "working" and session.active_seen)
	vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, { "Done.", "› Ask Codex to do anything" })
	infer_status(session)
	assert(session.display_status == "ready" and not session.awaiting_completion)
end)

test("input dialogs remain input and old selection instructions do not block ready", function()
	local lines = { "› First option", "  Use tab / ↑ ↓ to move, enter to select, esc to close" }
	local session = terminal_session(lines)
	infer_status(session)
	assert(session.display_status == "input" and not reports_ready(lines))
	vim.list_extend(lines, { "Selected first option.", "› Ask Codex to do anything", "  ? for shortcuts" })
	vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, lines)
	infer_status(session)
	assert(session.display_status == "ready" and reports_ready(lines))
end)

test("restoration becomes ready without marking activity or unread", function()
	local session = terminal_session({ "› Ask Codex to do anything", "  ? for shortcuts" }, "loading")
	session.initial_load_complete = false
	state.opts.status_debounce_ms = 500
	infer_status(session)
	assert(session.display_status == "ready" and session.initial_load_complete)
	assert(not session.status_timer and not session.unread)
	assert(state.threads.chat._activity_at == 123)
end)

test("terminal creation uses loading for restoration and working for a fresh submission", function()
	state.chat_win = vim.api.nvim_get_current_win()
	state.opts.command = "unused-test-command"
	state.opts.startup_working_ms = 5000
	local original_jobstart, original_notify = vim.fn.jobstart, vim.notify
	local observed = {}
	vim.fn.jobstart = function()
		for key, session in pairs(state.sessions) do
			observed[key] = observed[key] or session.display_status
		end
		return 0 -- Inspect initialization without launching a CLI.
	end
	vim.notify = function() end
	local ok, err = pcall(function()
		internals.create_terminal("saved", "/repo", "saved", "saved")
		internals.create_terminal(nil, "/repo", "fresh", nil, true)
		assert(observed.saved == "loading" and observed.fresh == "working")
	end)
	vim.fn.jobstart, vim.notify = original_jobstart, original_notify
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
	local started = {}
	debug.setupvalue(preload, slot, function(resume_id, cwd, key, thread_id)
		assert(resume_id == key and key == thread_id)
		started[key] = (started[key] or 0) + 1
		local session = { id = thread_id, key = key, cwd = cwd, display_status = "working" }
		state.sessions[key] = session
		return session
	end)
	local ok, err = pcall(callback, started)
	debug.setupvalue(preload, slot, original)
	assert(ok, err)
end

test("opening preloads up to ten active chats and reuses their sessions", function()
	local threads = {}
	for index = 1, 12 do
		table.insert(threads, thread("saved-" .. index, "prompt " .. index))
	end
	listing(threads)
	with_preload_spy(function(started)
		refresh()
		assert(next(started) == nil, "metadata refresh before opening must not start terminals")
		state.chat_win = vim.api.nvim_get_current_win()
		local buffer = vim.api.nvim_win_get_buf(state.chat_win)
		state.active_id = "saved-1"
		refresh()
		assert(vim.tbl_count(started) == 10)
		assert(state.active_id == "saved-1" and vim.api.nvim_win_get_buf(state.chat_win) == buffer)
		refresh()
		assert(vim.tbl_count(started) == 10)
		for _, starts in pairs(started) do
			assert(starts == 1, "refresh must not restart preloaded sessions")
		end
	end)
end)

test("preloading waits for pending identity then resumes other saved chats", function()
	local session = pending("pending-1")
	state.chat_win = vim.api.nvim_get_current_win()
	listing({ thread("saved", "older conversation") })
	with_preload_spy(function(started)
		refresh()
		assert(next(started) == nil and not session.id)
		listing({ thread("root"), thread("saved", "older conversation") })
		refresh()
		assert(session.id == "root" and state.sessions.root == session)
		assert(started.root == nil and started.saved == 1)
		assert(#state.order == 2 and state.threads["pending-1"] == nil)
	end)
end)

reset()
vim.defer_fn = real_defer
print(string.format("Passed %d recents regression tests", count))
