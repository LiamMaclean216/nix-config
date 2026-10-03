-- nvim --headless -u NONE -i NONE -l programs/nvim/tests/agent_mode_worktree_picker.lua
-- A child Neovim runs its input loop so insert-mode transitions use real keys.
local root = vim.fn.getcwd() .. "/programs/nvim/lua/agent_mode/"
local child = vim.fn.jobstart({ vim.v.progpath, "--embed", "--headless", "-n", "-u", "NONE", "-i", "NONE" }, { rpc = true })
local function lua(code, args) return vim.rpcrequest(child, "nvim_exec_lua", code, args or {}) end
local function press(keys)
	vim.rpcrequest(child, "nvim_input", keys)
end
local function wait_for(code)
	assert(vim.wait(2000, function() return lua("return " .. code) end, 10), code)
end
local ok, err = pcall(function()
	lua([[
		local root = ...
		package.preload["config.agent_mode.project"] = function() return dofile(root .. "project.lua") end
		picker = dofile(root .. "sidebar.lua")
		origin = vim.api.nvim_get_current_win()
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "draft" })
		items = {}
		for index = 1, 25 do items[index] = { label = "worktree " .. index } end
		function open_picker()
			local inserting = vim.api.nvim_get_mode().mode == "i"
			picker.select_worktree(items, {
				prompt = "Select worktree:", selected = 2,
				format_item = function(item) return item.label end,
			}, function(item, index)
				calls = (calls or 0) + 1
				selected = index
				if inserting then vim.schedule(function() vim.cmd("startinsert") end) end
			end)
			win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
		end
		vim.keymap.set({ "n", "i" }, "<C-w>", open_picker, { buffer = true })
	]], { root })
	press("i<C-w>")
	wait_for("win ~= nil and vim.api.nvim_get_mode().mode == 'n'")
	assert(lua("return vim.api.nvim_win_get_config(win).zindex == 100"))
	press("<Down><Tab><Up><S-Tab><CR>")
	wait_for("calls == 1 and vim.api.nvim_get_mode().mode == 'i'")
	assert(lua("return selected == 2 and vim.api.nvim_get_current_win() == origin"))
	assert(lua("return not vim.api.nvim_buf_is_valid(buf)"))
	print("ok - insert-mode picker accepts navigation and Enter and restores typing")

	press("<C-w><Up><Up><CR>")
	wait_for("calls == 2 and vim.api.nvim_get_mode().mode == 'i'")
	assert(lua("return selected == 25"))
	assert(lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == 'draft'"))
	print("ok - navigation wraps and scrolls through long lists without changing the draft")

	press("<C-w><Down><Esc>")
	wait_for("calls == 3 and vim.api.nvim_get_mode().mode == 'i'")
	assert(lua("return selected == nil and not vim.api.nvim_buf_is_valid(buf)"))
	print("ok - Escape cancels and cleans up the picker")

	press("<Esc><C-w>")
	wait_for("vim.bo.filetype == 'agentmodeworktrees'")
	lua("vim.api.nvim_set_current_win(origin)")
	wait_for("calls == 4")
	assert(lua("return selected == nil and not vim.api.nvim_win_is_valid(win)"))
	assert(lua("return vim.api.nvim_get_current_win() == origin"))
	print("ok - leaving the picker cancels without stealing focus")

	press("<C-w>")
	wait_for("vim.bo.filetype == 'agentmodeworktrees'")
	lua("vim.api.nvim_win_close(win, true)")
	wait_for("calls == 5")
	assert(lua("return selected == nil and not vim.api.nvim_buf_is_valid(buf)"))
	print("ok - external close cancels once and removes the buffer")
end)
vim.fn.jobstop(child)
assert(ok, err)
