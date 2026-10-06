local Project = require("config.agent_mode.project")
local M = {}

function M.setup_highlights()
	local light = vim.o.background == "light"
	local function color(group, field, fallback)
		return vim.api.nvim_get_hl(0, { name = group, link = false })[field] or fallback
	end
	local accent = color("DiagnosticInfo", "fg", light and 0x315f87 or 0x89b4ca)
	vim.api.nvim_set_hl(0, "AgentModeWorktree", { fg = accent, bold = true })
	vim.api.nvim_set_hl(0, "AgentModeWorktreeBorder", { link = "Comment" })
	vim.api.nvim_set_hl(0, "AgentModeWorktreeBorderSelected", { fg = accent, bold = true })
	vim.api.nvim_set_hl(0, "AgentModeRunSelected", { fg = accent, bold = true })
	vim.api.nvim_set_hl(0, "AgentModePort", { fg = accent, underline = true })
	vim.api.nvim_set_hl(0, "AgentModeMuted", { link = "Comment" })
	vim.api.nvim_set_hl(0, "AgentModeKey", { fg = color("Special", "fg", accent) })
	for name, value in pairs({
		Enter = accent,
		Up = color("DiagnosticOk", "fg", light and 0x457a42 or 0xa9c490),
		Down = color("DiagnosticError", "fg", light and 0xb34040 or 0xe49b93),
	}) do
		vim.api.nvim_set_hl(0, "AgentModeAction" .. name, { fg = value, bold = true })
		vim.api.nvim_set_hl(0, "AgentModeAction" .. name .. "Selected", { fg = value, bold = true, underline = true })
	end
end

function M.groups(state)
	local groups, by_path = {}, {}
	for _, worktree in ipairs(state.project and state.project.worktrees or {}) do
		local group = { worktree = worktree, threads = {} }
		table.insert(groups, group)
		by_path[worktree.path] = group
	end
	for _, thread in ipairs(state.order) do
		local worktree = Project.worktree_for(state.project, thread.cwd or "")
		if worktree and by_path[worktree.path] then
			table.insert(by_path[worktree.path].threads, thread)
		end
	end
	if not by_path[state.sidebar_worktree] then
		state.sidebar_worktree = state.project and state.project.current_worktree
		if not by_path[state.sidebar_worktree] then
			state.sidebar_worktree = groups[1] and groups[1].worktree.path
		end
		state.sidebar_level = nil
		state.sidebar_action = 1
	end
	state.sidebar_level = state.sidebar_level or (#groups > 1 and "worktrees" or "runs")
	local selected = by_path[state.sidebar_worktree]
	-- Follow a run selected by search, restore, or a newly launched chat.
	if state.sidebar_level == "runs" and state.selected_id then
		for _, group in ipairs(groups) do
			for _, thread in ipairs(group.threads) do
				if thread.id == state.selected_id then
					state.sidebar_worktree, selected = group.worktree.path, group
				end
			end
		end
	end
	return groups, selected
end

-- Keep the picker above Agent Mode's overlay, independent of vim.ui.select
-- providers (the default numbered prompt cannot navigate with arrow keys).
function M.select_worktree(items, options, callback)
	if #items == 0 then callback(nil); return end
	local origin = vim.api.nvim_get_current_win()
	vim.cmd("stopinsert")
	local buf = vim.api.nvim_create_buf(false, true)
	local lines, width = {}, 48
	for _, item in ipairs(items) do
		local line = options.format_item(item):gsub("[\r\n]", " ")
		table.insert(lines, line)
		width = math.max(width, vim.fn.strdisplaywidth(line))
	end
	width = math.max(1, math.min(width, vim.o.columns - 4))
	local height = math.max(1, math.min(#lines, 16, vim.o.lines - 4))
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].modifiable = "nofile", "wipe", false
	vim.bo[buf].filetype = "agentmodeworktrees"
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor", row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)), width = width, height = height,
		style = "minimal", border = "rounded", title = " " .. options.prompt .. " ", title_pos = "center",
		footer = " ↑/↓ Tab: move  Enter: select  Esc: cancel ", footer_pos = "center", zindex = 100,
	})
	vim.wo[win].wrap, vim.wo[win].cursorline = false, true
	vim.wo[win].scrolloff, vim.wo[win].sidescrolloff = 0, 0
	vim.wo[win].winhighlight = "NormalFloat:Normal,FloatBorder:DiagnosticInfo,CursorLine:PmenuSel"
	vim.api.nvim_win_set_cursor(win, { math.max(1, math.min(options.selected or 1, #items)), 0 })
	local finished = false
	local group = vim.api.nvim_create_augroup("AgentModeWorktreePicker" .. buf, { clear = true })
	local function finish(index)
		if finished then return end
		finished = true
		vim.api.nvim_del_augroup_by_id(group)
		local focused = vim.api.nvim_get_current_win() == win
		if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
		if focused and vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end
		callback(index and items[index] or nil, index)
	end
	local keys = { buffer = buf, silent = true, nowait = true }
	local function move(delta)
		local row = vim.api.nvim_win_get_cursor(win)[1]
		vim.api.nvim_win_set_cursor(win, { (row - 1 + delta) % #items + 1, 0 })
	end
	for _, key in ipairs({ "j", "<Down>", "<Tab>", "<C-n>" }) do
		vim.keymap.set("n", key, function() move(1) end, keys)
	end
	for _, key in ipairs({ "k", "<Up>", "<S-Tab>", "<C-p>" }) do
		vim.keymap.set("n", key, function() move(-1) end, keys)
	end
	vim.keymap.set("n", "<CR>", function() finish(vim.api.nvim_win_get_cursor(win)[1]) end, keys)
	for _, key in ipairs({ "<Esc>", "<C-c>", "q" }) do
		vim.keymap.set("n", key, function() finish(nil) end, keys)
	end
	vim.api.nvim_create_autocmd("WinClosed", {
		group = group, pattern = tostring(win), once = true,
		callback = function() vim.schedule(function() finish(nil) end) end,
	})
	vim.api.nvim_create_autocmd("BufLeave", {
		group = group, buffer = buf, once = true,
		callback = function() vim.schedule(function() finish(nil) end) end,
	})
end

function M.confirm_remove(worktree, callback)
	local buf = vim.api.nvim_create_buf(false, true)
	local width = math.max(1, math.min(68, vim.o.columns - 4))
	local lines = {
		"Remove this worktree?", "", worktree.path, "",
		worktree.branch and ("Keep local branch: " .. worktree.branch)
			or "Detached commits will be saved to a local branch.",
		"Stop and dismiss all Codex sessions in this worktree.",
		"", "  [ Cancel ]    Delete worktree",
	}
	if worktree.docker then
		table.insert(lines, 6, "Delete its Docker containers, networks, volumes and images.")
		table.insert(lines, 7, "All Docker data for this worktree will be erased.")
	end
	local action_row = #lines
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].modifiable = "nofile", "wipe", false
	local height = 0
	for _, line in ipairs(lines) do height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width)) end
	height = math.min(height, math.max(1, vim.o.lines - 4))
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor", row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)), width = width, height = height,
		style = "minimal", border = "rounded", title = " Remove worktree ", title_pos = "center", zindex = 100,
	})
	vim.wo[win].wrap = true
	vim.wo[win].winhighlight = "NormalFloat:Normal,FloatBorder:DiagnosticWarn,FloatTitle:DiagnosticWarn"
	local selected, finished = false, false
	local ns = vim.api.nvim_create_namespace("AgentModeConfirmRemove")
	local function render()
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, action_row - 1, action_row, false, { selected and "    Cancel    [ Delete worktree ]" or "  [ Cancel ]    Delete worktree" })
		vim.bo[buf].modifiable = false
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		vim.api.nvim_buf_add_highlight(buf, ns, "Title", 0, 0, -1)
		vim.api.nvim_buf_add_highlight(buf, ns, "DiagnosticOk", 4, 0, -1)
		if worktree.docker then
			vim.api.nvim_buf_add_highlight(buf, ns, "DiagnosticError", 5, 0, -1)
			vim.api.nvim_buf_add_highlight(buf, ns, "DiagnosticError", 6, 0, -1)
		end
		vim.api.nvim_buf_add_highlight(buf, ns, selected and "DiagnosticError" or "DiagnosticInfo", action_row - 1,
			selected and 14 or 2, selected and -1 or 12)
		vim.api.nvim_win_set_cursor(win, { action_row, selected and 14 or 2 })
	end
	local function finish(confirmed)
		if finished then return end
		finished = true
		if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
		callback(confirmed)
	end
	local options = { buffer = buf, silent = true, nowait = true }
	for _, key in ipairs({ "h", "k", "<Left>", "<Up>" }) do
		vim.keymap.set("n", key, function() selected = false; render() end, options)
	end
	for _, key in ipairs({ "l", "j", "<Right>", "<Down>" }) do
		vim.keymap.set("n", key, function() selected = true; render() end, options)
	end
	vim.keymap.set("n", "<Tab>", function() selected = not selected; render() end, options)
	for _, key in ipairs({ "<Esc>", "q" }) do
		vim.keymap.set("n", key, function() finish(false) end, options)
	end
	vim.keymap.set("n", "<CR>", function() finish(selected) end, options)
	vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(win), once = true, callback = function()
		if not finished then finished = true; callback(false) end
	end })
	render()
end

return M
