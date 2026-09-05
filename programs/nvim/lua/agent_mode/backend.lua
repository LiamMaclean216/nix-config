local Backend = {}

Backend.__index = Backend

local unpack_args = table.unpack or unpack

local function is_nil(value)
	return value == nil or (vim.NIL ~= nil and value == vim.NIL)
end

local function normalize(value)
	if is_nil(value) then
		return nil
	end

	if type(value) ~= "table" then
		return value
	end

	local copy = {}
	for key, item in pairs(value) do
		if not is_nil(item) then
			copy[key] = normalize(item)
		end
	end
	return copy
end

local function pack(...)
	return { n = select("#", ...), ... }
end

local function stop_timer(timer)
	if not timer then
		return
	end
	pcall(timer.stop, timer)
	pcall(timer.close, timer)
end

local function error_message(err)
	if type(err) == "string" then
		return err
	end

	if type(err) == "table" then
		local message = err.message or err.error
		if message then
			if err.code ~= nil then
				return string.format("%s (code %s)", tostring(message), tostring(err.code))
			end
			return tostring(message)
		end

		local ok, inspected = pcall(vim.inspect, err)
		if ok then
			return inspected
		end
	end

	return tostring(err)
end

local function thread_timestamp(thread)
	local recency = normalize(thread.recencyAt)
	local updated = normalize(thread.updatedAt)
	return tonumber(recency) or tonumber(updated) or 0
end

local function user_visible_thread(thread)
	if type(thread) ~= "table" or type(thread.id) ~= "string" or thread.id == "" then
		return false
	end
	-- Apply the same rule to list responses and notifier lookups. Helpers can
	-- inherit the CLI source and notifier, so neither proves a user conversation.
	if normalize(thread.ephemeral) == true or normalize(thread.parentThreadId) then
		return false
	end
	local classification = normalize(thread.threadSource)
	if classification and classification ~= "user" then
		return false
	end
	local source = normalize(thread.source)
	if source == "appServer" then
		return classification == "user"
	end
	return source == "cli" or source == "vscode"
end

Backend.user_visible_thread = user_visible_thread

function Backend.new(opts)
	opts = opts or {}

	local self = setmetatable({}, Backend)
	self.command = opts.command or "codexvenv"
	self.connector = opts.connector or "agent-mode-connect"
	self.cwd = opts.cwd
	self.env = opts.env
	self.on_error = opts.on_error
	self.on_notification = opts.on_notification
	self.stderr_limit = opts.stderr_limit or (64 * 1024)
	self.request_timeout = opts.request_timeout or 10000

	self.process = nil
	self.running = false
	self.ready = false
	self.starting = false
	self.stderr = ""
	self.last_error = nil

	self._generation = 0
	self._next_id = 1
	self._pending = {}
	self._ready_waiters = {}
	self._stdout_buffer = ""
	self._status_revision = 0
	self._statuses = {}

	return self
end

function Backend:_defer(callback, ...)
	if type(callback) ~= "function" then
		return
	end

	local args = pack(...)
	vim.schedule(function()
		local ok, err = xpcall(function()
			callback(unpack_args(args, 1, args.n))
		end, debug.traceback)
		if not ok then
			self:_report_error("Agent Mode backend callback failed: " .. tostring(err))
		end
	end)
end

function Backend:_report_error(message)
	message = error_message(message)
	self.last_error = message

	if type(self.on_error) == "function" then
		vim.schedule(function()
			local ok, err = pcall(self.on_error, message)
			if not ok then
				vim.notify("Agent Mode error handler failed: " .. tostring(err), vim.log.levels.ERROR)
			end
		end)
	else
		vim.schedule(function()
			vim.notify(message, vim.log.levels.ERROR)
		end)
	end
end

function Backend:_finish_start(err)
	local waiters = self._ready_waiters
	self._ready_waiters = {}

	for _, callback in ipairs(waiters) do
		self:_defer(callback, err)
	end
end

function Backend:_fail_pending(err)
	local pending = self._pending
	self._pending = {}

	for _, request in pairs(pending) do
		stop_timer(request.timer)
		self:_defer(request.callback, err)
	end
end

function Backend:_append_stderr(chunk)
	if not chunk or chunk == "" then
		return
	end

	self.stderr = self.stderr .. chunk
	if #self.stderr > self.stderr_limit then
		self.stderr = self.stderr:sub(#self.stderr - self.stderr_limit + 1)
	end
end

function Backend:_command_args()
	local args = type(self.connector) == "table" and vim.deepcopy(self.connector) or { self.connector }
	if type(self.command) == "table" then
		for _, part in ipairs(self.command) do
			table.insert(args, part)
		end
	else
		table.insert(args, self.command)
	end

	return args
end

function Backend:_send(message)
	if not self.process or not self.running then
		return false, "Codex metadata server is not running"
	end

	local encoded_ok, encoded = pcall(vim.json.encode, message)
	if not encoded_ok then
		return false, "Could not encode Codex request: " .. tostring(encoded)
	end

	local write_ok, write_error = pcall(self.process.write, self.process, encoded .. "\n")
	if not write_ok then
		return false, "Could not write to Codex metadata server: " .. tostring(write_error)
	end

	return true
end

function Backend:_request(method, params, callback)
	if method ~= "initialize"
		and method ~= "thread/list"
		and method ~= "thread/search"
		and method ~= "thread/read"
		and method ~= "thread/archive"
		and method ~= "thread/unarchive"
		and method ~= "turn/interrupt"
	then
		self:_defer(callback, "Unsupported metadata request: " .. tostring(method))
		return
	end

	local id = self._next_id
	self._next_id = self._next_id + 1
	local key = tostring(id)
	local request = {
		callback = callback,
		method = method,
	}
	self._pending[key] = request
	request.timer = vim.uv.new_timer()
	local timeout = method == "initialize" and 45000 or self.request_timeout
	request.timer:start(timeout, 0, vim.schedule_wrap(function()
		if self._pending[key] ~= request then
			return
		end
		self._pending[key] = nil
		stop_timer(request.timer)
		self:_defer(callback, string.format("Codex %s timed out after %.1fs", method, timeout / 1000))
	end))

	local sent, err = self:_send({
		id = id,
		method = method,
		params = params,
	})
	if not sent then
		self._pending[key] = nil
		stop_timer(request.timer)
		self:_defer(callback, err)
	end
end

function Backend:_handle_message(message)
	if type(message) ~= "table" then
		return
	end
	if is_nil(message.id) then
		local params = normalize(message.params) or {}
		local thread = message.method == "thread/started" and params.thread or nil
		local id = thread and thread.id or params.threadId
		local status = thread and thread.status or (message.method == "thread/status/changed" and params.status)
		if id and status then
			self._status_revision = self._status_revision + 1
			self._statuses[id] = { status = status, revision = self._status_revision }
		end
		self:_defer(self.on_notification, message.method, params)
		return
	end
	-- Server requests are for an owning terminal, never responses to our reads.
	if message.method then
		return
	end

	local key = tostring(message.id)
	local request = self._pending[key]
	if not request then
		return
	end

	self._pending[key] = nil
	stop_timer(request.timer)
	if not is_nil(message.error) then
		self:_defer(request.callback, "Codex " .. request.method .. " failed: " .. error_message(message.error))
		return
	end

	self:_defer(request.callback, nil, normalize(message.result))
end

function Backend:_handle_line(line)
	line = line:gsub("\r$", "")
	if line:match("^%s*$") then
		return
	end

	local ok, message = pcall(vim.json.decode, line)
	if not ok then
		self:_report_error("Could not decode Codex metadata response: " .. tostring(message))
		return
	end

	self:_handle_message(message)
end

function Backend:_feed_stdout(chunk)
	if not chunk or chunk == "" then
		return
	end

	self._stdout_buffer = self._stdout_buffer .. chunk
	while true do
		local newline = self._stdout_buffer:find("\n", 1, true)
		if not newline then
			break
		end

		local line = self._stdout_buffer:sub(1, newline - 1)
		self._stdout_buffer = self._stdout_buffer:sub(newline + 1)
		self:_handle_line(line)
	end
end

function Backend:_flush_stdout()
	if self._stdout_buffer == "" then
		return
	end

	local line = self._stdout_buffer
	self._stdout_buffer = ""
	self:_handle_line(line)
end

function Backend:_exit_description(result)
	local code = result and result.code or "unknown"
	local signal = result and result.signal or 0
	local message = string.format("Codex metadata server exited (code %s, signal %s)", tostring(code), tostring(signal))
	local stderr = self.stderr:gsub("^%s+", ""):gsub("%s+$", "")
	if stderr ~= "" then
		message = message .. ": " .. stderr
	end
	return message
end

function Backend:_handle_exit(generation, result)
	if generation ~= self._generation then
		return
	end

	self:_flush_stdout()
	local err = self:_exit_description(result)
	self._generation = self._generation + 1
	self.process = nil
	self.running = false
	self.ready = false
	self.starting = false
	self:_fail_pending(err)
	self:_finish_start(err)
	self:_report_error(err)
end

function Backend:_abort_start(generation, err)
	if generation ~= self._generation then
		return
	end

	local process = self.process
	self._generation = self._generation + 1
	self.process = nil
	self.running = false
	self.ready = false
	self.starting = false
	self:_fail_pending(err)
	self:_finish_start(err)
	self:_report_error(err)

	if process then
		pcall(process.kill, process, 15)
	end
end

function Backend:_spawn()
	self._generation = self._generation + 1
	local generation = self._generation
	self.running = true
	self.ready = false
	self.starting = true
	self.stderr = ""
	self._stdout_buffer = ""
	self._statuses = {}
	self._status_revision = 0

	local options = {
		stdin = true,
		text = true,
		cwd = self.cwd,
		env = self.env,
		stdout = function(err, data)
			vim.schedule(function()
				if generation ~= self._generation then
					return
				end
				if err then
					self:_report_error("Could not read Codex metadata response: " .. tostring(err))
				end
				if data then
					self:_feed_stdout(data)
				else
					self:_flush_stdout()
				end
			end)
		end,
		stderr = function(err, data)
			vim.schedule(function()
				if generation ~= self._generation then
					return
				end
				if err then
					self:_append_stderr(tostring(err) .. "\n")
				end
				self:_append_stderr(data)
			end)
		end,
	}

	local spawned, process = pcall(vim.system, self:_command_args(), options, function(result)
		vim.schedule(function()
			self:_handle_exit(generation, result)
		end)
	end)
	if not spawned then
		local err = "Could not start Codex metadata server: " .. tostring(process)
		self.process = nil
		self.running = false
		self.ready = false
		self.starting = false
		self:_finish_start(err)
		self:_report_error(err)
		return
	end

	self.process = process
	self:_request("initialize", {
		clientInfo = {
			name = "Neovim Agent Mode",
			title = "Neovim Agent Mode",
			version = "1.0.0",
		},
		capabilities = {
			experimentalApi = true,
			requestAttestation = false,
		},
	}, function(err)
		if generation ~= self._generation then
			return
		end

		if err then
			self:_abort_start(generation, "Could not initialize Codex metadata server: " .. error_message(err))
			return
		end

		local sent, send_error = self:_send({ method = "initialized" })
		if not sent then
			self:_abort_start(generation, send_error)
			return
		end

		self.starting = false
		self.ready = true
		self:_finish_start(nil)
	end)
end

function Backend:start(on_ready)
	if self.ready and self.process then
		self:_defer(on_ready, nil)
		return
	end

	if type(on_ready) == "function" then
		table.insert(self._ready_waiters, on_ready)
	end

	if self.starting or (self.running and self.process) then
		return
	end

	self:_spawn()
end

local function fetch_threads(self, method, params, callback)
	if type(params) == "function" and callback == nil then
		callback = params
		params = nil
	end
	if is_nil(params) then
		params = {}
	end

	local request_params = {
		limit = 100,
		sortKey = "recency_at",
		sortDirection = "desc",
		sourceKinds = { "cli", "vscode", "appServer" },
	}
	for key, value in pairs(params) do
		request_params[key] = normalize(value)
	end

	local threads = {}
	local seen_ids = {}
	local seen_cursors = {}
	local finished = false
	local snapshot_revision = self._status_revision

	local function finish(err)
		if finished then
			return
		end
		finished = true

		if err then
			self:_defer(callback, err)
			return
		end

		table.sort(threads, function(left, right)
			local left_timestamp = thread_timestamp(left)
			local right_timestamp = thread_timestamp(right)
			if left_timestamp ~= right_timestamp then
				return left_timestamp > right_timestamp
			end

			local left_updated = tonumber(left.updatedAt) or 0
			local right_updated = tonumber(right.updatedAt) or 0
			if left_updated ~= right_updated then
				return left_updated > right_updated
			end

			return tostring(left.id or "") < tostring(right.id or "")
		end)
		self:_defer(function()
			-- Reconcile at delivery: status events can arrive even after the last
			-- page is processed while this callback is waiting on the scheduler.
			for _, thread in ipairs(threads) do
				local live = self._statuses[thread.id]
				if live and live.revision > snapshot_revision then
					thread.status = normalize(live.status)
				end
			end
			if type(callback) == "function" then
				callback(nil, threads)
			end
		end)
	end

	local fetch_page
	fetch_page = function(cursor)
		if finished then
			return
		end

		local page_params = normalize(request_params)
		page_params.cursor = normalize(cursor)
		self:_request(method, page_params, function(err, result)
			if err then
				finish(err)
				return
			end

			if type(result) ~= "table" then
				finish("Codex " .. method .. " returned an invalid response")
				return
			end

			local data = normalize(result.data)
			if data ~= nil and type(data) ~= "table" then
				finish("Codex " .. method .. " returned invalid thread data")
				return
			end

			for _, item in ipairs(data or {}) do
				local thread = method == "thread/search" and normalize(item.thread) or item
				if type(thread) ~= "table" then
					finish("Codex " .. method .. " returned invalid thread data")
					return
				end
				if user_visible_thread(thread) and not seen_ids[thread.id] then
					seen_ids[thread.id] = true
					table.insert(threads, thread)
				end
			end

			local next_cursor = normalize(result.nextCursor)
			if next_cursor == nil or next_cursor == "" then
				finish(nil)
				return
			end

			next_cursor = tostring(next_cursor)
			if seen_cursors[next_cursor] then
				finish("Codex " .. method .. " returned a repeated pagination cursor")
				return
			end
			seen_cursors[next_cursor] = true
			fetch_page(next_cursor)
		end)
	end

	self:start(function(err)
		if err then
			finish(err)
			return
		end
		fetch_page(normalize(request_params.cursor))
	end)
end

function Backend:list_threads(params, callback)
	fetch_threads(self, "thread/list", params, callback)
end

function Backend:search_threads(params, callback)
	fetch_threads(self, "thread/search", params, callback)
end

function Backend:read_thread(thread_id, callback, options)
	if not thread_id or thread_id == "" then
		self:_defer(callback, "A thread ID is required")
		return
	end

	self:start(function(err)
		if err then
			self:_defer(callback, err)
			return
		end
		self:_request("thread/read", {
			threadId = thread_id,
			includeTurns = not (options and options.summary_only),
		}, callback)
	end)
end

local function active_turn_id(result)
	local thread = result and normalize(result.thread)
	if type(thread) ~= "table" or type(thread.turns) ~= "table" then
		return nil, "Codex thread/read returned invalid turn data"
	end
	for _, turn in ipairs(thread.turns) do
		if turn.status == "inProgress" then
			return turn.id
		end
	end
end

function Backend:interrupt_thread(thread_id, callback)
	-- Read live turns: the recents snapshot can lag behind a turn starting or
	-- finishing, and disconnecting a remote terminal does not stop daemon work.
	self:read_thread(thread_id, function(err, result)
		if err then
			callback(err)
			return
		end
		local turn_id, read_err = active_turn_id(result)
		if read_err or not turn_id then
			callback(read_err)
			return
		end
		self:_request("turn/interrupt", { threadId = thread_id, turnId = turn_id }, function(interrupt_err)
			if not interrupt_err then
				callback(nil)
				return
			end
			-- Completion can win the race with interruption. Only proceed when a
			-- fresh read confirms that no turn is still running.
			self:read_thread(thread_id, function(check_err, latest)
				local active_id, latest_err = active_turn_id(latest)
				callback((check_err or latest_err or active_id) and interrupt_err or nil)
			end)
		end)
	end)
end

local function change_archived_state(self, method, thread_id, callback)
	if not thread_id or thread_id == "" then
		self:_defer(callback, "A thread ID is required")
		return
	end

	self:start(function(err)
		if err then
			self:_defer(callback, err)
			return
		end
		self:_request(method, { threadId = thread_id }, callback)
	end)
end

function Backend:archive_thread(thread_id, callback)
	change_archived_state(self, "thread/archive", thread_id, callback)
end

function Backend:unarchive_thread(thread_id, callback)
	change_archived_state(self, "thread/unarchive", thread_id, callback)
end

function Backend:stop()
	local process = self.process
	local was_active = process ~= nil or self.running or self.starting
	self._generation = self._generation + 1
	self.process = nil
	self.running = false
	self.ready = false
	self.starting = false
	self._stdout_buffer = ""

	if was_active then
		local err = "Codex metadata server stopped"
		self:_fail_pending(err)
		self:_finish_start(err)
	end

	if process then
		pcall(process.kill, process, 15)
	end
end

return Backend
