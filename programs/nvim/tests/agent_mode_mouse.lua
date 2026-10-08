-- nvim --headless -u NONE -i NONE -l programs/nvim/tests/agent_mode_mouse.lua
-- Exercise actual mouse mappings and input-mode transitions in a child editor.
local root = vim.fn.getcwd() .. "/programs/nvim/lua/agent_mode/"
local child = vim.fn.jobstart({ vim.v.progpath, "--embed", "--headless", "-n", "-u", "NONE", "-i", "NONE" }, { rpc = true })
local function lua(code, args) return vim.rpcrequest(child, "nvim_exec_lua", code, args or {}) end
local function wait_for(code)
	if vim.wait(2000, function() return lua("return " .. code) end, 10) then return end
	error(code .. "\n" .. vim.inspect(lua([[
		return { mode = vim.api.nvim_get_mode(), mouse = vim.fn.getmousepos(), active = state.active_id,
			selected = state.selected_id, messages = vim.fn.execute('messages') }
	]])))
end
local function press(keys) vim.rpcrequest(child, "nvim_input", keys) end
local function click(target, line)
	local pos = lua([[
		local win, line = ...
		assert(win and vim.api.nvim_win_is_valid(win), "click target must exist")
		vim.cmd("redraw")
		local p = vim.fn.screenpos(win, line, 2)
		return { p.row - 1, p.col - 1 }
	]], { lua("return " .. target), line or 1 })
	assert(pos[1] >= 0 and pos[2] >= 0, "click target must be visible")
	vim.rpcrequest(child, "nvim_input_mouse", "left", "press", "", 0, pos[1], pos[2])
	vim.rpcrequest(child, "nvim_input_mouse", "left", "release", "", 0, pos[1], pos[2])
end
local ok, err = pcall(function()
	vim.rpcrequest(child, "nvim_ui_attach", 120, 40, { rgb = true })
	lua([[
		local root = ...
		for _, name in ipairs({ "backend", "history", "identity", "project", "sidebar", "docker" }) do
			package.preload["config.agent_mode." .. name] = function() return dofile(root .. name .. ".lua") end
		end
		mode = dofile(root .. "init.lua")
		internals = {}
		local visited = {}
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
		for _, fn in pairs(mode) do inspect(fn) end
		state = internals.state
		state.backend = {
			start = function(_, cb) cb(nil) end,
			stop = function() end,
			list_threads = function(_, _, cb) cb(nil, {}) end,
		}
		history_path = vim.fn.tempname()
		mode.setup({ history_path = history_path, sidebar_width = 32 })
		vim.o.mouse = "a"
	]], { root })
	lua([[
		state.project = { launch_cwd = "/repo", worktrees = { { path = "/repo", label = "repo" } } }
		for _, id in ipairs({ "first", "second" }) do
			state.threads[id] = { id = id, cwd = "/repo", preview = id, updatedAt = 1 }
		end
		internals.sort_threads()
		internals.ensure_ui()
		for _, id in ipairs({ "first", "second" }) do
			local buf = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_win_set_buf(state.chat_win, buf)
			vim.api.nvim_set_current_win(state.chat_win)
			local job = vim.fn.jobstart({ vim.fn.exepath("cat") }, { term = true })
			assert(job > 0)
			state.sessions[id] = { id = id, buf = buf, job_id = job, initial_load_complete = true }
		end
		state.selected_id, state.sidebar_level = "first", "runs"
		internals.render_sidebar()
		vim.api.nvim_set_current_win(state.sidebar_win)
	]])
	click("state.sidebar_win", lua("return state.cursor_rows.second"))
	wait_for("state.active_id == 'second' and vim.api.nvim_get_mode().mode == 't'")
	assert(lua("return vim.api.nvim_get_current_buf() == state.sessions.second.buf"))
	print("ok - clicking a recent chat without hovering opens it ready to type")

	-- The source terminal requests mouse input, as interactive agent TUIs do.
	lua([[vim.api.nvim_chan_send(vim.bo.channel, "\27[?1000h\27[?1006h\n")]])
	click("state.sidebar_win", lua("return state.cursor_rows.first"))
	wait_for("state.active_id == 'first' and vim.api.nvim_get_mode().mode == 't'")
	assert(lua("return vim.api.nvim_get_current_buf() == state.sessions.first.buf"))
	-- Let the hover-preview delay pass: it must not undo the requested focus.
	lua("vim.defer_fn(function() preview_delay_elapsed = true end, 250)")
	wait_for("preview_delay_elapsed == true")
	assert(lua("return state.sessions.first.reveal_focus and vim.api.nvim_get_mode().mode == 't'"))
	print("ok - clicking another recent chat leaves terminal input and retains typing focus")

	press("<C-\\><C-n>")
	wait_for("vim.api.nvim_get_mode().mode == 'nt'")
	click("state.chat_win")
	wait_for("vim.api.nvim_get_mode().mode == 't'")
	print("ok - clicking the conversation enters terminal input mode")

	press("<C-\\><C-n>")
	lua("internals.open_new_chat()")
	wait_for("state.composer ~= nil and vim.api.nvim_get_mode().mode == 'i'")
	press("<C-\\><C-n>")
	wait_for("vim.api.nvim_get_mode().mode == 'n'")
	click("state.composer.win")
	wait_for("vim.api.nvim_get_mode().mode == 'i'")
	press("typed prompt")
	wait_for("vim.api.nvim_buf_get_lines(state.composer.buf, 0, -1, false)[1] == 'typed prompt'")
	print("ok - clicking the prompt enters Insert mode and accepts text")

	click("state.sidebar_win", lua("return state.cursor_rows.second"))
	wait_for("state.active_id == 'second' and vim.api.nvim_get_mode().mode == 't'")
	print("ok - clicking a recent chat from the prompt enters terminal input mode")

	click("state.sidebar_win", lua("return state.group_rows['/repo']"))
	wait_for("vim.api.nvim_get_current_win() == state.sidebar_win and vim.api.nvim_get_mode().mode == 'n'")
	assert(lua("return state.sidebar_level == 'worktrees' and state.active_id == 'second'"))
	print("ok - clicking a worktree header selects it without opening a chat")

	lua("mode.leave()")
	click("vim.api.nvim_get_current_win()")
	wait_for("vim.api.nvim_get_mode().mode == 'n'")
	print("ok - editor clicks outside Agent Mode retain normal behavior")

	lua("internals.shutdown(); vim.fn.delete(history_path)")
end)
vim.fn.jobstop(child)
assert(ok, err)
