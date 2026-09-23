-- Run from the repository root:
-- nvim --headless -u NONE -i NONE -l programs/nvim/tests/agent_mode_recents.lua
local root = vim.fn.getcwd() .. "/programs/nvim/lua/agent_mode/"
for _, name in ipairs({ "backend", "history", "identity", "project", "sidebar", "docker" }) do
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
	local launcher = directory .. "/launcher.sh"
	vim.fn.writefile({
		"#!" .. vim.fn.exepath("sh"),
		"sleep 0.1",
		"touch service-ready",
		'exec "$@"',
	}, launcher)
	vim.fn.setfperm(launcher, "rwx------")
	vim.fn.writefile({
		'test -f service-ready || exit 1',
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
	state.opts.launcher = launcher
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

test("inline recents filtering updates both full lists and supports apply, clear, and cancel", function()
	state.opts.sidebar_width = 24
	state.opts.preview_delay = 1
	internals.create_ui()
	state.threads = { alpha = thread("alpha", "alpha chat"), beta = thread("beta", "beta chat") }
	state.dismissed_threads = { old = thread("old", "alpha archived") }
	state.backend = { search_threads = function(_, params, callback)
		local matches = {}
		for _, item in pairs(params.archived and state.dismissed_threads or state.threads) do
			if item.preview:find(params.searchTerm, 1, true) then table.insert(matches, item) end
		end
		callback(nil, matches)
	end }
	internals.sort_threads()
	internals.sidebar_mappings()
	internals.render_sidebar()
	local preload = mode.preload_selected
	mode.preload_selected = function() end
	local ok, err = pcall(function()
		local function key(lhs, mapping_mode)
			vim.fn.maparg(lhs, mapping_mode or "n", false, true).callback()
		end
		local function type_query(query)
			local filter = assert(state.filter)
			vim.api.nvim_buf_set_lines(filter.buf, 0, -1, false, { filter.prompt .. query })
			vim.api.nvim_exec_autocmds("TextChangedI", { buffer = filter.buf })
			if state.search then internals.search_recents(state.search) end
		end
		key("/")
		local filter = assert(state.filter)
		assert(vim.api.nvim_win_get_config(filter.win).relative == "editor", "input must stay within the overlay")
		assert(vim.api.nvim_win_get_position(filter.win)[1] < vim.api.nvim_win_get_position(state.sidebar_win)[1])
		type_query("alpha")
		assert(#state.order == 1 and state.order[1].id == "alpha")
		assert(#state.dismissed_order == 1)
		type_query("missing")
		assert(#state.order == 0 and #state.dismissed_order == 0)
		assert(not next(state.cursor_rows), "an empty search must have no selectable runs")
		type_query("")
		assert(#state.order == 2 and #state.dismissed_order == 1, "clearing input must restore all cached rows")
		type_query("beta")
		assert(#state.order == 1 and state.order[1].id == "beta" and #state.dismissed_order == 0)
		assert(vim.api.nvim_get_current_win() == filter.win, "rendering must preserve input focus")
		key("<CR>", "i")
		assert(not state.filter and state.search_term == "beta" and #state.order == 1)
		assert(not vim.api.nvim_buf_is_valid(filter.buf) and not vim.api.nvim_win_is_valid(filter.win))
		assert(vim.api.nvim_get_current_win() == state.sidebar_win)
		key("<Esc>")
		assert(not state.search_term and #state.order == 2 and #state.dismissed_order == 1)
		key("/")
		type_query("alpha")
		key("<Esc>", "i")
		assert(not state.filter and not state.search_term and #state.order == 2)
		local function feed(keys)
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
		end
		feed("/beta<CR>")
		assert(not state.filter and state.search_term == "beta", "typing and Enter must apply the prompt text")
		feed("<Esc>")
		assert(not state.search_term and #state.order == 2)
		feed("/alpha<Esc>")
		assert(not state.filter and not state.search_term and #state.order == 2)
	end)
	vim.cmd("stopinsert")
	if state.filter then internals.finish_recents_filter(false) end
	mode.leave()
	mode.preload_selected = preload
	vim.api.nvim_buf_delete(state.sidebar_buf, { force = true })
	vim.api.nvim_buf_delete(state.placeholder_buf, { force = true })
	assert(ok, err)
end)

test("full-text search debounces input and ignores stale or cancelled results", function()
	state.threads = { first = thread("first", "unrelated title"), second = thread("second", "another title") }
	local original_first = state.threads.first
	local scheduled, requests = {}, {}
	state.backend = { search_threads = function(_, params, callback)
		table.insert(requests, { params = params, reply = callback })
	end }
	local defer = vim.defer_fn
	vim.defer_fn = function(callback, delay)
		assert(delay == 150)
		table.insert(scheduled, callback)
	end
	local ok, err = pcall(function()
		internals.set_recents_filter("bo")
		internals.set_recents_filter("body text")
		scheduled[1]()
		assert(#requests == 0, "superseded keystrokes must not send searches")
		scheduled[2]()
		assert(#requests == 2 and requests[1].params.searchTerm == "body text")
		assert(not requests[1].params.archived and requests[2].params.archived)
		requests[1].reply(nil, { thread("first", "unrelated title"), thread("foreign", nil, { cwd = "/other" }) })
		assert(#state.order == 1 and state.order[1].id == "first", "body matches must survive title mismatch")
		assert(state.threads.first == original_first and not state.threads.foreign)
		internals.set_recents_filter("different body text")
		scheduled[3]()
		requests[2].reply(nil, { thread("stale", "unrelated archived title") })
		assert(not state.dismissed_threads.stale, "old replies must not populate the current search")
		requests[3].reply(nil, { thread("second", "another title"), thread("discovered", "older title") })
		assert(#state.order == 2 and state.threads.discovered, "search must include matches beyond the current cache")
		internals.set_recents_filter("")
		requests[4].reply(nil, { thread("cancelled") })
		assert(not state.search and not state.search_term and #state.order == 3)
		assert(not state.dismissed_threads.cancelled)
		assert(state.threads.first == original_first, "search must preserve the complete identity/runtime cache")
	end)
	vim.defer_fn = defer
	assert(ok, err)
end)

test("in-flight full list refreshes use the current inline filter", function()
	local replies = {}
	state.backend = { list_threads = function(_, params, callback)
		assert(params.searchTerm == nil)
		replies[params.archived and "dismissed" or "active"] = callback
	end }
	refresh()
	internals.refresh_dismissed_threads()
	state.search_term = "beta"
	state.search = { matches = { beta = true, ["old-beta"] = true }, pending = {}, errors = {} }
	replies.active(nil, { thread("alpha", "alpha"), thread("beta", "beta") })
	replies.dismissed(nil, { thread("old-alpha", "alpha"), thread("old-beta", "beta") })
	assert(#state.active_order == 1 and state.active_order[1].id == "beta")
	assert(#state.dismissed_order == 1 and state.dismissed_order[1].id == "old-beta")
	state.search_term = nil
	internals.sort_threads()
	assert(#state.active_order == 2 and #state.dismissed_order == 2)
end)

for _, immediate_refresh in ipairs({ true, false }) do
	test("Enter restores and focuses the first active chat with " .. (immediate_refresh and "immediate" or "delayed") .. " refresh", function()
		vim.cmd("tabnew")
		state.sidebar_win = vim.api.nvim_get_current_win()
		state.sidebar_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_win_set_buf(state.sidebar_win, state.sidebar_buf)
		vim.cmd("vsplit")
		state.chat_win = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(state.sidebar_win)
		local recent = thread("recent", nil, { updatedAt = os.time() + 100 })
		local old = thread("old", nil, { _dismissed = true })
		state.threads.recent = recent
		state.dismissed_threads.old = old
		state.recents_tab = "dismissed"
		state.selected_ids.active = "recent"
		internals.sort_threads()
		internals.sidebar_mappings()
		internals.render_sidebar()
		local restore_reply, refresh_reply
		local function refreshed(callback)
			callback(nil, { vim.deepcopy(recent), thread("old") })
		end
		state.backend = {
			unarchive_thread = function(_, id, callback)
				assert(id == "old")
				restore_reply = callback
			end,
			list_threads = function(_, _, callback)
				if immediate_refresh then refreshed(callback) else refresh_reply = callback end
			end,
		}
		local preload, open = mode.preload_selected, mode.open_selected
		local opened
		mode.preload_selected = function() end
		mode.open_selected = function(focus)
			opened = state.selected_id
			assert(focus, "Enter must request chat focus")
			vim.api.nvim_set_current_win(state.chat_win)
		end
		local ok, err = pcall(function()
			vim.fn.maparg("<CR>", "n", false, true).callback()
			assert(not opened and state.recents_tab == "dismissed", "wait for successful restore")
			restore_reply(nil, { thread = thread("old") })
			local function check_restored()
				assert(state.recents_tab == "active" and not state.dismissed_threads.old)
				assert(state.active_order[1].id == "old", "restored chat must sort ahead of newer chats")
				assert(state.selected_id == "old" and state.selected_ids.active == "old")
				assert(opened == "old", "Enter must open the restored chat")
				assert(vim.api.nvim_get_current_win() == state.chat_win)
				assert(vim.api.nvim_win_get_cursor(state.sidebar_win)[1] == state.cursor_rows.old)
			end
			check_restored()
			if refresh_reply then refreshed(refresh_reply) end
			check_restored()
		end)
		mode.preload_selected, mode.open_selected = preload, open
		vim.cmd("tabclose!")
		vim.api.nvim_buf_delete(state.sidebar_buf, { force = true })
		assert(ok, err)
	end)
end

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

for _, tab in ipairs({ "active", "dismissed" }) do
	test("f forks the hovered " .. tab .. " chat to the top, Ready and focused", function()
		vim.cmd("tabnew")
		state.tab = vim.api.nvim_get_current_tabpage()
		state.sidebar_win = vim.api.nvim_get_current_win()
		state.sidebar_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_win_set_buf(state.sidebar_win, state.sidebar_buf)
		vim.cmd("vsplit")
		state.chat_win = vim.api.nvim_get_current_win()
		state.placeholder_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_win_set_buf(state.chat_win, state.placeholder_buf)
		vim.api.nvim_set_current_win(state.sidebar_win)
		local cwd = vim.fn.getcwd()
		state.project = { launch_cwd = cwd, worktrees = { { path = cwd } } }
		state.opts.preview_delay = 150
		state.opts.command = { vim.fn.exepath("sh"), "-c", "printf '› Ask Codex to do anything\\n'; sleep 30" }
		local source = thread("source", "source history", {
			cwd = cwd, status = { type = "active" }, _dismissed = tab == "dismissed" or nil,
		})
		local recent = thread("recent", nil, { cwd = cwd, updatedAt = os.time() + 100 })
		state.threads.recent = recent
		local source_list = tab == "active" and state.threads or state.dismissed_threads
		source_list.source = source
		state.recents_tab = tab
		state.search_term = "history"
		state.search = { matches = { source = true, recent = true } }
		internals.sort_threads()
		internals.sidebar_mappings()
		internals.render_sidebar()
		local reply, requests = nil, 0
		state.backend = {
			fork_thread = function(_, id, callback)
				assert(id == "source", "fork the hovered row, regardless of the open chat")
				requests, reply = requests + 1, callback
			end,
		}
		local job
		local ok, err = pcall(function()
			internals.select_sidebar_row(state.cursor_rows.source)
			state.active_id = "recent"
			local fork_key = vim.fn.maparg("f", "n", false, true).callback
			fork_key()
			fork_key()
			assert(requests == 1 and not state.threads.fork, "deduplicate while the fork is pending")
			local fork = thread("fork", "source history", { cwd = cwd, status = { type = "idle" } })
			reply(nil, { thread = fork })
			local session = assert(state.sessions.fork)
			job = session.job_id
			assert(job > 0)
			local function check()
				assert(state.recents_tab == "active" and state.order[1].id == "fork")
				assert(state.selected_id == "fork" and state.selected_ids.active == "fork")
				assert(state.active_id == "fork" and vim.api.nvim_get_current_win() == state.chat_win)
				assert(internals.status_name(state.threads.fork) == "ready")
			end
			check()
			assert(not state.search_term and not state.search, "the fork must be visible outside the old filter")
			assert(source_list.source == source and source.status.type == "active", "leave the source unchanged")
			assert(session.default_status == "ready" and not session.initial_prompt)
			assert(vim.wait(1000, function() return session.initial_load_complete end))
			check()
			assert(vim.api.nvim_win_get_buf(state.chat_win) == session.buf)
			-- A poll started before the fork may omit it; its new terminal keeps it visible.
			listing({ recent })
			refresh()
			check()
			listing({ recent, fork })
			refresh()
			check()
		end)
		if job then
			state.session_tokens[state.sessions.fork.notify_token] = nil
			vim.fn.jobstop(job)
			vim.fn.jobwait({ job }, 1000)
		end
		if state.preview_timer then
			state.preview_timer:stop()
			state.preview_timer:close()
			state.preview_timer = nil
		end
		vim.cmd("stopinsert")
		vim.cmd("tabclose!")
		vim.api.nvim_buf_delete(state.sidebar_buf, { force = true })
		vim.api.nvim_buf_delete(state.placeholder_buf, { force = true })
		assert(ok, err)
	end)
end

test("failed and stale forks do not change the selected chat", function()
	local reply, messages = nil, {}
	state.backend = { fork_thread = function(_, _, callback) reply = callback end }
	state.threads.source = thread("source")
	state.selected_id = "source"
	local original_notify = vim.notify
	vim.notify = function(message) table.insert(messages, message) end
	local ok, err = pcall(function()
		internals.fork_selected()
		reply("fork failed")
		assert(not state.fork_pending.source and state.selected_id == "source")
		assert(#messages == 1 and messages[1]:find("fork failed", 1, true))
		internals.fork_selected()
		state.project = { launch_cwd = "/other", worktrees = { { path = "/other" } } }
		reply(nil, { thread = thread("fork") })
		assert(not state.threads.fork and state.selected_id == "source")
	end)
	vim.notify = original_notify
	assert(ok, err)
end)

test("fork and unsubscribe pass through the metadata transport", function()
	local backend = Backend.new()
	backend.start = function(_, callback) callback() end
	backend.running = true
	local sent, called, failure, result = {}, false, nil, nil
	backend.process = { write = function(_, line)
		table.insert(sent, vim.json.decode(line))
	end }
	backend:fork_thread("source", function(err, response)
		called, failure, result = true, err, response
	end)
	assert(#sent == 1 and sent[1].method == "thread/fork", "fork must reach the transport")
	assert(sent[1].params.threadId == "source")
	backend:_feed_stdout(vim.json.encode({ id = sent[1].id, result = { thread = thread("fork") } }) .. "\n")
	assert(vim.wait(1000, function() return #sent == 2 or called end))
	assert(not called, "the fork must wait for unsubscribe")
	assert(sent[2].method == "thread/unsubscribe" and sent[2].params.threadId == "fork")
	backend:_feed_stdout(vim.json.encode({ id = sent[2].id, result = { status = "unsubscribed" } }) .. "\n")
	assert(vim.wait(1000, function() return called end))
	assert(not failure, failure)
	assert(result.thread.id == "fork" and next(backend._pending) == nil)
end)

test("fork requests defer goals and release ownership before opening the terminal", function()
	for _, scenario in ipairs({ "success", "fork-error", "invalid", "release-error" }) do
		local backend = Backend.new()
		backend.start = function(_, callback) callback() end
		local release, called, failure
		backend._request = function(_, method, params, callback)
			if method == "thread/fork" then
				assert(params.threadId == "source" and params.threadSource == "user")
				assert(params.deferGoalContinuation and params.excludeTurns)
				if scenario == "fork-error" then callback("fork failed"); return end
				callback(nil, { thread = thread(scenario == "invalid" and "source" or "fork") })
			elseif method == "thread/unsubscribe" then
				assert(params.threadId == "fork")
				release = callback
			else
				error("Unexpected request: " .. method)
			end
		end
		backend:fork_thread("source", function(err, result)
			called, failure = true, err
			if not err then assert(result.thread.id == "fork") end
		end)
		if release then
			assert(not called, "the CLI must wait until the metadata connection releases the fork")
			release(scenario == "release-error" and "release failed" or nil)
		end
		assert(called and (failure ~= nil) == (scenario ~= "success"), scenario)
	end
end)

test("moving a thread confirms its directory and releases ownership without forking history", function()
	for _, scenario in ipairs({ "success", "busy", "writer-conflict", "update-error", "read-error", "release-error" }) do
		local backend = Backend.new()
		backend.start = function(_, callback) callback() end
		backend.running = true
		local sent, called, failure, moved = {}, false, nil, nil
		backend.process = { write = function(_, line) table.insert(sent, vim.json.decode(line)) end }
		backend:move_thread("source", "/repo/new-worktree", function(err, result)
			called, failure, moved = true, err, result
		end)
		local cursor = 1
		while not called do
			assert(vim.wait(1000, function() return sent[cursor] ~= nil or called end))
			if called then break end
			local request = sent[cursor]
			assert(request.params.threadId == "source")
			local response = { id = request.id, result = {} }
			if request.method == "thread/resume" then
				assert(cursor == 1)
				if scenario == "writer-conflict" then
					response = { id = request.id, error = { code = -32600, message = "active writer" } }
				else
					response.result = { thread = { id = "source", turns = scenario == "busy"
						and { { id = "running", status = "inProgress" } } or {} } }
				end
			elseif request.method == "thread/settings/update" then
				assert(scenario ~= "busy" and request.params.cwd == "/repo/new-worktree")
				if scenario == "update-error" then
					response = { id = request.id, error = { code = -32600, message = "update failed" } }
				end
			elseif request.method == "thread/read" then
				response.result = { thread = { id = "source", cwd = "/repo/new-worktree" } }
				if scenario == "read-error" then
					response = { id = request.id, error = { code = -32600, message = "read failed" } }
				end
			elseif request.method == "thread/unsubscribe" then
				assert(not called, "wait for release before reopening")
				if scenario == "release-error" then
					response = { id = request.id, error = { code = -32600, message = "release failed" } }
				end
			else
				error("Unexpected request: " .. request.method)
			end
			backend:_feed_stdout(vim.json.encode(response) .. "\n")
			cursor = cursor + 1
		end
		assert((failure ~= nil) == (scenario ~= "success"), scenario)
		assert(sent[#sent].method == (scenario == "writer-conflict" and "thread/resume" or "thread/unsubscribe"))
		if scenario == "success" then assert(moved.id == "source" and moved.cwd == "/repo/new-worktree") end
	end
end)

test("moving waits for asynchronous directory publication before releasing the writer", function()
	local backend = Backend.new()
	backend.start = function(_, callback) callback() end
	local retry, released, completed, reads = nil, false, false, 0
	local defer = vim.defer_fn
	vim.defer_fn = function(callback) retry = callback end
	backend._request = function(_, method, _, callback)
		if method == "thread/resume" then
			callback(nil, { thread = { turns = {} } })
		elseif method == "thread/read" then
			reads = reads + 1
			callback(nil, { thread = { id = "source", cwd = reads == 1 and "/old" or "/new" } })
		else
			released = method == "thread/unsubscribe"
			callback(nil, {})
		end
	end
	backend:move_thread("source", "/new", function(err) assert(not err, err); completed = true end)
	assert(retry and not completed and not released)
	retry()
	vim.defer_fn = defer
	assert(completed and released and reads == 2)
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

for _, tab in ipairs({ "active", "dismissed" }) do
	test(tab .. " recents keep all runs expanded and scroll keyboard navigation", function()
		vim.cmd("tabnew")
		state.sidebar_win = vim.api.nvim_get_current_win()
		state.sidebar_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_win_set_buf(state.sidebar_win, state.sidebar_buf)
		internals.set_window_options(state.sidebar_win, true)
		state.recents_tab = tab
		local source = tab == "active" and state.threads or state.dismissed_threads
		for index = 1, 1003 do
			local id = tostring(index)
			source[id] = thread(id, "Conversation " .. id, { updatedAt = 2000 - index })
		end
		internals.sort_threads()
		internals.sidebar_mappings()
		local ok, err = pcall(function()
			internals.render_sidebar()
			local header = vim.wo[state.sidebar_win].winbar
			local function check_selection(expected)
				vim.cmd("redraw")
				assert(state.selected_id == tostring(expected))
				local row = assert(state.cursor_rows[state.selected_id])
				assert(vim.api.nvim_win_get_cursor(state.sidebar_win)[1] == row)
				assert(vim.fn.line("w0") <= row and row <= vim.fn.line("w$"), "selection must stay visible")
				assert(vim.tbl_count(state.cursor_rows) == 1003, "every run must remain inside the expanded worktree")
				assert(vim.wo[state.sidebar_win].winbar == header, "scrolling must preserve the fixed header")
				local rendered = vim.api.nvim_eval_statusline(header, { winid = state.sidebar_win, use_winbar = true }).str
				assert(rendered:find("Active", 1, true) and rendered:find("Dismissed", 1, true))
				assert(not table.concat(vim.api.nvim_buf_get_lines(state.sidebar_buf, 0, -1, false), "\n")
					:find("Dismissed", 1, true), "header must be outside the scrolling buffer")
			end
			check_selection(1)
			for index = 2, 26 do
				vim.fn.maparg("j", "n", false, true).callback()
				check_selection(index)
			end
			for index = 25, 1, -1 do
				vim.fn.maparg("k", "n", false, true).callback()
				check_selection(index)
			end
			vim.fn.maparg("G", "n", false, true).callback()
			check_selection(1003)
			assert(vim.tbl_count(state.cursor_rows) == 1003, "jumping to the end must keep earlier runs expanded")
			internals.select_sidebar_row(state.cursor_rows["1001"])
			check_selection(1001)
			vim.fn.maparg("gg", "n", false, true).callback()
			check_selection(1)
		end)
		vim.cmd("tabclose!")
		vim.api.nvim_buf_delete(state.sidebar_buf, { force = true })
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
				assert(not next(state.cursor_rows), "empty worktrees must have no selectable runs")
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

for _, review in ipairs({
	{ name = "base branch", prompt = "Review the code changes against the base branch 'develop'." },
	{ name = "uncommitted changes", prompt = "Review the current code changes (staged, unstaged, and untracked files)." },
	{ name = "commit", prompt = "Review the changes introduced by commit abc123." },
	{ name = "custom instructions", prompt = "Check whether the new cache preserves permissions." },
}) do
	test("/review with " .. review.name .. " replaces its temporary row while working", function()
		local session = pending("pending-review", "/review")
		state.active_id, state.selected_id = session.key, session.key
		state.selected_ids.active = session.key
		local saved = thread("review", review.prompt, { status = { type = "active" } })
		listing({ saved })
		local reads = 0
		state.backend.read_thread = function(_, id, callback, options)
			reads = reads + 1
			assert(id == "review" and not (options and options.summary_only))
			callback(nil, { thread = vim.tbl_extend("force", saved, {
				turns = { { items = { { type = "enteredReviewMode", review = review.name } } } },
			}) })
		end
		refresh()
		assert(session.id == "review" and #state.order == 1)
		assert(not state.threads["pending-review"] and state.sessions.review == session)
		assert(state.active_id == "review" and state.selected_ids.active == "review")
		assert(status_name(state.order[1]) == "working")
		refresh()
		assert(#state.order == 1 and reads == 1, "bound reviews need no further history reads")
	end)
end

test("typing /review in a fresh terminal preserves identity through picker confirmation", function()
	local session = pending("pending-review")
	session.initial_prompt = nil
	session.buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_current_buf(session.buf)
	internals.configure_terminal_buffer(session)
	local enter
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(session.buf, "t")) do
		if mapping.lhs == "<CR>" then enter = mapping.callback end
	end
	for _, line in ipairs({ "› /review", "› Review against a base branch", "› develop" }) do
		vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, { line })
		vim.api.nvim_win_set_cursor(0, { 1, #line - 1 })
		assert(enter)()
		assert(session.initial_prompt == "/review")
	end
end)

test("review identity ignores unrelated chats and excludes old, known, and other-project rows", function()
	local session = pending("pending-review", "/review")
	session.known_ids.known = true
	listing({
		thread("ordinary", "Review the code changes against the base branch 'develop'."),
		thread("old", nil, { createdAt = 90 }), thread("known"),
		thread("elsewhere", nil, { cwd = "/another-project" }),
	})
	local reads = 0
	state.backend.read_thread = function(_, id, callback)
		reads = reads + 1
		assert(id == "ordinary")
		callback(nil, { thread = thread(id, nil, { turns = {
			{ items = { { type = "userMessage" } } },
			{ items = { { type = "enteredReviewMode" } } },
		} }) })
	end
	refresh()
	assert(not session.id and reads == 1, "only a review in the first turn is identity evidence")
end)

test("simultaneous reviews stay ambiguous without displaying duplicate saved rows", function()
	local first = pending("pending-first", "/review")
	local second = pending("pending-second", "/review")
	listing({ thread("first", "First custom review"), thread("second", "Second custom review") })
	local callbacks = {}
	state.backend.read_thread = function(_, id, callback) callbacks[id] = callback end
	refresh()
	assert(state.refreshing)
	callbacks.second(nil, { thread = thread("second", nil, {
		turns = { { items = { { type = "enteredReviewMode" } } } },
	}) })
	assert(state.refreshing and not first.id and not second.id)
	callbacks.first(nil, { thread = thread("first", nil, {
		turns = { { items = { { type = "enteredReviewMode" } } } },
	}) })
	assert(not state.refreshing and not first.id and not second.id)
	assert(#state.order == 2 and not state.threads.first and not state.threads.second)
end)

test("review lookup failures retry and delayed responses respect project changes", function()
	local session = pending("pending-review", "/review")
	listing({ thread("review", "Custom review") })
	local callback
	state.backend.read_thread = function(_, _, cb) callback = cb end
	refresh()
	callback("not yet persisted")
	assert(not state.refreshing and not session.id)
	refresh()
	state.project = { launch_cwd = "/elsewhere", worktrees = { { path = "/elsewhere" } } }
	callback(nil, { thread = thread("review", nil, {
		turns = { { items = { { type = "enteredReviewMode" } } } },
	}) })
	assert(not state.refreshing and not session.id)
	state.project = { launch_cwd = "/repo", worktrees = { { path = "/repo" } } }
	refresh()
	callback(nil, { thread = thread("review", nil, {
		turns = { { items = { { type = "enteredReviewMode" } } } },
	}) })
	assert(session.id == "review" and #state.order == 1)
	-- Drain the refresh queued by the project change before replacing its backend.
	vim.wait(10, function() return false end)
end)

test("title changes update the existing row after switching away", function()
	local session = pending("pending-1")
	state.active_id = "another-chat"
	state.search_term = "Generated title"
	state.search = { matches = { root = true }, pending = {}, errors = {} }
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

for _, method in ipairs({ "list", "search" }) do
	test(method .. " pagination deduplicates canonical IDs", function()
		local backend = Backend.new()
		backend.start = function(_, callback) callback() end
		backend._defer = function(_, callback, ...) callback(...) end
		backend._request = function(_, request_method, params, callback)
			assert(request_method == "thread/" .. method)
			assert(params.searchTerm == (method == "search" and "body text" or nil))
			local function result(item)
				return method == "search" and { thread = item, snippet = "body text" } or item
			end
			if not params.cursor then
				callback(nil, { data = { result(thread("root")) }, nextCursor = "next" })
			else
				callback(nil, { data = { result(thread("root")), result(thread("helper", nil, { ephemeral = true })) } })
			end
		end
		backend[method .. "_threads"](backend, { searchTerm = method == "search" and "body text" or nil }, function(err, threads)
			assert(not err and #threads == 1 and threads[1].id == "root")
		end)
	end)
end


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
		mode.leave()
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

test("queued dismissal keeps the terminal alive until completion, then closes before archiving", function()
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
		assert(chat._dismiss_queued and not interrupt_reply and not session.closing)
		assert(vim.fn.jobwait({ job }, 0)[1] == -1)
		internals.handle_backend_notification("thread/status/changed", { threadId = "chat", status = { type = "idle" } })
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
	local chat = thread("chat", nil, { status = { type = "idle" } })
	state.threads.chat = chat
	state.backend = {
		interrupt_thread = function(_, _, callback) callback("could not interrupt") end,
		archive_thread = function() error("must not archive running work") end,
	}
	internals.dismiss_thread(chat)
	assert(state.threads.chat == chat and not state.dismissed_threads.chat)
	assert(not state.dismiss_pending.chat and not chat._dismissed)
end)

test("dismiss all queues working tasks while dismissing idle tasks", function()
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
	assert(working._dismiss_queued)
end)

for _, first in ipairs({ "d", "D" }) do
	for _, second in ipairs({ "d", "D" }) do
		test(first .. " queues working recents and " .. second .. " cancels dismissal", function()
			local chat = thread("chat", nil, { status = { type = "active" } })
			state.threads.chat = chat
			state.opts.sidebar_width = 60
			state.sidebar_buf = vim.api.nvim_create_buf(false, true)
			internals.sidebar_mappings()
			internals.sort_threads()
			local function press(key)
				vim.api.nvim_buf_call(state.sidebar_buf, function()
					vim.fn.maparg(key, "n", false, true).callback()
				end)
			end
			local function queued_label()
				for _, line in ipairs(vim.api.nvim_buf_get_lines(state.sidebar_buf, 0, -1, false)) do
					if line:find("Queued to dismiss", 1, true) then
						assert(line:match("Working .*Queued to dismiss%s*│$"), "queue label must end the status line")
						return true
					end
				end
			end
			press(first)
			assert(chat._dismiss_queued and not chat._dismissed and not state.dismiss_pending.chat)
			assert(queued_label(), "queued rows need a visible label")
			press(second)
			assert(not chat._dismiss_queued and state.threads.chat == chat)
			assert(not queued_label(), "cancelling must remove the label")
			internals.handle_backend_notification("thread/status/changed", { threadId = "chat", status = { type = "idle" } })
			assert(state.threads.chat == chat, "cancelled dismissal must survive completion")
			vim.api.nvim_buf_delete(state.sidebar_buf, { force = true })
		end)
	end
end

for _, ending in ipairs({ "idle", "systemError" }) do
	test("queued dismissal waits through pauses and finishes on " .. ending, function()
		local chat = thread("chat", nil, { status = { type = "active" } })
		state.threads.chat = chat
		local archived, interrupts = 0, 0
		state.backend = {
			interrupt_thread = function(_, _, callback) interrupts = interrupts + 1; callback(nil) end,
			archive_thread = function(_, _, callback) archived = archived + 1; callback(nil) end,
		}
		internals.dismiss_thread(chat)
		for _, flag in ipairs({ "waitingOnApproval", "waitingOnUserInput" }) do
			internals.handle_backend_notification("thread/status/changed", {
				threadId = "chat", status = { type = "active", activeFlags = { flag } },
			})
			assert(chat._dismiss_queued and state.threads.chat == chat and interrupts == 0)
		end
		internals.handle_backend_notification("thread/status/changed", { threadId = "chat", status = { type = ending } })
		assert(not state.threads.chat and state.dismissed_threads.chat == chat)
		assert(not chat._dismiss_queued)
		assert(vim.wait(1000, function() return archived == 1 end))
		internals.handle_backend_notification("thread/status/changed", { threadId = "chat", status = { type = ending } })
		assert(interrupts == 1, "duplicate completion must not dismiss twice")
	end)
end

test("refresh preserves the queue and dismisses completed chats hidden by a filter", function()
	state.threads.chat = thread("chat", nil, { status = { type = "active" } })
	internals.dismiss_thread(state.threads.chat)
	listing({ thread("chat", nil, { status = { type = "active" } }) })
	refresh()
	assert(state.threads.chat._dismiss_queued)
	listing({ thread("chat", nil, { status = { type = "notLoaded" } }) })
	refresh()
	assert(state.threads.chat._dismiss_queued, "unloaded snapshots are not completion")
	state.search_term = "no matching conversations"
	listing({ thread("chat", nil, { status = { type = "idle" } }) })
	local archived
	state.backend.interrupt_thread = function(_, _, callback) callback(nil) end
	state.backend.archive_thread = function(_, id, callback) archived = id; callback(nil) end
	refresh()
	assert(not state.threads.chat and state.dismissed_threads.chat)
	assert(vim.wait(1000, function() return archived == "chat" end))
end)

test("queued pending tasks retain the queue when their identity binds", function()
	local session = pending("pending-1")
	session.default_status = "working"
	local interrupted, archived
	state.backend = {
		interrupt_thread = function(_, id, callback) interrupted = id; callback(nil) end,
		archive_thread = function(_, id, callback) archived = id; callback(nil) end,
	}
	internals.dismiss_thread(state.threads[session.key])
	assert(state.threads[session.key]._dismiss_queued and not interrupted)
	local canonical = thread("canonical", nil, { status = { type = "active" } })
	state.threads.canonical = canonical
	internals.bind_session(session, canonical, true)
	assert(canonical._dismiss_queued and not interrupted and not state.threads["pending-1"])
	internals.handle_backend_notification("thread/status/changed", { threadId = "canonical", status = { type = "idle" } })
	assert(interrupted == "canonical")
	assert(vim.wait(1000, function() return archived == "canonical" end))
	assert(not state.sessions.canonical and state.dismissed_threads.canonical)
end)

test("saved collaboration mode includes interrupted turns and explicit settings changes", function()
	local path = vim.fn.tempname()
	local saved = thread("saved", nil, { path = path })
	local function append(item)
		vim.fn.writefile({ vim.json.encode(item) }, path, "a")
	end
	append({ type = "session_meta", payload = { id = "saved" } })
	append({ type = "turn_context", payload = { collaboration_mode = { mode = "plan" } } })
	append({ type = "event_msg", payload = { type = "turn_aborted" } })
	assert(Backend.saved_plan_mode(saved) == true)
	append({ type = "event_msg", payload = { type = "thread_settings_applied",
		thread_settings = { collaboration_mode = { mode = "default" } } } })
	assert(Backend.saved_plan_mode(saved) == false, "an explicit mode change wins over the last turn")
	append({ type = "event_msg", payload = { type = "task_started", collaboration_mode_kind = "plan" } })
	vim.fn.writefile({ '{"type":"turn_context","payload":' }, path, "a")
	assert(Backend.saved_plan_mode(saved) == true, "a partial final record must not erase saved mode")
	assert(Backend.saved_plan_mode(thread("other", nil, { path = path })) == nil)
	vim.fn.delete(path)
	assert(Backend.saved_plan_mode(saved) == nil)
end)

test("reopening a plan chat restores its mode before revealing the composer", function()
	local path = vim.fn.tempname()
	vim.fn.writefile({
		vim.json.encode({ type = "session_meta", payload = { id = "chat" } }),
		vim.json.encode({ type = "turn_context", payload = { collaboration_mode = { mode = "plan" } } }),
	}, path)
	state.threads.chat = thread("chat", nil, { path = path })
	state.chat_win = vim.api.nvim_get_current_win()
	state.opts.command = "fake-codex"
	local original_start, original_wait, original_send = vim.fn.jobstart, vim.fn.jobwait, vim.api.nvim_chan_send
	local sent = {}
	vim.fn.jobstart = function() return 987 end
	vim.fn.jobwait = function() return { -1 } end
	vim.api.nvim_chan_send = function(_, text) table.insert(sent, text) end
	local ok, err = pcall(function()
		local session = internals.create_terminal("chat", "/repo", "chat", "chat")
		assert(session.restore_plan_mode)
		vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, { "› Ask Codex to do anything", "  ? for shortcuts" })
		assert(vim.wait(1000, function() return #sent == 1 end))
		assert(sent[1] == "\27[Z" and not session.initial_load_complete)
		vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, { "› Ask Codex to do anything", "  Plan mode (shift+tab to cycle)" })
		assert(vim.wait(1000, function() return session.initial_load_complete end))
		assert(#sent == 1 and not session.restore_plan_mode)

		-- A CLI that already restores Plan must not get toggled back to Default.
		state.session_tokens[session.notify_token] = nil
		state.sessions.chat = nil
		vim.api.nvim_buf_delete(session.buf, { force = true })
		session = internals.create_terminal("chat", "/repo", "chat", "chat")
		vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, { "› Ask Codex to do anything", "  Plan mode" })
		assert(vim.wait(1000, function() return session.initial_load_complete end))
		assert(#sent == 1, "restoration is idempotent")

		-- An explicit local switch wins even if the saved turn is still Plan.
		vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, { "› Ask Codex to do anything", "  ? for shortcuts" })
		vim.fn.jobwait = function() return { 0 } end
		session = internals.create_terminal("chat", "/repo", "chat", "chat")
		vim.fn.jobwait = function() return { -1 } end
		assert(session.plan_mode == false and not session.restore_plan_mode)
		vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, { "› Ask Codex to do anything", "  ? for shortcuts" })
		assert(vim.wait(1000, function() return session.initial_load_complete end))
		assert(#sent == 1, "do not undo an explicit switch to Default")
	end)
	vim.fn.jobstart, vim.fn.jobwait, vim.api.nvim_chan_send = original_start, original_wait, original_send
	vim.fn.delete(path)
	assert(ok, err)
end)

test("mode detection ignores transcript text and native dialogs", function()
	local session = terminal_session({ "Plan mode", "› Ask Codex to do anything", "  ? for shortcuts" })
	assert(internals.terminal_plan_mode(session) == false)
	vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, { "› Ask Codex to do anything" })
	assert(internals.terminal_plan_mode(session) == nil, "wait for the footer")
	vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, { "› 1. Plan mode", "  Enter to select" })
	assert(internals.terminal_plan_mode(session) == nil)
end)

local function with_initial_prompt(callback)
	local original_wait, original_send, original_defer = vim.fn.jobwait, vim.api.nvim_chan_send, vim.defer_fn
	local sent, scheduled = {}, {}
	local running = true
	vim.fn.jobwait = function() return { running and -1 or 0 } end
	vim.api.nvim_chan_send = function(_, text) table.insert(sent, text) end
	vim.defer_fn = function(fn, delay) table.insert(scheduled, { fn = fn, delay = delay }) end
	local ok, err = pcall(function()
		local session = terminal_session({ "› Ask Codex to do anything", "  ? for shortcuts" })
		session.job_id = 987
		local function step(lines)
			if lines then vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, lines) end
			local next_step = assert(table.remove(scheduled, 1), "expected a pending startup callback")
			next_step.fn()
		end
		callback(session, sent, scheduled, step, function() running = false end)
	end)
	vim.fn.jobwait, vim.api.nvim_chan_send, vim.defer_fn = original_wait, original_send, original_defer
	assert(ok, err)
end

test("new plan chats wait for the mode switch before sending the first prompt", function()
	with_initial_prompt(function(session, sent, scheduled, step)
		session.plan_mode = true
		internals.wait_for_composer(session, "investigate\nthe race", 0)
		assert(#sent == 1 and sent[1] == "\27[Z")
		for _ = 1, 5 do
			step()
			assert(#sent == 1, "a slow mode switch must not send the prompt or toggle again")
		end
		step({ "› Ask Codex to do anything", "  Plan mode" })
		assert(#sent == 2 and sent[2] == "\27[200~investigate\nthe race\27[201~")
		assert(#scheduled == 1 and scheduled[1].delay >= 250, "separate paste and submit")
		internals.wait_for_composer(session, "investigate\nthe race", 0)
		assert(#sent == 2 and #scheduled == 1, "send the initial prompt only once")
		step()
		assert(#sent == 3 and sent[3] == "\r" and #scheduled == 0)
	end)
end)

test("new plan chats wait for a footer and preserve an already selected Plan mode", function()
	with_initial_prompt(function(session, sent, _, step)
		session.plan_mode = true
		vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, { "› Ask Codex to do anything" })
		internals.wait_for_composer(session, "hello", 0)
		assert(#sent == 0, "the composer can render before the mode footer")
		step({ "› Ask Codex to do anything", "  Plan mode" })
		assert(#sent == 1 and sent[1] == "\27[200~hello\27[201~", "do not toggle Plan back to Default")
		step()
		assert(#sent == 2 and sent[2] == "\r")
	end)
end)

test("new chat startup waits for native menus and cancels submission when the CLI exits", function()
	with_initial_prompt(function(session, sent, scheduled, step, stop)
		vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, { "› 1. Trust this directory", "  Enter to select" })
		internals.wait_for_composer(session, "hello", 0)
		assert(#sent == 0)
		step({ "› Ask Codex to do anything", "  ? for shortcuts" })
		assert(#sent == 1 and sent[1] == "\27[200~hello\27[201~")
		stop()
		step()
		assert(#sent == 1 and #scheduled == 0)
	end)
end)

test("interrupted inline plan prompts bind without a completion notification", function()
	local session = pending("pending-1", "/plan investigate the race")
	state.active_id, state.selected_id = session.key, session.key
	listing({ thread("saved", "", { status = { type = "active" } }) })
	refresh()
	assert(#state.order == 1 and state.order[1].id == "pending-1", "do not publish an unidentified empty preview")
	listing({ thread("saved", "investigate the race", { status = { type = "idle" } }) })
	refresh()
	assert(session.id == "saved" and #state.order == 1 and not state.threads["pending-1"])
	refresh()
	assert(#state.order == 1 and state.active_id == "saved")
end)

test("typing an inline plan prompt retains identity before interruption", function()
	local session = pending("pending-1")
	session.initial_prompt = nil
	session.initial_load_complete = true
	session.buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_current_buf(session.buf)
	local prompt = "› /plan investigate the race"
	vim.api.nvim_buf_set_lines(session.buf, 0, -1, false, { prompt })
	vim.api.nvim_win_set_cursor(0, { 1, #prompt - 1 })
	internals.configure_terminal_buffer(session)
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(session.buf, "t")) do
		if mapping.lhs == "<CR>" then mapping.callback() end
	end
	listing({ thread("saved", "investigate the race", { status = { type = "idle" } }) })
	refresh()
	assert(session.id == "saved" and #state.order == 1)
end)

test("a failed background resume cannot block the pending terminal's canonical identity", function()
	local session = pending("pending-1")
	local failed = { id = "saved", key = "saved", notify_token = "failed",
		frontend_status = "active", active_elsewhere = true,
		buf = vim.api.nvim_create_buf(false, true) }
	state.sessions.saved, state.session_tokens.failed = failed, failed
	state.threads.saved = thread("saved")
	listing({ thread("saved", "hello", { status = { type = "active" } }) })
	refresh()
	assert(session.id == "saved" and state.sessions.saved == session)
	assert(#state.order == 1 and not state.threads["pending-1"])
	assert(not state.session_tokens.failed and not vim.api.nvim_buf_is_valid(failed.buf))
end)

test("wrapped terminal prompts bind uniquely without treating complete prompts as prefixes", function()
	local session = pending("pending-1", "investigate the refresh problem")
	local saved = thread("saved", session.initial_prompt .. " and fix the duplicates")
	assert(#Identity.matches(state.sessions, { saved }) == 0)
	session.initial_prompt_truncated = true
	assert(#Identity.matches(state.sessions, { saved }) == 1)
	local matches, unresolved = Identity.matches(state.sessions, {
		saved, thread("other", session.initial_prompt .. " in another window"),
	})
	assert(#matches == 0 and unresolved.saved and unresolved.other)
	listing({ saved })
	refresh()
	assert(session.id == "saved" and #state.order == 1)
end)

test("identity repair cannot replace another live terminal", function()
	local pending_session = pending("pending-1")
	local owner = { id = "saved", key = "saved", job_id = 123 }
	state.sessions.saved = owner
	local jobwait = vim.fn.jobwait
	vim.fn.jobwait = function() return { -1 } end
	local ok, err = pcall(function()
		internals.bind_session(pending_session, thread("saved"), true)
		assert(not pending_session.id and state.sessions.saved == owner)
		assert(#Identity.matches(internals.identity_sessions(), { thread("saved") }) == 0)
	end)
	vim.fn.jobwait = jobwait
	assert(ok, err)
end)

test("refresh preserves exited terminal status and retires a stale working default", function()
	for _, frontend in ipairs({ "closed", "error", "loading" }) do
		local session = { id = "saved", key = "saved", job_id = 987654321,
			default_status = "working", frontend_status = frontend }
		state.sessions.saved = session
		listing({ thread("saved", nil, { status = { type = "notLoaded" } }) })
		refresh()
		assert(session.default_status == "ready")
		assert(status_name(state.threads.saved) == (frontend == "error" and "error" or "closed"))
	end
end)

test("an unloaded conversation clears a stale external writer conflict", function()
	local session = { id = "saved", key = "saved", active_elsewhere = true, retry_after = math.huge }
	state.sessions.saved = session
	listing({ thread("saved", nil, { status = { type = "notLoaded" } }) })
	refresh()
	assert(not session.active_elsewhere and not session.retry_after)
	assert(status_name(state.threads.saved) == "closed")
end)

test("missing exited placeholders release their sessions and notification tokens", function()
	local session = pending("pending-1")
	listing({})
	refresh()
	refresh()
	refresh()
	assert(not state.threads[session.key] and not state.sessions[session.key])
	assert(not state.session_tokens[session.notify_token])
end)

test("status events arriving during identity reads survive list delivery", function()
	pending("pending-1", "/review")
	state.threads.saved = thread("saved", "review", { status = { type = "active" } })
	local backend = Backend.new({ on_notification = internals.handle_backend_notification })
	backend._defer = function(_, cb, ...) if cb then cb(...) end end
	backend.list_threads = function(_, _, cb)
		cb(nil, { thread("saved", "review", { status = { type = "active" } }) })
	end
	local read
	backend.read_thread = function(_, _, cb) read = cb end
	state.backend = backend
	refresh()
	assert(state.refreshing)
	runtime_status(backend, "saved", { type = "idle" })
	read(nil, { thread = thread("saved", "review", { turns = {
		{ items = { { type = "enteredReviewMode" } } },
	} }) })
	assert(not state.refreshing and #state.order == 1)
	assert(status_name(state.threads.saved) == "ready")
end)

test("resync replaces in-flight lists, repairs history and preserves live terminals", function()
	local old_list, new_list, old_dismissed
	listing({})
	local backend = state.backend
	backend.list_threads = function(_, params, cb)
		if params.archived then old_dismissed = cb else old_list = cb end
	end
	refresh()
	internals.refresh_dismissed_threads()
	local buf = vim.api.nvim_create_buf(false, true)
	local session = { id = "live", key = "live", job_id = 123, buf = buf }
	state.sessions.live = session
	local stopped = 0
	backend.stop = function() stopped = stopped + 1 end
	backend.start = function(_, cb) cb() end
	backend.list_threads = function(_, params, cb)
		assert(not params.useStateDbOnly, "resync must repair the persisted history index")
		new_list = cb
	end
	state.history_repaired = true
	local jobwait, jobstop = vim.fn.jobwait, vim.fn.jobstop
	vim.fn.jobwait = function() return { -1 } end
	vim.fn.jobstop = function() error("resync must not stop live terminals") end
	local ok, err = pcall(function()
		mode.resync()
		assert(stopped == 1 and state.refreshing and new_list)
		old_list(nil, { thread("stale") })
		old_dismissed(nil, { thread("stale-archive") })
		assert(state.refreshing and not state.threads.stale and not state.dismissed_threads["stale-archive"])
		new_list(nil, { thread("live", nil, { status = { type = "idle" } }) })
		assert(not state.refreshing and state.history_repaired and #state.order == 1)
		assert(state.sessions.live == session and vim.api.nvim_buf_is_valid(buf))
	end)
	vim.fn.jobwait, vim.fn.jobstop = jobwait, jobstop
	assert(ok, err)
end)

test("resync refreshes the dismissed tab and clears stale writer retry state", function()
	state.recents_tab = "dismissed"
	local session = { id = "saved", key = "saved", active_elsewhere = true, retry_after = math.huge }
	state.sessions.saved = session
	local active, dismissed = 0, 0
	state.backend = {
		stop = function() end,
		start = function(_, cb) cb() end,
		list_threads = function(_, params, cb)
			if params.archived then dismissed = dismissed + 1 else active = active + 1 end
			cb(nil, { thread(params.archived and "archive" or "saved") })
		end,
	}
	mode.resync()
	assert(active == 1 and dismissed == 1 and state.dismissed_threads.archive)
	assert(not session.active_elsewhere and not session.retry_after)
end)

test("late startup callbacks from before resync cannot mark the new connection unavailable", function()
	local starts = {}
	state.backend_ready = false
	state.backend = {
		stop = function() end,
		start = function(_, cb) table.insert(starts, cb) end,
		list_threads = function(_, _, cb) cb(nil, {}) end,
	}
	internals.start_backend()
	mode.resync()
	assert(#starts == 2)
	starts[2]()
	assert(state.backend_ready)
	starts[1]("old connection stopped")
	assert(state.backend_ready)
end)

reset()
vim.defer_fn = real_defer
print(string.format("Passed %d recents regression tests", count))
