local Backend = require("config.agent_mode.backend")
local History = require("config.agent_mode.history")
local Identity = require("config.agent_mode.identity")
local Project = require("config.agent_mode.project")
local Sidebar = require("config.agent_mode.sidebar")
local Docker = require("config.agent_mode.docker")

local M = {}

local defaults = {
	command = "codexvenv",
	launcher = "agent-mode-chat",
	keys = {
		new_chat = "<C-c>",
		recents = "<F10>",
	},
	history_limit = 100,
	history_write_delay = 0,
	refresh_interval = 2500,
	preview_delay = 150,
	preview_loading_timeout = 5000,
	preload_concurrency = 2,
	sidebar_width = 40,
	connector = "agent-mode-connect",
}

local state = {
	setup = false,
	shutting_down = false,
	project = nil,
	backend = nil,
	backend_ready = false,
	refreshing = false,
	refresh_generation = 0,
	threads = {},
	active_order = {},
	dismissed_threads = {},
	dismissed_order = {},
	dismissed_refreshing = false,
	dismiss_pending = {},
	fork_pending = {},
	move_pending = {},
	recents_tab = "active",
	search_term = nil,
	search = nil,
	filter = nil,
	selected_ids = {},
	order = {},
	selected_id = nil,
	sidebar_level = nil,
	sidebar_worktree = nil,
	sidebar_action = 1,
	docker = {},
	active_id = nil,
	sessions = {},
	session_tokens = {},
	session_sequence = 0,
	preload_scheduled = false,
	pending_sequence = 0,
	activity_clock = 0,
	new_worktree = false,
	new_worktree_name = nil,
	new_target = 1,
	tab = nil,
	origin_win = nil,
	editor_options = nil,
	chat_buf = nil,
	sidebar_buf = nil,
	sidebar_win = nil,
	chat_win = nil,
	placeholder_buf = nil,
	composer = nil,
	prompt_history = nil,
	auto_open_latest = false,
	refresh_timer = nil,
	preview_timer = nil,
	working_animation_timer = nil,
	working_animation_frame = 0,
	mousemoveevent_restore = nil,
	guicursor_restore = nil,
	notify_timer = nil,
	notify_path = nil,
	notify_offset = 0,
	notify_fragment = "",
	notifier_enabled = false,
	last_backend_error = nil,
	history_repaired = false,
}

local namespace = vim.api.nvim_create_namespace("AgentMode")
local working_namespace = vim.api.nvim_create_namespace("AgentModeWorking")
local working_labels = {}
local codex_backtab = "\27[Z"
local select_sidebar_row

local function valid_buf(buf)
	return buf and vim.api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
	return win and vim.api.nvim_win_is_valid(win)
end

local function valid_tab(tab)
	return tab and vim.api.nvim_tabpage_is_valid(tab)
end

local function is_null(value)
	return value == nil or value == vim.NIL
end

local function normalize(value)
	return is_null(value) and nil or value
end

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Agent Mode" })
end

local function stop_timer(timer)
	if not timer then
		return
	end
	pcall(timer.stop, timer)
	pcall(timer.close, timer)
end

local function enable_mouse_hover()
	if state.mousemoveevent_restore == nil then
		state.mousemoveevent_restore = vim.o.mousemoveevent
	end
	vim.o.mousemoveevent = true
end

local function restore_mouse_hover()
	if state.mousemoveevent_restore == nil then
		return
	end
	vim.o.mousemoveevent = state.mousemoveevent_restore
	state.mousemoveevent_restore = nil
end

local function restore_sidebar_cursor()
	if state.guicursor_restore ~= nil then
		vim.o.guicursor = state.guicursor_restore
		state.guicursor_restore = nil
	end
end

local function hide_sidebar_cursor()
	if vim.api.nvim_get_current_win() ~= state.sidebar_win
		or vim.api.nvim_get_current_buf() ~= state.sidebar_buf
	then
		return
	end
	if state.guicursor_restore == nil then
		state.guicursor_restore = vim.o.guicursor
	end
	-- A transparent cursor highlight hides the native cursor in the TUI too.
	-- Leave command-line and insert cursors available for prompts.
	vim.api.nvim_set_hl(0, "AgentModeHiddenCursor", { blend = 100 })
	local prefix = state.guicursor_restore ~= "" and state.guicursor_restore .. "," or ""
	vim.o.guicursor = prefix .. "n-v-ve-o:AgentModeHiddenCursor/AgentModeHiddenCursor"
end

local function handle_sidebar_hover()
	local mouse = vim.fn.getmousepos()
	if mouse.winid == state.sidebar_win and select_sidebar_row then
		select_sidebar_row(mouse.line)
	end
end

local function handle_input_click()
	if not valid_tab(state.tab) or vim.api.nvim_get_current_tabpage() ~= state.tab then
		return "<LeftMouse>"
	end
	local mouse = vim.fn.getmousepos()
	if not valid_win(mouse.winid) or mouse.winrow < 1 or mouse.wincol < 1
		or mouse.winrow > vim.api.nvim_win_get_height(mouse.winid)
		or mouse.wincol > vim.api.nvim_win_get_width(mouse.winid)
	then
		return "<LeftMouse>"
	end
	local buf = vim.api.nvim_win_get_buf(mouse.winid)
	local terminal = vim.bo[buf].buftype == "terminal"
		and (mouse.winid == state.chat_win or vim.b[buf].agent_mode_lazygit)
	local composer = state.composer and mouse.winid == state.composer.win
		and buf == state.composer.buf and vim.bo[buf].modifiable
	if not terminal and not composer then
		return "<LeftMouse>"
	end
	-- Process the click in Normal mode so it focuses the destination even when
	-- the source terminal captures mouse input, then enter input mode there.
	return "<C-\\><C-n><LeftMouse><Cmd>startinsert<CR>"
end

local function map_agent_buffer(buf)
	-- Navigate the Agent Mode panes without invoking editor buffer navigation.
	for key, action in pairs({ ["<C-h>"] = "focus_recents", ["<C-l>"] = "focus_chat" }) do
		vim.keymap.set({ "n", "i", "v", "t", "c", "s", "o" }, key, function()
			local normal = vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true)
			vim.api.nvim_feedkeys(normal, "n", false)
			vim.schedule(function() M[action]() end)
		end, {
			buffer = buf,
			silent = true,
			nowait = true,
			desc = action == "focus_recents" and "Focus Agent Mode recents" or "Focus Agent Mode chat",
		})
	end
	-- MouseMove is dispatched in the mode and buffer that currently own input,
	-- which is often the chat terminal or composer while the pointer is over the
	-- sidebar. Install the handler on every Agent Mode buffer so hovering a recent
	-- always previews it and marks it read without moving keyboard focus.
	vim.keymap.set({ "n", "i", "v", "t" }, "<MouseMove>", handle_sidebar_hover, {
		buffer = buf,
		silent = true,
		nowait = true,
		desc = "Preview hovered Agent Mode recent",
	})
end

local function set_scratch_options(buf, filetype)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].buflisted = false
	vim.bo[buf].filetype = filetype
	vim.bo[buf].modifiable = false
	vim.bo[buf].undofile = false
	vim.bo[buf].modeline = false
	map_agent_buffer(buf)
end

local function set_window_options(win, sidebar)
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].foldcolumn = "0"
	vim.wo[win].spell = false
	vim.wo[win].wrap = false
	-- The sidebar highlights whole conversation cards, including wrapped titles.
	vim.wo[win].cursorline = false
	vim.wo[win].winfixwidth = sidebar
	vim.wo[win].winfixheight = false
	vim.wo[win].list = false
	vim.wo[win].colorcolumn = ""
	vim.wo[win].winbar = ""
	if sidebar then
		vim.wo[win].statusline = "  [/] filter  [[]/[]] tab  [Tab] toggle  [j/k] move  [Enter/i] open  [d] toggle  [q] back"
	else
		vim.wo[win].statusline = "  [Esc] recents  [Alt-Esc] send Escape to Codex  [Ctrl-C] new  [F10] recents"
	end
end

local function wanted_sidebar_width()
	local available = math.max(18, vim.o.columns - 30)
	return math.min(state.opts.sidebar_width, available)
end

local function layout_overlay()
	local width = math.max(1, math.min(wanted_sidebar_width(), vim.o.columns - 2))
	local height = math.max(1, vim.o.lines - vim.o.cmdheight)
	local filter_height = state.filter and 2 or 0
	local function configure(win, row, col, columns, rows, border)
		local config = {
			relative = "editor", row = row, col = col, width = columns, height = rows,
			style = "minimal", border = border or "none", zindex = 40,
		}
		if valid_win(win) then
			vim.api.nvim_win_set_config(win, config)
		end
		return config
	end
	local sidebar = configure(state.sidebar_win, filter_height, 0, width,
		math.max(1, height - filter_height), { "", "", "", "│", "", "", "", "" })
	local chat = configure(state.chat_win, 0, width + 1, math.max(1, vim.o.columns - width - 1), height)
	if state.filter then
		configure(state.filter.win, 0, 0, width, 1, { "", "", "", "│", "┤", "─", "", "" })
	end
	return sidebar, chat
end

local function project_key(project)
	if not project then
		return ""
	end
	return project.common_dir or project.launch_cwd
end

local function current_entry_directory()
	local name = vim.api.nvim_buf_get_name(0)
	if name ~= "" and not name:match("^agent://") and vim.fn.filereadable(name) == 1 then
		return vim.fs.dirname(name)
	end
	return vim.fn.getcwd()
end

local function truncate(text, width)
	text = tostring(text or "")
	if width <= 1 then
		return text:sub(1, math.max(width, 0))
	end
	if vim.fn.strdisplaywidth(text) <= width then
		return text
	end

	local result = ""
	for index = 0, vim.fn.strchars(text) - 1 do
		local character = vim.fn.strcharpart(text, index, 1)
		local next_result = result .. character
		if vim.fn.strdisplaywidth(next_result .. "…") > width then
			break
		end
		result = next_result
	end
	return result .. "…"
end

local function thread_title(thread)
	local title = normalize(thread.name)
	if not title or title == "" then
		title = normalize(thread.preview)
	end
	if not title or title == "" then
		title = "Untitled conversation"
	end
	return title:gsub("%s+", " ")
end


local function thread_matches_search(thread)
	return not state.search_term or (state.search and state.search.matches[thread.id]) or false
end

local function backend_thread_time(thread)
	return tonumber(normalize(thread.recencyAt)) or tonumber(normalize(thread.updatedAt)) or tonumber(thread.createdAt) or 0
end

local function thread_time(thread)
	-- Once a thread has an explicit list position, backend recency updates must
	-- not continually reshuffle it while work is in progress.
	return tonumber(thread._activity_at) or backend_thread_time(thread)
end

local function status_name(thread)
	if thread._dismissed then
		return "saved"
	end
	-- Preview loading should not hide runtime status or the new/resumed default.
	if thread._local_status and thread._local_status ~= "loading" then
		return thread._local_status
	end

	local status = normalize(thread.status)
	local kind = type(status) == "table" and normalize(status.type) or nil
	if kind == "active" then
		for _, flag in ipairs(status.activeFlags or {}) do
			if flag == "waitingOnApproval" then
				return "approval"
			elseif flag == "waitingOnUserInput" then
				return "input"
			end
		end
		return "working"
	elseif kind == "idle" then
		return "ready"
	elseif kind == "systemError" then
		return "error"
	end
	local session = state.sessions[thread.id]
	-- A new chat already has its first prompt queued; resumed chats start ready.
	return session and session.default_status or "ready"
end

local status_icons = {
	loading = "◌",
	input = "?",
	approval = "!",
	active = "↗",
	error = "×",
	closed = "○",
	saved = "·",
}

local status_highlights = {
	working = "DiagnosticInfo",
	loading = "DiagnosticHint",
	ready = "DiagnosticOk",
	input = "DiagnosticWarn",
	approval = "DiagnosticWarn",
	active = "DiagnosticWarn",
	error = "DiagnosticError",
	closed = "Comment",
	saved = "Comment",
}

local function relative_date(timestamp, now)
	if timestamp <= 0 then
		return "No date"
	end
	-- Count local calendar days, including year boundaries and daylight saving.
	local function calendar_day(time)
		local date = os.date("*t", time)
		local year = date.year - 1
		return 365 * year + math.floor(year / 4) - math.floor(year / 100)
			+ math.floor(year / 400) + date.yday
	end
	local days = calendar_day(now or os.time()) - calendar_day(timestamp)
	if days == 0 then
		return "Today"
	elseif days == 1 then
		return "Yesterday"
	elseif days > 1 then
		return string.format("%d days ago", days)
	end
	return os.date("%y-%m-%d", timestamp)
end

local function setup_tab_highlights()
	vim.api.nvim_set_hl(0, "AgentModeTabSelected", { link = "PmenuSel", default = true })
	vim.api.nvim_set_hl(0, "AgentModeTabInactive", { link = "Comment", default = true })
end

local function setup_working_highlights()
	local dim = vim.api.nvim_get_hl(0, { name = "Comment", link = false }).fg or 0x808080
	local bright = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).fg
		or (vim.o.background == "light" and 0x202020 or 0xffffff)
	for level = 0, 7 do
		local color = 0
		for _, shift in ipairs({ 16, 8, 0 }) do
			local low = math.floor(dim / 2 ^ shift) % 256
			local high = math.floor(bright / 2 ^ shift) % 256
			color = color + math.floor(low + (high - low) * level / 7 + 0.5) * 2 ^ shift
		end
		vim.api.nvim_set_hl(0, "AgentModeWorking" .. level, {
			fg = color, bold = level >= 6,
			ctermfg = level >= 4 and (vim.o.background == "light" and 0 or 15) or 8,
		})
	end
end

local function render_working_animation()
	if not valid_buf(state.sidebar_buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(state.sidebar_buf, working_namespace, 0, -1)
	for _, label in ipairs(working_labels) do
		for index = 0, 6 do
			local phase = state.working_animation_frame / 24 - index / 12
			local intensity = ((1 + math.cos(2 * math.pi * phase)) / 2) ^ 2
			vim.api.nvim_buf_set_extmark(state.sidebar_buf, working_namespace, label.row, label.col + index, {
				end_col = label.col + index + 1,
				hl_group = "AgentModeWorking" .. math.floor(intensity * 7 + 0.5),
				hl_mode = "combine", priority = 200,
			})
		end
	end
end

local function selected_index()
	for index, thread in ipairs(state.order) do
		if thread.id == state.selected_id then
			return index
		end
	end
	return #state.order > 0 and 1 or nil
end

local function displayed_threads()
	return state.recents_tab == "dismissed" and state.dismissed_threads or state.threads
end

local function selected_thread()
	if state.sidebar_level == "worktrees" and vim.api.nvim_get_current_win() == state.sidebar_win then return nil end
	return state.selected_id and displayed_threads()[state.selected_id] or nil
end

function M.selected_worktree()
	if not valid_win(state.sidebar_win) or vim.api.nvim_get_current_win() ~= state.sidebar_win then
		return nil
	end
	local _, group = Sidebar.groups(state)
	return group and group.worktree.path or nil
end

local function current_target()
	local worktrees = state.project and state.project.worktrees or {}
	if #worktrees == 0 then
		return nil
	end
	state.new_target = math.max(1, math.min(state.new_target, #worktrees))
	return worktrees[state.new_target]
end

local function target_summary()
	local target = current_target()
	if not target then
		return "current directory"
	end
	local label = target.label or vim.fs.basename(target.path)
	if state.new_worktree then
		return (state.new_worktree_name or "new worktree") .. " (new, from " .. label .. ")"
	end
	return label
end

local render_sidebar
render_sidebar = function()
	if not valid_buf(state.sidebar_buf) then
		return
	end

	local width = valid_win(state.sidebar_win) and vim.api.nvim_win_get_width(state.sidebar_win) or state.opts.sidebar_width
	local groups = Sidebar.groups(state)
	local content_width = math.max(1, width - 2)
	local docker = Docker.supported(state.project)
	if docker then Docker.refresh(state.project, state.docker, render_sidebar) end
	if valid_win(state.sidebar_win) then
		-- The winbar stays above the viewport, independent of buffer scrolling.
		local active_hl = state.recents_tab == "active" and "AgentModeTabSelected" or "AgentModeTabInactive"
		local dismissed_hl = state.recents_tab == "dismissed" and "AgentModeTabSelected" or "AgentModeTabInactive"
		vim.wo[state.sidebar_win].winbar = string.format(
			"%%#Normal#  %%#%s# Active %d %%#WinSeparator# │ %%#%s# Dismissed %%#Normal#%%=",
			active_hl, #state.active_order, dismissed_hl
		)
		vim.wo[state.sidebar_win].statusline = state.recents_tab == "active"
			and "  [/] filter  []] dismissed  [Tab] toggle  [j/k] move  [Enter/i] open  [r] resync  [f] fork  [d] dismiss  [q] back"
			or "  [/] filter  [[] active  [Tab] toggle  [j/k] move  [Enter] restore/open  [i] preview  [r] resync  [f] fork  [d] restore  [q] back"
		if state.sidebar_level == "worktrees" then
			vim.wo[state.sidebar_win].statusline = "  [j/k] worktrees  [Enter] select"
				.. (docker and "  [h/l] action  [d] Docker down" or "") .. "  [a] rename  [D] remove worktree  [/] filter  [Tab] active/dismissed  [r] resync  [q] back"
		else
			vim.wo[state.sidebar_win].statusline = "  [Esc] worktrees" .. vim.wo[state.sidebar_win].statusline
		end
		if docker then
			vim.wo[state.sidebar_win].statusline = vim.wo[state.sidebar_win].statusline:gsub("%[r%] resync", "[r] restart Docker  [Ctrl-r] resync")
		end
		if state.search_term and not state.filter then
			vim.wo[state.sidebar_win].statusline = "  [Esc] clear filter" .. vim.wo[state.sidebar_win].statusline
		end

	end
	local lines = {}
	if state.search_term and not state.filter then
		table.insert(lines, truncate("  Filter: " .. state.search_term, width - 1))
		table.insert(lines, "")
	end
	local decorations = {}
	working_labels = {}
	local now = os.time()
	local cursor_rows = {}
	local row_threads = {}
	local group_rows, row_groups, group_decorations = {}, {}, {}
	local function group_header(group)
		local path = group.worktree.path
		local selected = state.sidebar_worktree == path
		local first_row = #lines + 1
		local spans = {}
		local function span(row, first, last, hl)
			table.insert(spans, { row = row, first = first, last = last, hl = hl })
		end
		local count = string.format("%d %s", #group.threads, #group.threads == 1 and "run" or "runs")
		local title = " " .. truncate(group.worktree.label or vim.fs.basename(path), math.max(1, content_width - #count - 3))
		local gap = string.rep(" ", math.max(1, content_width - vim.fn.strdisplaywidth(title) - #count - 1))
		table.insert(lines, title .. gap .. count .. " ")
		span(#lines, 0, #title, "AgentModeWorktree")
		span(#lines, #title + #gap, -1, "AgentModeMuted")
		if docker then
			local label = Docker.label(state.docker, path)
			local status, address = label:match("^(.-) · (localhost:%d+)$")
			local status_hl = ({
				["Docker running"] = "DiagnosticOk", ["Docker down"] = "AgentModeMuted",
				["Docker partial"] = "DiagnosticWarn", ["Docker unhealthy"] = "DiagnosticError",
				["Docker unavailable"] = "DiagnosticWarn",
			})[status or label] or "DiagnosticInfo"
			local status_text = status or label
			if address and vim.fn.strdisplaywidth(status_text .. " " .. address) + 1 > content_width then
				status_text = status_text:gsub("^Docker ", "")
				status_text = truncate(status_text, math.max(1, content_width - #address - 2))
			end
			local text = " " .. status_text .. (address and " " .. address or "")
			table.insert(lines, truncate(text, content_width))
			span(#lines, 1, 1 + #status_text, status_hl)
			if address then span(#lines, 2 + #status_text, -1, "AgentModePort") end
		end
		if selected and state.sidebar_level == "worktrees" then
			local actions = docker and { "Enter", "Docker up", "Docker down" } or { "Enter" }
			local highlights = { "Enter", "Up", "Down" }
			local labels = {}
			for i, action in ipairs(actions) do
				labels[i] = i == state.sidebar_action and ("[" .. action .. "]") or (" " .. action .. " ")
			end
			local action_line = " " .. table.concat(labels, " ")
			local action_row = #lines + 1
			if vim.fn.strdisplaywidth(action_line) > content_width then
				action_line = " ‹ " .. labels[state.sidebar_action] .. " ›"
				local first = #" ‹ "
				span(action_row, first, first + #labels[state.sidebar_action],
					"AgentModeAction" .. highlights[state.sidebar_action] .. "Selected")
			else
				local first = 1
				for i, label in ipairs(labels) do
					span(action_row, first, first + #label,
						"AgentModeAction" .. highlights[i] .. (i == state.sidebar_action and "Selected" or ""))
					first = first + #label + 1
				end
			end
			table.insert(lines, truncate(action_line, content_width))
		end
		group_rows[path] = first_row
		for row = first_row, #lines do row_groups[row] = path end
		table.insert(group_decorations, { first = first_row, last = #lines, spans = spans,
			selected = selected })
	end
	for _, group in ipairs(groups) do
		local border_first = #lines + 1
		table.insert(lines, "╭" .. string.rep("─", content_width) .. "╮")
		group_header(group)
		local decoration = group_decorations[#group_decorations]
		decoration.first = border_first
		row_groups[border_first] = group.worktree.path
		local order = group.threads

		if #order == 0 then
			local empty_message
			if state.search and state.search.pending[state.recents_tab] then
				empty_message = "  Searching conversations…"
			elseif state.search and state.search.errors[state.recents_tab] then
				empty_message = "  Search failed; press / to retry"
			elseif state.search_term then
				empty_message = state.recents_tab == "active"
					and "  No matching active conversations"
					or "  No matching dismissed conversations"
			else
				empty_message = state.recents_tab == "active"
					and "  No active conversations"
					or "  No dismissed conversations"
			end
			table.insert(lines, empty_message)
		else
			for _, thread in ipairs(order) do
				local status = status_name(thread)
				local updated = thread_time(thread)
				local date = relative_date(updated, now)
				local selected = state.sidebar_level == "runs" and thread.id == state.selected_id
					and not (state.composer and valid_win(state.composer.win))
				local marker = selected and "› " or "  "
				local run_icon = thread._unread and "◆" or (status_icons[status] or "●")
				local first_row = #lines + 1

				table.insert(lines, marker .. run_icon .. " " .. truncate(thread_title(thread), math.max(1, content_width - 4)))
				local title_last = #lines
				local label = status:sub(1, 1):upper() .. status:sub(2)
				local icon = status_icons[status]
				local status_text = (icon and icon .. " " or "") .. label
				local metadata = (status == "saved" or status == "loading") and date or status_text .. " · " .. date
				if thread._dismiss_queued then
					metadata = metadata .. " · Queued to dismiss"
				end
				table.insert(lines, truncate("    " .. metadata, content_width))
				local metadata_row = #lines
				if status == "working" and content_width >= 11 then
					table.insert(working_labels, { row = metadata_row - 1, col = #"│" + 4 })
				end

				local last_row = #lines

				cursor_rows[thread.id] = first_row
				for row = first_row, last_row do
					row_threads[row] = thread.id
				end
				table.insert(decorations, {
					first = first_row,
					last = last_row,
					title_last = title_last,
					metadata_row = metadata_row,
					status_end = #"│" + math.min(#lines[metadata_row], 4 + #status_text),
					status = status,
					marker_end = #"│" + #marker,
					icon_end = #"│" + #marker + #run_icon,
					unread = thread._unread,
					selected = selected,
				})
			end
		end

		-- Every group stays expanded; the navigation level only changes what j/k selects.
		for _, span in ipairs(decoration.spans) do
			local length = #lines[span.row]
			span.first = #"│" + math.min(span.first, length)
			span.last = #"│" + (span.last == -1 and length or math.min(span.last, length))
		end
		for row = border_first + 1, #lines do
			local text = truncate(lines[row], content_width)
			lines[row] = "│" .. text .. string.rep(" ", math.max(0, content_width - vim.fn.strdisplaywidth(text))) .. "│"
		end
		table.insert(lines, "╰" .. string.rep("─", content_width) .. "╯")
		decoration.last = #lines
		row_groups[#lines] = group.worktree.path
	end

	local footer = {
		"  " .. string.rep("─", math.max(1, width - 4)),
		state.worktree_sync_error and "  Worktree sync failed; retrying…" or "",
		truncate("  New chat: " .. target_summary(), width - 1),
		"  [Ctrl-W] worktrees / recent branches",
		"  [Ctrl-T/W] move chat to new worktree",
		"  [w] cycle existing worktree",
		"",
		state.sidebar_level == "worktrees" and "  [j/k] worktrees  [Enter] select" or "  [j/k] runs  [Esc] worktrees",
		docker and "  [h/l] Enter / Docker up / down" or "",
		docker and "  [r] restart Docker  [Ctrl-r] resync" or "  [r/Ctrl-r] resync",
		"  [gg/G] first/last",
		"  [Tab/[/]] switch recents tab",
		"  [/] filter  [Esc] clear filter",
		state.recents_tab == "active" and "  [Enter/i/I] open chat" or "  [Enter] restore and open chat",
		state.sidebar_level == "worktrees" and "  [D] remove worktree (keep branch)"
			or (state.recents_tab == "active" and "  [d] dismiss" or "  [i/I] preview  [d] restore"),
		state.sidebar_level == "worktrees" and docker and "  [d] Docker down" or "",
		state.sidebar_level == "worktrees" and "  [a] rename worktree / branch" or "",
		state.sidebar_level == "runs" and state.recents_tab == "active" and "  Working: d toggles dismiss queue" or "",
		"  [f] fork and focus chat",
		"  [q] back",
	}
	local keys = state.opts.keys or defaults.keys
	for _, action in ipairs({ { "new_chat", "new chat" }, { "recents", "recents" } }) do
		local key = keys[action[1]]
		if key then
			table.insert(footer, "  [" .. key:gsub("^<", ""):gsub(">$", "") .. "] " .. action[2])
		end
	end
	-- Keep the footer at the bottom when the conversations leave room for it.
	local height = valid_win(state.sidebar_win) and vim.api.nvim_win_get_height(state.sidebar_win) or 0
	for _ = #lines + #footer + 1, height do
		table.insert(lines, "")
	end
	local footer_start = #lines + 1
	vim.list_extend(lines, footer)
	state.cursor_rows = cursor_rows
	state.row_threads = row_threads
	state.group_rows, state.row_groups = group_rows, row_groups

	vim.bo[state.sidebar_buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.sidebar_buf, 0, -1, false, lines)
	vim.bo[state.sidebar_buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(state.sidebar_buf, namespace, 0, -1)

	for _, decoration in ipairs(decorations) do
		for row = decoration.first, decoration.last do
			local hl = row <= decoration.title_last
				and (decoration.selected and "AgentModeRunSelected" or "AgentModeTitle") or "Comment"
			vim.api.nvim_buf_add_highlight(state.sidebar_buf, namespace, hl, row - 1, #"│", #lines[row] - #"│")
		end
		vim.api.nvim_buf_add_highlight(state.sidebar_buf, namespace,
			decoration.unread and "DiagnosticWarn" or (status_highlights[decoration.status] or "Comment"),
			decoration.first - 1, decoration.marker_end, decoration.icon_end)
		if decoration.selected then
			vim.api.nvim_buf_add_highlight(state.sidebar_buf, namespace, "AgentModeRunSelected",
				decoration.first - 1, #"│", decoration.marker_end)
		end
		if decoration.status ~= "saved" and decoration.status ~= "loading" then
			vim.api.nvim_buf_add_highlight(state.sidebar_buf, namespace,
				status_highlights[decoration.status] or "Comment",
				decoration.metadata_row - 1, #"│" + 4, decoration.status_end)
		end
	end

	for _, decoration in ipairs(group_decorations) do
		local border_hl = decoration.selected and "AgentModeWorktreeBorderSelected" or "AgentModeWorktreeBorder"
		for row = decoration.first, decoration.last do
			if row == decoration.first or row == decoration.last then
				vim.api.nvim_buf_add_highlight(state.sidebar_buf, namespace, border_hl, row - 1, 0, -1)
			else
				vim.api.nvim_buf_add_highlight(state.sidebar_buf, namespace, border_hl, row - 1, 0, #"│")
				vim.api.nvim_buf_add_highlight(state.sidebar_buf, namespace, border_hl, row - 1, #lines[row] - #"│", -1)
			end
		end
		for _, span in ipairs(decoration.spans) do
			if span.last > span.first then
				vim.api.nvim_buf_add_highlight(state.sidebar_buf, namespace, span.hl, span.row - 1, span.first, span.last)
			end
		end
	end
	for row = footer_start, #lines do
		vim.api.nvim_buf_add_highlight(state.sidebar_buf, namespace, "AgentModeMuted", row - 1, 0, -1)
		local offset = 1
		while true do
			local first, last = lines[row]:find("%b[]", offset)
			if not first then break end
			vim.api.nvim_buf_add_highlight(state.sidebar_buf, namespace, "AgentModeKey", row - 1, first - 1, last)
			offset = last + 1
		end
	end
	render_working_animation()
	if valid_win(state.sidebar_win) and state.sidebar_level == "worktrees" and group_rows[state.sidebar_worktree] then
		pcall(vim.api.nvim_win_set_cursor, state.sidebar_win, { group_rows[state.sidebar_worktree], 1 })
	elseif valid_win(state.sidebar_win) and state.selected_id and cursor_rows[state.selected_id] then
		pcall(vim.api.nvim_win_set_cursor, state.sidebar_win, { cursor_rows[state.selected_id], 1 })
	end
end

local function restart_worktree(worktree)
	if not Docker.supported(state.project) then
		M.resync()
	elseif worktree and state.project.removing_worktree ~= worktree.path then
		Docker.run(worktree.path, "restart", state.docker, render_sidebar, notify)
	end
end

local focus_recents

local function centered_text(text, width)
	local padding = math.max(0, math.floor((width - vim.fn.strdisplaywidth(text)) / 2))
	return string.rep(" ", padding) .. text
end

local agent_mode_banner = {
	"    _                    _     __  __           _      ",
	"   / \\   __ _  ___ _ __ | |_  |  \\/  | ___   __| | ___ ",
	"  / _ \\ / _` |/ _ \\ '_ \\| __| | |\\/| |/ _ \\ / _` |/ _ \\",
	" / ___ \\ (_| |  __/ | | | |_  | |  | | (_) | (_| |  __/",
	"/_/   \\_\\__, |\\___|_| |_|\\__| |_|  |_|\\___/ \\__,_|\\___|",
	"        |___/                                                ",
}

local function append_centered_banner(lines, width)
	local first = #lines + 1
	for _, line in ipairs(agent_mode_banner) do
		table.insert(lines, centered_text(line, width))
	end
	return first, #lines
end

local function render_placeholder(message, detail)
	if not valid_buf(state.placeholder_buf) then
		return
	end
	message = message or "Choose a recent conversation, or press Ctrl-C for a new chat."
	local height = valid_win(state.chat_win) and vim.api.nvim_win_get_height(state.chat_win) or 20
	local width = valid_win(state.chat_win) and vim.api.nvim_win_get_width(state.chat_win) or 80
	local extra_lines = detail and detail ~= "" and 2 or 0
	local padding = math.max(0, math.floor((height - #agent_mode_banner - 3 - extra_lines) / 2))
	local lines = {}
	for _ = 1, padding do
		table.insert(lines, "")
	end
	local banner_first, banner_last = append_centered_banner(lines, width)
	table.insert(lines, "")
	local message_row = #lines + 1
	table.insert(lines, centered_text(message, width))
	local detail_row = nil
	if detail and detail ~= "" then
		table.insert(lines, "")
		detail_row = #lines + 1
		table.insert(lines, centered_text(truncate(detail, math.max(1, width - 8)), width))
	end

	vim.bo[state.placeholder_buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.placeholder_buf, 0, -1, false, lines)
	vim.bo[state.placeholder_buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(state.placeholder_buf, namespace, 0, -1)
	for row = banner_first, banner_last do
		vim.api.nvim_buf_add_highlight(state.placeholder_buf, namespace, "DiagnosticInfo", row - 1, 0, -1)
	end
	vim.api.nvim_buf_add_highlight(state.placeholder_buf, namespace, "Comment", message_row - 1, 0, -1)
	if detail_row then
		vim.api.nvim_buf_add_highlight(state.placeholder_buf, namespace, "Title", detail_row - 1, 0, -1)
	end
end

local function render_thread_loading(thread)
	if valid_win(state.chat_win) and valid_buf(state.placeholder_buf) then
		vim.api.nvim_win_set_buf(state.chat_win, state.placeholder_buf)
		set_window_options(state.chat_win, false)
		vim.wo[state.chat_win].wrap = true
		render_placeholder("◌  Loading conversation…", thread and thread_title(thread) or nil)
	end
end

local function append_text(lines, highlights, label, text, highlight)
	text = tostring(text or "")
	if text == "" then
		return
	end
	table.insert(lines, label)
	table.insert(highlights, { row = #lines, group = highlight })
	for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
		table.insert(lines, line)
	end
	table.insert(lines, "")
end

local function user_message_text(item)
	local parts = {}
	for _, content in ipairs(item.content or {}) do
		if type(content) == "table" and content.text and content.text ~= "" then
			table.insert(parts, content.text)
		end
	end
	return table.concat(parts, "\n")
end

local function render_readonly_history(buf, thread, message, options)
	options = options or {}
	if not valid_buf(buf) then
		return
	end
	local lines = {
		options.heading or "ACTIVE IN ANOTHER CODEX WINDOW",
		message or options.message or "This conversation is read-only here until its current writer closes.",
		options.action or "Press r to retry opening it here.",
		"",
	}
	local highlights = {
		{ row = 1, group = "DiagnosticWarn" },
		{ row = 2, group = "Comment" },
		{ row = 3, group = "Comment" },
	}
	for _, turn in ipairs((thread and thread.turns) or {}) do
		for _, item in ipairs(turn.items or {}) do
			if item.type == "userMessage" then
				append_text(lines, highlights, "YOU", user_message_text(item), "Title")
			elseif item.type == "agentMessage" then
				append_text(lines, highlights, "CODEX", item.text, "DiagnosticInfo")
			end
		end
	end
	if #lines == 4 then
		table.insert(lines, "No conversation messages are available yet.")
	end

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	for _, item in ipairs(highlights) do
		vim.api.nvim_buf_add_highlight(buf, namespace, item.group, item.row - 1, 0, -1)
	end
end

local function show_dismissed_thread(thread, focus)
	if not thread or not valid_win(state.chat_win) or not valid_buf(state.placeholder_buf) then
		return
	end
	local history_options = {
		heading = "DISMISSED CONVERSATION",
		message = "This conversation is not monitored and is read-only while dismissed.",
		action = "Press d in recents to return it to Active.",
	}
	state.active_id = thread.id
	vim.api.nvim_win_set_buf(state.chat_win, state.placeholder_buf)
	set_window_options(state.chat_win, false)
	vim.wo[state.chat_win].wrap = true
	vim.keymap.set("n", "<Esc>", focus_recents, {
		buffer = state.placeholder_buf,
		silent = true,
		desc = "Focus Agent Mode recents",
	})
	render_readonly_history(state.placeholder_buf, nil, "Loading its conversation history…", history_options)
	if focus then
		vim.api.nvim_set_current_win(state.chat_win)
	end
	if not state.backend then
		render_readonly_history(state.placeholder_buf, nil, "Conversation history is unavailable because the metadata server is not running.", history_options)
		return
	end

	local requested_id = thread.id
	state.backend:read_thread(requested_id, function(err, result)
		if state.recents_tab ~= "dismissed" or state.selected_id ~= requested_id
			or not valid_buf(state.placeholder_buf)
		then
			return
		end
		if err then
			render_readonly_history(state.placeholder_buf, nil, "Could not read this conversation: " .. tostring(err), history_options)
			return
		end
		local saved_thread = result and (result.thread or result) or nil
		render_readonly_history(state.placeholder_buf, saved_thread, nil, history_options)
	end)
end

local function show_readonly_thread(thread, session, focus)
	if not thread or not session or not valid_win(state.chat_win) then
		return
	end
	if not valid_buf(session.readonly_buf) then
		session.readonly_buf = vim.api.nvim_create_buf(false, true)
		pcall(vim.api.nvim_buf_set_name, session.readonly_buf, "agent://readonly/" .. thread.id)
		set_scratch_options(session.readonly_buf, "markdown")
		vim.keymap.set("n", "<Esc>", focus_recents, {
			buffer = session.readonly_buf,
			silent = true,
			desc = "Focus Agent Mode recents",
		})
		vim.keymap.set("n", "r", function()
			session.active_elsewhere = false
			session.retry_after = nil
			M.open_selected(true)
		end, { buffer = session.readonly_buf, silent = true, desc = "Retry Agent Mode conversation" })
		for _, key in ipairs({ "<CR>", "i", "I" }) do
			vim.keymap.set("n", key, function()
				notify("This conversation is active in another Codex window; press r after closing it there", vim.log.levels.WARN)
			end, { buffer = session.readonly_buf, silent = true })
		end
	end

	vim.api.nvim_win_set_buf(state.chat_win, session.readonly_buf)
	set_window_options(state.chat_win, false)
	vim.wo[state.chat_win].wrap = true
	render_readonly_history(session.readonly_buf, nil, "Loading its conversation history…")
	if focus then
		vim.api.nvim_set_current_win(state.chat_win)
	end

	if not state.backend then
		render_readonly_history(session.readonly_buf, nil, "Conversation history is unavailable because the metadata server is not running.")
		return
	end
	local requested_id = thread.id
	state.backend:read_thread(requested_id, function(err, result)
		if not valid_buf(session.readonly_buf) or session.id ~= requested_id then
			return
		end
		if err then
			render_readonly_history(session.readonly_buf, nil, "Could not read this conversation: " .. tostring(err))
			return
		end
		local saved_thread = result and (result.thread or result) or nil
		render_readonly_history(session.readonly_buf, saved_thread)
		if valid_win(state.chat_win) and state.active_id == requested_id
			and vim.api.nvim_win_get_buf(state.chat_win) == session.readonly_buf
		then
			vim.api.nvim_win_set_cursor(state.chat_win, { math.max(1, vim.api.nvim_buf_line_count(session.readonly_buf)), 0 })
		end
	end)
end

local function composer_text(composer)
	if not composer or not valid_buf(composer.buf) then
		return composer and composer.text or ""
	end
	return table.concat(vim.api.nvim_buf_get_lines(composer.buf, 0, -1, false), "\n")
end

local function composer_draft_text(composer)
	if composer and composer.history_index ~= nil and composer.history_draft ~= nil then
		return composer.history_draft
	end
	return composer_text(composer)
end

local function render_composer(message)
	local composer = state.composer
	if not composer or not valid_buf(composer.buf) or not valid_buf(composer.background_buf)
		or not valid_win(state.chat_win)
	then
		return
	end

	local text = composer_text(composer)
	composer.text = text
	local width = vim.api.nvim_win_get_width(state.chat_win)
	local height = vim.api.nvim_win_get_height(state.chat_win)
	local input_width = math.max(20, math.min(72, width - 8))
	local input_height = 0
	for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
		input_height = input_height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / input_width))
	end
	input_height = math.max(3, math.min(10, input_height))
	local content_height = #agent_mode_banner + input_height + (composer.plan_mode and 9 or 8) + (message and 1 or 0)
	local padding = math.max(1, math.floor((height - content_height) / 2))
	local lines = {}
	for _ = 1, padding do
		table.insert(lines, "")
	end
	local banner_first, banner_last = append_centered_banner(lines, width)
	table.insert(lines, "")
	local message_row = nil
	if message then
		message_row = #lines + 1
		table.insert(lines, centered_text(message, width))
	end
	local target_row = #lines + 1
	table.insert(lines, centered_text("Worktree: " .. target_summary(), width))
	table.insert(lines, centered_text("Ctrl-W select worktree  ·  Ctrl-T new worktree", width))
	local mode_row = nil
	if composer.plan_mode then
		mode_row = #lines + 1
		table.insert(lines, centered_text("Plan mode: ON", width))
	end
	table.insert(lines, "")
	local input_row = #lines
	for _ = 1, input_height + 2 do
		table.insert(lines, "")
	end

	vim.bo[composer.background_buf].modifiable = true
	vim.api.nvim_buf_set_lines(composer.background_buf, 0, -1, false, lines)
	vim.bo[composer.background_buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(composer.background_buf, namespace, 0, -1)
	for row = banner_first, banner_last do
		vim.api.nvim_buf_add_highlight(composer.background_buf, namespace, "DiagnosticInfo", row - 1, 0, -1)
	end
	if message_row then
		vim.api.nvim_buf_add_highlight(composer.background_buf, namespace, "DiagnosticInfo", message_row - 1, 0, -1)
	end
	vim.api.nvim_buf_add_highlight(composer.background_buf, namespace, "Comment", target_row - 1, 0, -1)
	vim.api.nvim_buf_add_highlight(composer.background_buf, namespace, "Comment", target_row, 0, -1)
	if mode_row then
		vim.api.nvim_buf_add_highlight(composer.background_buf, namespace, "DiagnosticWarn", mode_row - 1, 0, -1)
	end
	vim.bo[composer.buf].modifiable = not composer.busy

	local float_config = {
		relative = "win",
		win = state.chat_win,
		row = input_row,
		col = math.max(0, math.floor((width - input_width - 2) / 2)),
		width = input_width,
		height = input_height,
		style = "minimal",
		border = "rounded",
		title = " Agent prompt ",
		title_pos = "center",
		zindex = 50,
	}
	if valid_win(composer.win) then
		vim.api.nvim_win_set_config(composer.win, float_config)
	else
		composer.win = vim.api.nvim_open_win(composer.buf, false, float_config)
	end
	vim.wo[composer.win].wrap = true
	vim.wo[composer.win].linebreak = true
	vim.wo[composer.win].cursorline = true
	vim.wo[composer.win].winhighlight = "NormalFloat:Normal,FloatBorder:DiagnosticInfo,FloatTitle:Title"
	render_sidebar()
end

local function update_composer_frame()
	render_composer(state.composer and state.composer.message or nil)
	render_sidebar()
end

focus_recents = function()
	if not valid_win(state.sidebar_win) then
		return
	end
	vim.cmd("stopinsert")
	vim.api.nvim_set_current_win(state.sidebar_win)
	if state.composer and valid_win(state.chat_win)
		and vim.api.nvim_win_get_buf(state.chat_win) == state.composer.background_buf
		and state.order[1]
	then
		state.selected_id = state.order[1].id
		if state.preview_timer then
			state.preview_timer:stop()
		end
		M.open_selected(false)
	end
	render_sidebar()
	local row = state.sidebar_level == "worktrees" and state.group_rows[state.sidebar_worktree]
		or (state.selected_id and state.cursor_rows and state.cursor_rows[state.selected_id])
	if row then
		pcall(vim.api.nvim_win_set_cursor, state.sidebar_win, { row, 1 })
	end
end

M.focus_recents = focus_recents

local function terminal_running(session)
	if not session or not session.job_id or session.job_id <= 0 then
		return false
	end
	local result = vim.fn.jobwait({ session.job_id }, 0)
	return result[1] == -1
end

local function thread_for_session(session)
	if not session then
		return nil
	end
	return state.threads[session.id or session.key]
end

local function next_activity_time()
	local latest = os.time()
	for _, other in pairs(state.threads) do
		latest = math.max(latest, thread_time(other))
	end
	state.activity_clock = math.max(state.activity_clock + 0.001, latest + 0.001)
	return state.activity_clock
end

local function bump_thread(thread)
	if not thread then
		return
	end
	thread._activity_at = next_activity_time()
	local session = state.sessions[thread.id]
	if session then
		session.activity_at = thread._activity_at
	end
	table.sort(state.active_order, function(left, right)
		return thread_time(left) > thread_time(right)
	end)
	if state.recents_tab == "active" then
		state.order = state.active_order
	end
	render_sidebar()
end

local function chat_is_focused(thread_id)
	return valid_win(state.chat_win)
		and vim.api.nvim_get_current_win() == state.chat_win
		and state.active_id == thread_id
end

local function scroll_chat_to_bottom(buf)
	if not valid_win(state.chat_win) or not valid_buf(buf)
		or vim.api.nvim_win_get_buf(state.chat_win) ~= buf
	then
		return
	end
	local line_count = math.max(1, vim.api.nvim_buf_line_count(buf))
	pcall(vim.api.nvim_win_set_cursor, state.chat_win, { line_count, 0 })
	pcall(vim.api.nvim_win_call, state.chat_win, function()
		vim.cmd("normal! G")
	end)
end

local function show_terminal_session(session, focus)
	if not session or not valid_buf(session.buf) or not valid_win(state.chat_win) then
		return
	end
	local session_id = session.id or session.key
	if state.active_id ~= session_id then
		return
	end
	vim.api.nvim_win_set_buf(state.chat_win, session.buf)
	set_window_options(state.chat_win, false)
	scroll_chat_to_bottom(session.buf)
	vim.schedule(function()
		if state.active_id == session_id then
			scroll_chat_to_bottom(session.buf)
		end
	end)
	if focus then
		session.unread = false
		vim.api.nvim_set_current_win(state.chat_win)
		vim.cmd("startinsert")
	end
end

local function finish_initial_load(session)
	if not session or session.initial_load_complete then
		return
	end
	session.initial_load_complete = true
	if session.frontend_status == "loading" then
		session.frontend_status = nil
		local thread = thread_for_session(session)
		if thread and thread._local_status == "loading" then
			thread._local_status = nil
		end
		render_sidebar()
	end
	show_terminal_session(session, session.reveal_focus)
end

local function terminal_prompt_status(lines)
	-- Dialogs replace the composer and end with a keyboard-hint footer. Match
	-- that live footer, not approval-related prose or resolved prompts in history.
	for index = #lines, 1, -1 do
		local footer = vim.trim(lines[index]):lower()
		if footer ~= "" then
			if footer:match("^press enter to confirm or esc to cancel") then
				return "approval"
			elseif footer:find("enter to select", 1, true)
				or footer:match("^enter to submit.*esc to cancel")
				or footer:match("^waiting for your input")
			then
				return "input"
			end
			return nil
		end
	end
end

local function terminal_reports_ready(lines)
	if terminal_prompt_status(lines) then
		return false
	end
	for index = #lines, 1, -1 do
		if vim.trim(lines[index]):sub(1, #"›") == "›" then
			return true
		end
	end
	return false
end

-- Terminal inspection is only for revealing the UI and handling native menus.
-- It never supplies the recents runtime status.
local detach_session_for_switch

local function terminal_ui_status(session)
	if not valid_buf(session.buf) then
		return nil
	end
	local count = vim.api.nvim_buf_line_count(session.buf)
	local lines = vim.api.nvim_buf_get_lines(session.buf, math.max(0, count - 40), count, false)
	return terminal_prompt_status(lines) or (terminal_reports_ready(lines) and "ready" or nil)
end

local function terminal_plan_mode(session)
	if not valid_buf(session.buf) then
		return nil
	end
	local count = vim.api.nvim_buf_line_count(session.buf)
	local lines = vim.api.nvim_buf_get_lines(session.buf, math.max(0, count - 40), count, false)
	if terminal_prompt_status(lines) then
		return nil
	end
	-- Only inspect the footer after the last composer, never Plan-mode prose
	-- or old prompts in the transcript. Wait for a footer to be rendered.
	local footer = {}
	for index = #lines, 1, -1 do
		local line = vim.trim(lines[index])
		if line:sub(1, #"›") == "›" then
			if #footer > 0 then
				return table.concat(footer, "\n"):match("Plan mode") ~= nil
			end
			return nil
		end
		if line ~= "" then
			table.insert(footer, line)
		end
	end
end

local function attach_terminal_activity(session)
	local function check_initial_load()
		if not state.shutting_down and state.session_tokens[session.notify_token] == session
			and not session.initial_load_complete and terminal_ui_status(session)
		then
			if session.restore_plan_mode then
				local current = terminal_plan_mode(session)
				if current == nil then
					return
				end
				if not current then
					if not session.mode_restore_sent and terminal_running(session) then
						session.mode_restore_sent = true
						vim.api.nvim_chan_send(session.job_id, codex_backtab)
					end
					return
				end
				session.restore_plan_mode = nil
			end
			finish_initial_load(session)
		end
	end
	vim.api.nvim_buf_attach(session.buf, false, {
		on_lines = function()
			if session.initial_load_complete or session.activity_scheduled then
				return
			end
			session.activity_scheduled = true
			vim.schedule(function()
				session.activity_scheduled = false
				check_initial_load()
			end)
		end,
	})
	-- Output can arrive before the listener is attached. Also reveal unfamiliar
	-- startup screens after a bounded wait so their prompts remain accessible.
	vim.schedule(check_initial_load)
	vim.defer_fn(function()
		if not state.shutting_down and state.session_tokens[session.notify_token] == session
			and valid_buf(session.buf) and not session.active_elsewhere
		then
			if session.restore_plan_mode then
				notify("Could not confirm restored Plan mode; check the chat's mode before sending", vim.log.levels.WARN)
			end
			finish_initial_load(session)
		end
	end, state.opts.preview_loading_timeout)
end

local function send_escape_to_codex(session)
	if session and terminal_running(session) then
		vim.api.nvim_chan_send(session.job_id, "\27")
		session.pending_thread_switch = nil
	end
end

local function configure_terminal_buffer(session)
	vim.bo[session.buf].bufhidden = "hide"
	vim.bo[session.buf].buflisted = false
	vim.bo[session.buf].swapfile = false
	map_agent_buffer(session.buf)
	vim.keymap.set("n", "r", function()
		restart_worktree(Project.worktree_for(state.project, session.cwd))
	end, { buffer = session.buf, silent = true, desc = "Restart chat worktree Docker (resync for other projects)" })

	vim.keymap.set("t", "<Esc>", function()
		local normal = vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true)
		vim.api.nvim_feedkeys(normal, "n", false)
		vim.schedule(focus_recents)
	end, { buffer = session.buf, silent = true, desc = "Focus Agent Mode recents" })

	vim.keymap.set("n", "<Esc>", focus_recents, {
		buffer = session.buf,
		silent = true,
		desc = "Focus Agent Mode recents",
	})

	vim.keymap.set("t", "<M-Esc>", function()
		send_escape_to_codex(session)
	end, { buffer = session.buf, silent = true, desc = "Send Escape to Codex" })

	-- Forward plain Up/Down to Codex for shell-style prompt history.
	vim.keymap.set("t", "<Up>", function()
		if terminal_running(session) then
			vim.api.nvim_chan_send(session.job_id, "\27[A")
		end
	end, { buffer = session.buf, silent = true, desc = "Older Codex prompt" })
	vim.keymap.set("t", "<Down>", function()
		if terminal_running(session) then
			vim.api.nvim_chan_send(session.job_id, "\27[B")
		end
	end, { buffer = session.buf, silent = true, desc = "Newer Codex prompt" })

	vim.keymap.set("t", "<S-Tab>", function()
		if terminal_running(session) then
			session.restore_plan_mode = nil
			vim.api.nvim_chan_send(session.job_id, codex_backtab)
		end
	end, { buffer = session.buf, silent = true, desc = "Cycle Codex collaboration mode" })

	vim.keymap.set("t", "<CR>", function()
		local thread = thread_for_session(session)
		local status_before_enter = terminal_ui_status(session)
		local runtime_status = thread and status_name(thread)
		local cursor = vim.api.nvim_win_get_cursor(0)
		local lines = valid_buf(session.buf)
			and vim.api.nvim_buf_get_lines(session.buf, math.max(0, cursor[1] - 1), cursor[1], false)
			or {}
		local prompt = nil
		local marker = lines[1] and lines[1]:find("›", 1, true) or nil
		if marker then
			prompt = vim.trim(lines[1]:sub(marker + #"›"))
			local input_column = marker - 1 + #"›" + 1
			local lowered = prompt:lower()
			if cursor[2] <= input_column
				or lowered:match("^ask codex")
			then
				prompt = nil
			end
		end
		local slash_command = prompt and prompt:lower():match("^/(%S+)") or nil
		if slash_command == "plan" and not session.id and not session.initial_prompt then
			local inline = prompt:match("^/plan%s+(.+)$")
			if inline then
				session.initial_prompt = inline
			end
		end
		if slash_command == "review" and not session.id and not session.initial_prompt then
			session.initial_prompt = "/review"
		end
		if slash_command == "new" or slash_command == "clear" or slash_command == "resume" or slash_command == "fork" then
			session.pending_thread_switch = slash_command
		end
		local confirms_thread_switch = session.pending_thread_switch and status_before_enter == "input"
		if status_before_enter ~= "approval" and status_before_enter ~= "input"
			and runtime_status ~= "approval" and runtime_status ~= "input"
			and prompt and prompt ~= "" and prompt:sub(1, 1) ~= "/"
		then
			if state.prompt_history then
				state.prompt_history:record_final(prompt)
			end
			-- The saved preview identifies the first prompt. A follow-up can arrive
			-- before metadata or the notify hook binds this terminal to its ID.
			-- Keep that evidence so the saved row replaces the temporary one.
			if not session.id and not session.initial_prompt then
				session.initial_prompt = prompt
				-- A terminal line can contain only the start of a wrapped prompt.
				session.initial_prompt_truncated = true
			end
		end
		if terminal_running(session) then
			vim.api.nvim_chan_send(session.job_id, "\r")
		end
		if session.pending_thread_switch then
			local expected = session.pending_thread_switch
			vim.defer_fn(function()
				if not terminal_running(session) or session.pending_thread_switch ~= expected then
					return
				end
				if expected == "new" or expected == "clear" or expected == "fork" or confirms_thread_switch then
					detach_session_for_switch(session, expected)
				end
			end, confirms_thread_switch and 100 or 250)
		end
	end, { buffer = session.buf, silent = true, desc = "Send prompt to Codex" })

	attach_terminal_activity(session)
end

local function notifier_config_argument(token)
	if not state.notifier_enabled then
		return nil
	end
	return string.format("notify=[%q,%q,%q]", "agent-mode-notify", state.notify_path, token)
end

local function terminal_command(resume_id, notify_token, cwd)
	local command = type(state.opts.command) == "table" and vim.deepcopy(state.opts.command) or { state.opts.command }
	if state.opts.launcher then
		table.insert(command, 1, state.opts.launcher)
	end
	-- Explicit remote connections use the daemon's cwd unless --cd is sent.
	-- jobstart's cwd only changes the local terminal process's directory.
	vim.list_extend(command, { "--remote", "unix://", "--cd", cwd })
	local notifier = notifier_config_argument(notify_token)
	if notifier then
		vim.list_extend(command, { "-c", notifier })
	end
	if resume_id then
		vim.list_extend(command, { "resume", resume_id })
	end
	return command
end

local function terminal_tail(session)
	if not session or not valid_buf(session.buf) then
		return ""
	end
	local count = vim.api.nvim_buf_line_count(session.buf)
	return table.concat(vim.api.nvim_buf_get_lines(session.buf, math.max(0, count - 40), count, false), "\n")
end

local function finish_session_close(session, err)
	if not session or not session.closing then
		return
	end
	local callbacks = session.close_callbacks or {}
	session.close_callbacks = nil
	session.closing = false
	if not err then
		if state.sessions[session.id] == session then
			state.sessions[session.id] = nil
		end
		if state.sessions[session.key] == session then
			state.sessions[session.key] = nil
		end
		if state.session_tokens[session.notify_token] == session then
			state.session_tokens[session.notify_token] = nil
		end
		session.job_id = nil
		if valid_buf(session.buf) then
			pcall(vim.api.nvim_buf_delete, session.buf, { force = true })
		end
	end
	for _, callback in ipairs(callbacks) do
		callback(err)
	end
end

local function close_session(session, callback)
	if not session then
		vim.schedule(function()
			callback(nil)
		end)
		return
	end
	session.close_callbacks = session.close_callbacks or {}
	table.insert(session.close_callbacks, callback)
	if session.closing then
		return
	end
	session.closing = true
	if not terminal_running(session) then
		vim.schedule(function()
			finish_session_close(session)
		end)
		return
	end
	local ok, stopped = pcall(vim.fn.jobstop, session.job_id)
	if not ok or stopped ~= 1 then
		finish_session_close(session, "Could not close the active Codex session")
	end
end

local function create_terminal(resume_id, cwd, key, thread_id, fresh)
	local existing = state.sessions[key]
	if existing and terminal_running(existing) then
		return existing
	end
	local plan_mode = existing and terminal_plan_mode(existing)
	if plan_mode == nil and resume_id then
		plan_mode = Backend.saved_plan_mode(state.threads[resume_id] or state.dismissed_threads[resume_id])
	end
	state.session_sequence = state.session_sequence + 1
	local notify_token = string.format("%s-%d", vim.fn.getpid(), state.session_sequence)
	local command = terminal_command(resume_id, notify_token, cwd)
	local buf = vim.api.nvim_create_buf(false, true)
	pcall(vim.api.nvim_buf_set_name, buf, "agent://chat/" .. key)
	local previous_buf = valid_win(state.chat_win) and vim.api.nvim_win_get_buf(state.chat_win) or nil
	vim.api.nvim_win_set_buf(state.chat_win, buf)
	set_window_options(state.chat_win, false)
	local session = {
		key = key,
		id = thread_id,
		-- Resumed chats already have a saved canonical ID. Fresh chats start under
		-- a temporary key and are rebound when the CLI persists its real thread.
		identity_confirmed = resume_id ~= nil,
		plan_mode = plan_mode,
		restore_plan_mode = resume_id ~= nil and plan_mode == true,
		buf = buf,
		cwd = cwd,
		started_at = os.time(),
		frontend_status = "loading",
		default_status = fresh and "working" or "ready",
		initial_load_complete = false,
		reveal_focus = false,
		notify_token = notify_token,
		known_ids = {},
	}
	for id in pairs(state.threads) do
		session.known_ids[id] = true
	end
	local replaced = state.sessions[key]
	if replaced and replaced.notify_token then
		state.session_tokens[replaced.notify_token] = nil
		if valid_buf(replaced.buf) and replaced.buf ~= buf then
			pcall(vim.api.nvim_buf_delete, replaced.buf, { force = true })
		end
	end
	state.sessions[key] = session
	state.session_tokens[notify_token] = session

	local job_id
	vim.api.nvim_win_call(state.chat_win, function()
		job_id = vim.fn.jobstart(command, {
			cwd = cwd,
			term = true,
			on_exit = function(_, code)
				local exit_tail = terminal_tail(session)
				vim.schedule(function()
					if session.closing then
						finish_session_close(session)
						return
					end
					local writer_conflict = code ~= 0
						and exit_tail:lower():match("already%s+has%s+an%s+active%s+writer") ~= nil
					session.active_elsewhere = writer_conflict
					session.retry_after = writer_conflict and (os.time() + 3) or nil
					session.frontend_status = writer_conflict and "active" or (code == 0 and "closed" or "error")
					if state.session_tokens[session.notify_token] ~= session then
						return
					end
					local thread = thread_for_session(session)
					if thread then
						thread._local_status = session.frontend_status
						render_sidebar()
						if writer_conflict and state.active_id == thread.id then
							show_readonly_thread(thread, session, vim.api.nvim_get_current_win() == state.chat_win)
						end
					end
					if not writer_conflict then
						finish_initial_load(session)
					end
				end)
			end,
		})
	end)
	if valid_win(state.chat_win) and valid_buf(previous_buf)
		and vim.api.nvim_win_get_buf(state.chat_win) == buf
	then
		vim.api.nvim_win_set_buf(state.chat_win, previous_buf)
	end
	session.job_id = job_id
	if not job_id or job_id <= 0 then
		session.frontend_status = "error"
		session.initial_load_complete = true
		local command_name = type(state.opts.command) == "table" and table.concat(state.opts.command, " ") or state.opts.command
		notify("Could not start " .. command_name, vim.log.levels.ERROR)
		return session
	end
	configure_terminal_buffer(session)
	return session
end

local function preload_active_threads()
	local limit = state.opts.preload_concurrency or 0
	if state.shutting_down or not state.backend_ready or not valid_win(state.chat_win)
		or (state.project and state.project.removing_worktree)
		or state.recents_tab ~= "active" or limit <= 0
	then
		return
	end
	local loading = 0
	for _, session in pairs(state.sessions) do
		-- A new CLI must acquire its canonical identity before background resumes
		-- can occupy IDs that identity discovery might otherwise assign to it.
		if not session.id or session.pending_thread_switch then
			return
		end
		if not session.initial_load_complete and terminal_running(session) then
			loading = loading + 1
		end
	end
	local candidates = {}
	local selected = state.threads[state.selected_id]
	if selected then
		table.insert(candidates, selected)
	end
	for _, thread in ipairs(state.active_order) do
		if thread ~= selected then
			table.insert(candidates, thread)
		end
	end
	local remaining = false
	for _, thread in ipairs(candidates) do
		local status = normalize(thread.status)
		local kind = type(status) == "table" and status.type or nil
		-- Loaded threads may have a writer in another client. Leave them alone;
		-- selecting one explicitly still uses the usual read-only fallback.
		if not state.sessions[thread.id] and not thread._dismissed and not state.dismiss_pending[thread.id]
			and not state.move_pending[thread.id]
			and (not kind or kind == "notLoaded") and thread.cwd and vim.fn.isdirectory(thread.cwd) == 1
		then
			if loading < limit then
				create_terminal(thread.id, thread.cwd, thread.id, thread.id)
				loading = loading + 1
			else
				remaining = true
				break
			end
		end
	end
	if remaining and not state.preload_scheduled then
		state.preload_scheduled = true
		vim.defer_fn(function()
			state.preload_scheduled = false
			preload_active_threads()
		end, 250)
	end
end

local sort_threads
local dismiss_completed_thread

local function archive_thread_after_close(thread, callback)
	-- The app server refuses to archive a thread while the interactive CLI still
	-- owns its writer lease. Wait for the terminal's on_exit callback before
	-- issuing the archive request so dismissal cannot race that cleanup.
	local session = state.sessions[thread.id]
	state.backend:interrupt_thread(thread.id, function(interrupt_err)
		if interrupt_err then
			callback(interrupt_err)
			return
		end
		close_session(session, function(close_err)
			if close_err then
				callback(close_err)
				return
			end
			state.backend:archive_thread(thread.id, callback)
		end)
	end)
end

local function bind_session(session, thread, identity_confirmed)
	if not session or not thread then
		return
	end
	local occupying = state.sessions[thread.id]
	if occupying and occupying ~= session then
		if terminal_running(occupying) or occupying.closing then
			return
		end
		occupying.closing = true
		finish_session_close(occupying)
	end
	if session.id == thread.id then
		if identity_confirmed then
			session.identity_confirmed = true
		end
		return
	end
	state.sessions[session.key] = nil
	local previous_key = session.key
	local placeholder = state.threads[previous_key] or state.dismissed_threads[previous_key]
	local was_dismissed = session.dismiss_when_bound or (placeholder and placeholder._dismissed)
	if placeholder and previous_key:match("^pending%-%d+$") then
		thread._unread = placeholder._unread
		thread._activity_at = placeholder._activity_at
		thread._dismiss_queued = placeholder._dismiss_queued
		state.threads[previous_key] = nil
		state.dismissed_threads[previous_key] = nil
		state.dismiss_pending[previous_key] = nil
	elseif placeholder then
		placeholder._local_status = "saved"
	end
	session.id = thread.id
	session.key = thread.id
	session.identity_confirmed = identity_confirmed == true
	session.switch_kind = nil
	session.switch_from_id = nil
	session.switch_started_at = nil
	state.sessions[thread.id] = session
	thread._local_status = was_dismissed and nil or session.frontend_status
	if session.unread ~= nil then
		thread._unread = session.unread
	end
	if session.activity_at then
		thread._activity_at = session.activity_at
	end
	if state.active_id == previous_key then
		state.active_id = thread.id
	end
	if state.selected_id == previous_key then
		state.selected_id = thread.id
	end
	for tab, id in pairs(state.selected_ids) do
		if id == previous_key then
			state.selected_ids[tab] = thread.id
		end
	end
	if was_dismissed then
		session.dismiss_when_bound = nil
		thread._dismissed = true
		thread._unread = false
		state.threads[thread.id] = nil
		state.dismissed_threads[thread.id] = thread
		state.dismiss_pending[thread.id] = true
		archive_thread_after_close(thread, function(err)
			state.dismiss_pending[thread.id] = nil
			if err then
				state.dismissed_threads[thread.id] = nil
				thread._dismissed = nil
				thread._local_status = nil
				state.threads[thread.id] = thread
				notify("Could not dismiss conversation: " .. tostring(err), vim.log.levels.WARN)
			end
			sort_threads()
			render_sidebar()
		end)
	end
end

local function identity_sessions()
	local candidates = {}
	for key, session in pairs(state.sessions) do
		-- A failed background resume must not reserve the canonical ID forever.
		local failed = session.active_elsewhere or session.frontend_status == "closed" or session.frontend_status == "error"
		if not session.id or terminal_running(session) or session.closing or (not session.job_id and not failed) then
			candidates[key] = session
		end
	end
	return candidates
end

local function associate_pending_sessions(threads)
	local matches, unresolved = Identity.matches(identity_sessions(), threads)
	for _, match in ipairs(matches) do
		bind_session(match.session, match.thread)
	end
	return unresolved
end

sort_threads = function()
	state.active_order = {}
	-- Local session events can arrive after switching projects, between polls.
	-- Keep the display boundary scoped as well as the backend list ingestion.
	for _, thread in pairs(state.threads) do
		if Project.contains(state.project, thread.cwd) and thread_matches_search(thread) then
			table.insert(state.active_order, thread)
		end
	end
	table.sort(state.active_order, function(left, right)
		local left_time = thread_time(left)
		local right_time = thread_time(right)
		if left_time == right_time then
			return tostring(left.id) > tostring(right.id)
		end
		return left_time > right_time
	end)
	state.dismissed_order = {}
	for _, thread in pairs(state.dismissed_threads) do
		if Project.contains(state.project, thread.cwd) and thread_matches_search(thread) then
			table.insert(state.dismissed_order, thread)
		end
	end
	table.sort(state.dismissed_order, function(left, right)
		local left_time = thread_time(left)
		local right_time = thread_time(right)
		if left_time == right_time then
			return tostring(left.id) > tostring(right.id)
		end
		return left_time > right_time
	end)

	state.order = state.recents_tab == "dismissed" and state.dismissed_order or state.active_order
	local visible = {}
	for _, thread in ipairs(state.order) do
		visible[thread.id] = true
	end
	local remembered_id = state.selected_ids[state.recents_tab]
	if state.selected_id and visible[state.selected_id] then
		remembered_id = state.selected_id
	end
	if not remembered_id or not visible[remembered_id] then
		remembered_id = state.order[1] and state.order[1].id or nil
		if state.sidebar_level == "runs" and state.sidebar_worktree
			and Project.worktree_for(state.project, state.sidebar_worktree)
		then
			remembered_id = nil
			for _, thread in ipairs(state.order) do
				local worktree = Project.worktree_for(state.project, thread.cwd)
				if worktree and worktree.path == state.sidebar_worktree then
					remembered_id = thread.id
					break
				end
			end
		end
	end
	state.selected_id = remembered_id
	state.selected_ids[state.recents_tab] = remembered_id
end

local refresh_threads
local refresh_dismissed_threads

detach_session_for_switch = function(session, command)
	if not session then
		return
	end
	session.pending_thread_switch = nil
	if not session.id or state.session_tokens[session.notify_token] ~= session then
		return
	end
	local previous_id = session.id
	if state.sessions[previous_id] == session then
		state.sessions[previous_id] = nil
	end
	local previous = state.threads[previous_id]
	if previous then
		previous._local_status = nil
	end

	state.pending_sequence = state.pending_sequence + 1
	local key = "pending-" .. state.pending_sequence
	session.id = nil
	session.key = key
	session.identity_confirmed = false
	session.initial_prompt = nil
	session.switch_kind = command
	session.switch_from_id = previous_id
	session.switch_started_at = os.time()
	session.frontend_status = nil
	session.default_status = "ready"
	session.known_ids = {}
	for id, thread in pairs(state.threads) do
		session.known_ids[id] = true
	end
	state.sessions[key] = session
	state.threads[key] = {
		id = key,
		cwd = session.cwd,
		createdAt = os.time(),
		updatedAt = os.time(),
		preview = command == "resume" and "Resumed conversation" or "New conversation",
	}
	state.threads[key]._activity_at = next_activity_time()
	session.activity_at = state.threads[key]._activity_at
	if state.active_id == previous_id then
		state.active_id = key
	end
	if state.selected_id == previous_id then
		state.selected_id = key
	end
	sort_threads()
	render_sidebar()
	vim.defer_fn(function()
		if refresh_threads then
			refresh_threads()
		end
	end, 150)
end

local function handle_backend_notification(method, params)
	if state.shutting_down then
		return
	end
	local started = method == "thread/started" and normalize(params.thread) or nil
	local id = started and started.id or params.threadId
	local status = started and normalize(started.status)
		or (method == "thread/status/changed" and normalize(params.status))
	local thread = id and state.threads[id]
	if not thread or type(status) ~= "table" or thread._dismissed
		or state.dismissed_threads[id] or state.dismiss_pending[id]
	then
		return
	end

	local previous = status_name(thread)
	thread.status = status
	local session = state.sessions[id]
	if session and status.type ~= "notLoaded" then
		session.default_status = "ready"
	end
	local current = status_name(thread)
	if dismiss_completed_thread(thread) then
		return
	end
	if current == "ready" and (previous == "working" or previous == "approval" or previous == "input") then
		thread._unread = not chat_is_focused(id)
		local session = state.sessions[id]
		if session then
			session.unread = thread._unread
		end
		bump_thread(thread)
	else
		render_sidebar()
	end
end

local function start_backend()
	if state.shutting_down then
		return
	end
	if not state.backend then
		state.backend = Backend.new({
			command = state.opts.command,
			connector = state.opts.connector,
			on_notification = handle_backend_notification,
			on_error = function(message)
				if state.shutting_down then
					return
				end
				state.backend_ready = false
				if message ~= state.last_backend_error then
					state.last_backend_error = message
					notify("Recents backend: " .. message, vim.log.levels.WARN)
				end
			end,
		})
	end
	local generation = state.refresh_generation
	state.backend:start(function(err)
		if state.shutting_down or generation ~= state.refresh_generation then
			return
		end
		if err then
			state.backend_ready = false
			return
		end
		state.backend_ready = true
		state.last_backend_error = nil
		refresh_threads()
		if state.recents_tab == "dismissed" then
			refresh_dismissed_threads()
		end
	end)
end

refresh_threads = function()
	if state.shutting_down or state.refreshing or not state.project or state.project.removing_worktree then
		return
	end
	if not state.backend_ready then
		start_backend()
		return
	end

	state.refreshing = true
	local generation = state.refresh_generation
	local backend = state.backend
	local status_revision = backend._status_revision
	local scope = project_key(state.project)
	local request_uses_state_db = state.history_repaired
	local request_params = request_uses_state_db and { archived = false, useStateDbOnly = true } or { archived = false }
	local function receive_threads(err, threads)
		if generation ~= state.refresh_generation then
			return
		end
		state.refreshing = false
		if state.shutting_down or (state.project and state.project.removing_worktree) then
			return
		end
		if not err and not request_uses_state_db then
			state.history_repaired = true
		end
		local scope_changed = scope ~= project_key(state.project)
		if err or scope_changed then
			if err then
				state.backend_ready = false
				if err ~= state.last_backend_error then
					state.last_backend_error = err
					notify("Recents backend: " .. tostring(err), vim.log.levels.WARN)
				end
			end
			if scope_changed then
				vim.schedule(refresh_threads)
			end
			return
		end
		state.last_backend_error = nil
		-- Identity lookups may outlive the list request. Preserve status events
		-- received during those lookups as well as during pagination.
		if backend.reconcile_statuses then
			backend:reconcile_statuses(threads, status_revision)
		end

		local unresolved = associate_pending_sessions(threads)
		local previous = state.threads
		local had_previous_threads = next(previous) ~= nil
		local next_threads = {}
		for _, thread in ipairs(threads) do
			thread.cwd = normalize(thread.cwd) or ""
			if Project.contains(state.project, thread.cwd) and not state.dismiss_pending[thread.id]
				and not unresolved[thread.id]
			then
				state.dismissed_threads[thread.id] = nil
				local old = previous[thread.id]
				local remote_activity = backend_thread_time(thread)
				local previous_remote = old and (old._remote_recency or backend_thread_time(old)) or 0
				if old then
					thread._unread = old._unread
					thread._activity_at = old._activity_at
					thread._dismiss_queued = old._dismiss_queued
				end
				local previous_status = old and status_name(old) or nil
				local session = state.sessions[thread.id]
				local external_activity = old
					and previous_remote > 0
					and remote_activity > previous_remote
					and not terminal_running(session)
				if external_activity then
					thread._unread = not chat_is_focused(thread.id)
					if session then
						session.unread = thread._unread
					end
				end
				if session then
					local running = terminal_running(session)
					if not running and session.job_id and not session.active_elsewhere
						and session.frontend_status ~= "error"
					then
						session.frontend_status = "closed"
					end
					local status = normalize(thread.status)
					if not running or (type(status) == "table" and status.type ~= "notLoaded") then
						session.default_status = "ready"
					end
					if session.unread ~= nil and not external_activity then
						thread._unread = session.unread
					end
					if session.activity_at then
						thread._activity_at = session.activity_at
					end
					if session.active_elsewhere and type(status) == "table" and status.type == "notLoaded" then
						session.active_elsewhere = false
						session.retry_after = nil
						session.frontend_status = "closed"
					end
					if session.active_elsewhere then
						thread._local_status = "active"
					elseif running then
						thread._local_status = session.frontend_status
					elseif session.frontend_status == "closed" or session.frontend_status == "error" then
						thread._local_status = session.frontend_status
					end
				end
				local current_status = status_name(thread)
				if old and not session and previous_status == "working" and current_status == "ready" then
					thread._activity_at = next_activity_time()
				elseif not old and had_previous_threads and not thread._activity_at then
					-- A newly discovered chat is a creation event and belongs at the top,
					-- regardless of timestamp precision or backend refresh timing.
					thread._activity_at = next_activity_time()
				end
				thread._remote_recency = remote_activity
				next_threads[thread.id] = thread
			end
		end
		for id, old in pairs(previous) do
			if not next_threads[id] and state.sessions[id] and old.cwd and Project.contains(state.project, old.cwd) then
				old._missing_count = (old._missing_count or 0) + 1
				if terminal_running(state.sessions[id]) or old._missing_count <= 2 then
					next_threads[id] = old
				elseif not state.sessions[id].closing then
					state.sessions[id].closing = true
					finish_session_close(state.sessions[id])
				end
			end
		end
		state.threads = next_threads
		sort_threads()
		for _, thread in ipairs(vim.tbl_values(next_threads)) do
			dismiss_completed_thread(thread)
		end
		render_sidebar()

		if state.auto_open_latest and state.recents_tab == "active" and state.active_order[1] then
			state.auto_open_latest = false
			vim.schedule(function()
				M.open_selected(false)
				focus_recents()
			end)
		end
		vim.schedule(preload_active_threads)
	end
	state.backend:list_threads(request_params, function(err, threads)
		if generation ~= state.refresh_generation then
			return
		end
		if err or state.shutting_down or scope ~= project_key(state.project) then
			receive_threads(err, threads)
			return
		end
		Identity.prepare(identity_sessions(), threads, function(id, callback)
			backend:read_thread(id, callback)
		end, function()
			receive_threads(nil, threads)
		end)
	end)
end

refresh_dismissed_threads = function()
	if state.shutting_down or state.dismissed_refreshing or not state.project then
		return
	end
	if not state.backend_ready then
		start_backend()
		return
	end

	state.dismissed_refreshing = true
	local generation = state.refresh_generation
	render_sidebar()
	local scope = project_key(state.project)
	local request_params = { archived = true }
	if state.history_repaired then
		request_params.useStateDbOnly = true
	end
	state.backend:list_threads(request_params, function(err, threads)
		if generation ~= state.refresh_generation then
			return
		end
		state.dismissed_refreshing = false
		if state.shutting_down then
			return
		end
		if scope ~= project_key(state.project) then
			vim.schedule(refresh_dismissed_threads)
			return
		end
		if err then
			if err ~= state.last_backend_error then
				state.last_backend_error = err
				notify("Dismissed recents: " .. tostring(err), vim.log.levels.WARN)
			end
			render_sidebar()
			return
		end

		state.last_backend_error = nil
		local next_dismissed = {}
		for _, thread in ipairs(threads) do
			thread.cwd = normalize(thread.cwd) or ""
			if Project.contains(state.project, thread.cwd) then
				local old = state.dismissed_threads[thread.id]
				thread._dismissed = true
				thread._local_status = nil
				thread._unread = false
				if old then
					thread._activity_at = old._activity_at
				end
				next_dismissed[thread.id] = thread
			end
		end
		for id, thread in pairs(state.dismissed_threads) do
			if state.dismiss_pending[id] then
				next_dismissed[id] = thread
			end
		end
		state.dismissed_threads = next_dismissed
		sort_threads()
		render_sidebar()
	end)
end

local function refresh_project_state(refresh_runs)
	local project = state.project
	if not project or project.worktrees_refreshing then return end
	local revision = project.worktree_revision
	project.worktrees_refreshing = true
	Project.refresh_worktrees(project, function(worktrees, err)
		project.worktrees_refreshing = nil
		if state.project ~= project or state.shutting_down or project.worktree_revision ~= revision then return end
		state.worktree_sync_error = err
		local changed = worktrees and not vim.deep_equal(project.worktrees, worktrees)
		if worktrees then
			local target = current_target()
			local previous_count = #project.worktrees
			project.worktrees = worktrees
			state.new_target = 1
			for index, worktree in ipairs(worktrees) do
				if target and target.path == worktree.path then state.new_target = index end
			end
			if #worktrees ~= previous_count and (#worktrees == 1 or previous_count == 1) then
				state.sidebar_level = #worktrees == 1 and "runs" or "worktrees"
			end
			sort_threads()
		end
		-- Discover worktrees before fetching runs so new worktrees pass containment checks.
		if refresh_runs ~= false or changed then
			refresh_threads()
			if state.recents_tab == "dismissed" then refresh_dismissed_threads() end
		end
		render_sidebar()
	end)
	Docker.refresh(project, state.docker, render_sidebar)
end

local function start_refresh_timer()
	if state.refresh_timer then
		return
	end
	state.refresh_timer = vim.uv.new_timer()
	state.refresh_timer:start(state.opts.refresh_interval, state.opts.refresh_interval, vim.schedule_wrap(function()
		if valid_tab(state.tab) or next(state.sessions) ~= nil then
			refresh_project_state()
		end
	end))
end

local function start_working_animation()
	if state.working_animation_timer then
		return
	end
	state.working_animation_timer = vim.uv.new_timer()
	state.working_animation_timer:start(80, 80, vim.schedule_wrap(function()
		if not valid_tab(state.tab) or not valid_buf(state.sidebar_buf) then
			return
		end
		local has_working_thread = false
		for _, thread in ipairs(state.order) do
			if status_name(thread) == "working" then
				has_working_thread = true
				break
			end
		end
		if has_working_thread then
			state.working_animation_frame = (state.working_animation_frame + 1) % 24
			render_working_animation()
		else
			state.working_animation_frame = 0
		end
	end))
end

local function process_notification(payload, notify_token)
	if payload.type ~= "agent-turn-complete" then
		return
	end
	local thread_id = payload["thread-id"]
	if type(thread_id) ~= "string" or thread_id == "" then
		return
	end
	local session = notify_token and state.session_tokens[notify_token] or nil
	if notify_token and not session then
		return
	end
	if state.dismissed_threads[thread_id] or state.dismiss_pending[thread_id] then
		return
	end

	-- This legacy CLI hook supplies identity only. Turn completion is not an
	-- authoritative runtime status (agent runs may continue across turns).
	if session and session.id == thread_id then
		session.identity_confirmed = true
		render_sidebar()
		return
	end
	if not session then
		-- Untagged notifications cannot identify a terminal.
		return
	end
	if session.identity_confirmed and not session.pending_thread_switch then
		return
	end
	if not state.backend then
		return
	end

	local expected_key = session.key
	local expected_switch = session.pending_thread_switch
	state.backend:read_thread(thread_id, function(err, result)
		if err or state.shutting_down or state.session_tokens[notify_token] ~= session
			or session.key ~= expected_key or session.pending_thread_switch ~= expected_switch
		then
			return
		end
		local thread = result and (result.thread or result)
		if not Backend.user_visible_thread(thread) or thread.id ~= thread_id
			or vim.fs.normalize(thread.cwd or "") ~= vim.fs.normalize(session.cwd)
		then
			return
		end
		if state.dismissed_threads[thread_id] or state.dismiss_pending[thread_id] then
			return
		end

		local function attach()
			if state.shutting_down or state.session_tokens[notify_token] ~= session
				or session.key ~= expected_key or session.pending_thread_switch ~= expected_switch
				or (state.sessions[thread_id] and state.sessions[thread_id] ~= session)
			then
				return
			end
			session.pending_thread_switch = nil
			if state.project and Project.contains(state.project, thread.cwd) then
				state.threads[thread_id] = thread
			end
			bind_session(session, thread, true)
			sort_threads()
			dismiss_completed_thread(thread)
			render_sidebar()
			vim.defer_fn(refresh_threads, 150)
		end

		local occupying = state.sessions[thread_id]
		if occupying and occupying ~= session then
			-- Never steal a live terminal's association. A failed preview/resume
			-- can be discarded after its process has exited.
			if terminal_running(occupying) then
				return
			end
			close_session(occupying, function(close_err)
				if not close_err then
					attach()
				end
			end)
		else
			attach()
		end
	end, { summary_only = true })
end

local function poll_notifications()
	if not state.notifier_enabled then
		return
	end
	local stat = vim.uv.fs_stat(state.notify_path)
	if not stat then
		return
	end
	if stat.size < state.notify_offset then
		state.notify_offset = 0
		state.notify_fragment = ""
	end
	if stat.size == state.notify_offset then
		return
	end
	local fd = vim.uv.fs_open(state.notify_path, "r", 438)
	if not fd then
		return
	end
	local chunk = vim.uv.fs_read(fd, stat.size - state.notify_offset, state.notify_offset)
	vim.uv.fs_close(fd)
	if not chunk or chunk == "" then
		return
	end
	state.notify_offset = state.notify_offset + #chunk
	local data = state.notify_fragment .. chunk
	local complete_to = data:match("^.*()\n")
	if not complete_to then
		state.notify_fragment = data
		return
	end
	local complete = data:sub(1, complete_to - 1)
	state.notify_fragment = data:sub(complete_to + 1)
	for line in (complete .. "\n"):gmatch("(.-)\n") do
		local notify_token, json = line:match("^([^\t]+)\t(.*)$")
		if not json then
			json = line
		end
		local decoded, payload = pcall(vim.json.decode, json)
		if decoded and type(payload) == "table" then
			process_notification(payload, notify_token)
		end
	end
end

function M.resync()
	if state.shutting_down or not state.project then
		return
	end
	poll_notifications()
	-- Invalidate in-flight lists before reconnecting the metadata client. The
	-- shared daemon and its interactive terminals continue running normally.
	state.refresh_generation = state.refresh_generation + 1
	state.refreshing = false
	state.dismissed_refreshing = false
	state.history_repaired = false
	state.backend_ready = false
	for _, session in pairs(state.sessions) do
		if not terminal_running(session) and not session.closing then
			session.default_status = "ready"
			session.active_elsewhere = false
			session.retry_after = nil
			if session.frontend_status ~= "error" then
				session.frontend_status = "closed"
			end
			local thread = thread_for_session(session)
			if thread then
				thread._local_status = session.frontend_status
			end
		end
	end
	if state.backend then
		state.backend:stop()
	end
	start_backend()
	state.docker.checked = nil
	refresh_project_state(false)
	render_sidebar()
end

local function start_notification_watcher()
	if state.notify_timer then
		return
	end
	state.notifier_enabled = vim.fn.executable("agent-mode-notify") == 1
	if not state.notifier_enabled then
		return
	end
	local cache_dir = vim.fn.stdpath("cache")
	pcall(vim.fn.mkdir, cache_dir, "p")
	state.notify_path = cache_dir .. "/agent-mode-notify-" .. vim.fn.getpid() .. ".jsonl"
	local created, write_result = pcall(vim.fn.writefile, {}, state.notify_path)
	if not created or write_result ~= 0 then
		state.notifier_enabled = false
		state.notify_path = nil
		notify("Could not create the turn-status log", vim.log.levels.WARN)
		return
	end
	state.notify_offset = 0
	state.notify_fragment = ""
	state.notify_timer = vim.uv.new_timer()
	state.notify_timer:start(250, 250, vim.schedule_wrap(poll_notifications))
end

local function hide_composer()
	if state.composer and valid_win(state.composer.win) then
		pcall(vim.api.nvim_win_close, state.composer.win, true)
		state.composer.win = nil
	end
end

local function show_composer()
	if not state.composer or not valid_buf(state.composer.buf)
		or not valid_buf(state.composer.background_buf) or not valid_win(state.chat_win)
	then
		return false
	end
	vim.api.nvim_win_set_buf(state.chat_win, state.composer.background_buf)
	set_window_options(state.chat_win, false)
	vim.wo[state.chat_win].wrap = true
	render_composer(state.composer.message)
	vim.api.nvim_set_current_win(state.composer.win)
	local last_row = math.max(1, vim.api.nvim_buf_line_count(state.composer.buf))
	local last_line = vim.api.nvim_buf_get_lines(state.composer.buf, last_row - 1, last_row, false)[1] or ""
	pcall(vim.api.nvim_win_set_cursor, state.composer.win, { last_row, #last_line })
	vim.cmd("startinsert")
	return true
end

local function move_selection(delta)
	local groups, group = Sidebar.groups(state)
	local order = group and group.threads or {}
	local index = 1
	for i, thread in ipairs(order) do if thread.id == state.selected_id then index = i end end
	-- Stepping beyond the runs returns to browsing worktree headers. Keep
	-- gg/G scoped to the current list, since they jump rather than step.
	if state.sidebar_level == "runs" and (delta == -1 or delta == 1)
		and (#order == 0 or index + delta < 1 or index + delta > #order)
	then
		state.sidebar_level = "worktrees"
	end
	if state.sidebar_level == "worktrees" then
		local index = 1
		for i, item in ipairs(groups) do if item == group then index = i end end
		group = groups[math.max(1, math.min(#groups, index + delta))]
		if group then state.sidebar_worktree = group.worktree.path end
		state.sidebar_action = 1
		render_sidebar()
		return
	end
	if #order == 0 then return end
	index = math.max(1, math.min(#order, index + delta))
	if state.selected_id == order[index].id then return end
	state.selected_id = order[index].id
	render_sidebar()
	M.preload_selected()
end

function M.preload_selected()
	if state.sidebar_level == "worktrees" then return end
	if not state.selected_id or not valid_win(state.chat_win) then
		return
	end
	if not state.preview_timer then
		state.preview_timer = vim.uv.new_timer()
	end
	local selected_id = state.selected_id
	state.preview_timer:stop()
	state.preview_timer:start(state.opts.preview_delay, 0, vim.schedule_wrap(function()
		if state.shutting_down
			or state.selected_id ~= selected_id
			or state.sidebar_level == "worktrees"
			or not valid_win(state.sidebar_win)
			or not valid_win(state.chat_win)
		then
			return
		end
		M.open_selected(false)
	end))
end

select_sidebar_row = function(row)
	local path = state.row_groups and state.row_groups[row]
	if path then
		if state.sidebar_worktree ~= path or state.sidebar_level ~= "worktrees" then
			state.sidebar_worktree, state.sidebar_level, state.sidebar_action = path, "worktrees", 1
			render_sidebar()
		end
		return
	end
	local selected_id = state.row_threads and state.row_threads[row] or nil
	if not selected_id then
		return
	end
	local changed_level = state.sidebar_level ~= "runs"
	state.sidebar_level = "runs"
	local thread = state.threads[selected_id] or state.dismissed_threads[selected_id]
	local cleared_unread = thread and thread._unread
	if cleared_unread then
		thread._unread = false
		local session = state.sessions[selected_id]
		if session then
			session.unread = false
		end
	end
	if selected_id == state.selected_id then
		if cleared_unread or changed_level then
			render_sidebar()
		end
		return
	end
	state.selected_id = selected_id
	render_sidebar()
	M.preload_selected()
end

local function switch_recents_tab(tab, selected_id)
	if tab ~= "active" and tab ~= "dismissed" then
		return
	end
	state.selected_ids[state.recents_tab] = state.selected_id
	state.recents_tab = tab
	state.selected_id = selected_id
	state.selected_ids[tab] = nil
	sort_threads()
	render_sidebar()
	if valid_win(state.sidebar_win) then
		vim.api.nvim_win_call(state.sidebar_win, function()
			-- Tab changes start at the first conversation in the new list.
			vim.fn.winrestview({ topline = 1, topfill = 0, leftcol = 0, skipcol = 0 })
		end)
	end
	if tab == "dismissed" then
		refresh_dismissed_threads()
	end
	if state.selected_id then
		M.preload_selected()
	elseif valid_win(state.chat_win) then
		render_placeholder()
	end
end

local function toggle_recents_tab()
	switch_recents_tab(state.recents_tab == "active" and "dismissed" or "active")
end

local function cycle_recents_tab(delta)
	local tabs = { "active", "dismissed" }
	local index = vim.fn.index(tabs, state.recents_tab)
	index = (index + delta) % #tabs
	switch_recents_tab(tabs[index + 1])
end

local open_new_chat

local function move_to_dismissed(thread, skip_preview)
	local selected_position = nil
	if state.recents_tab == "active" and state.selected_id == thread.id then
		selected_position = selected_index()
	end
	local replace_open_chat = state.active_id == thread.id
	state.threads[thread.id] = nil
	thread._dismissed = true
	thread._local_status = nil
	thread._unread = false
	state.dismissed_threads[thread.id] = thread
	if state.active_id == thread.id then
		state.active_id = nil
	end
	sort_threads()
	if selected_position then
		local replacement = state.order[math.min(selected_position, #state.order)]
		state.selected_id = replacement and replacement.id or nil
		state.selected_ids.active = state.selected_id
	end
	render_sidebar()
	if skip_preview then
		return
	end
	if state.selected_id then
		if replace_open_chat then
			M.open_selected(false)
		else
			M.preload_selected()
		end
	elseif valid_win(state.chat_win) then
		open_new_chat()
	end
end

local function move_to_active(thread)
	state.dismissed_threads[thread.id] = nil
	thread._dismissed = nil
	thread._local_status = nil
	thread._unread = false
	state.threads[thread.id] = thread
	sort_threads()
	render_sidebar()
	if state.selected_id then
		M.preload_selected()
	elseif valid_win(state.chat_win) then
		render_placeholder()
	end
end

local function recheck_queued_dismissal(thread)
	local backend = state.backend
	if not state.backend_ready or not backend or not backend.read_thread
		or tostring(thread.id):match("^pending%-%d+$")
	then
		return
	end
	local id, queued = thread.id, thread._dismiss_queued
	local generation, revision = state.refresh_generation, backend._status_revision
	backend:read_thread(id, function(err, result)
		local current = state.threads[id]
		if err or state.shutting_down or state.backend ~= backend
			or state.refresh_generation ~= generation
			or not current or current._dismiss_queued ~= queued
		then
			return
		end
		local latest = result and normalize(result.thread)
		if type(latest) ~= "table" or latest.id ~= id then
			return
		end
		-- A status event received during the read takes precedence over its snapshot.
		if backend.reconcile_statuses then
			backend:reconcile_statuses({ latest }, revision)
		end
		handle_backend_notification("thread/status/changed", { threadId = id, status = latest.status })
	end, { summary_only = true })
end

local function dismiss_thread(thread, skip_preview)
	if not thread or state.dismiss_pending[thread.id] or state.move_pending[thread.id] then
		return
	end
	if thread._dismiss_queued or status_name(thread) == "working" then
		-- A unique token prevents a cancelled queue's reply from dismissing a later run.
		thread._dismiss_queued = not thread._dismiss_queued and {} or nil
		render_sidebar()
		if thread._dismiss_queued then
			recheck_queued_dismissal(thread)
		end
		return
	end
	if tostring(thread.id):match("^pending%-%d+$") then
		local session = state.sessions[thread.id]
		if session then
			session.dismiss_when_bound = true
			state.dismiss_pending[thread.id] = true
			move_to_dismissed(thread, skip_preview)
		end
		return
	end
	if not state.backend_ready then
		notify("The recents backend is not ready", vim.log.levels.WARN)
		start_backend()
		return
	end

	state.dismiss_pending[thread.id] = true
	move_to_dismissed(thread, skip_preview)
	archive_thread_after_close(thread, function(err)
		state.dismiss_pending[thread.id] = nil
		if err then
			if state.dismissed_threads[thread.id] == thread then
				move_to_active(thread)
			end
			notify("Could not dismiss conversation: " .. tostring(err), vim.log.levels.WARN)
		end
	end)
end

dismiss_completed_thread = function(thread)
	-- Only authoritative terminal states finish a queued run. Approval/input
	-- pauses and unloaded snapshots must leave it running and cancellable.
	local status = normalize(thread.status)
	if not thread._dismiss_queued or type(status) ~= "table"
		or (status.type ~= "idle" and status.type ~= "systemError")
		or not state.backend_ready
	then
		return false
	end
	thread._dismiss_queued = nil
	dismiss_thread(thread)
	return thread._dismissed == true
end

local function restore_thread(thread, on_restored)
	if not thread or state.dismiss_pending[thread.id] then
		return
	end
	if not state.backend_ready then
		notify("The recents backend is not ready", vim.log.levels.WARN)
		start_backend()
		return
	end

	local scope = project_key(state.project)
	state.dismiss_pending[thread.id] = true
	state.backend:unarchive_thread(thread.id, function(err, result)
		if state.shutting_down or scope ~= project_key(state.project) then
			return
		end
		state.dismiss_pending[thread.id] = nil
		if err then
			notify("Could not restore conversation: " .. tostring(err), vim.log.levels.WARN)
			return
		end
		local restored = result and result.thread or thread
		restored.cwd = normalize(restored.cwd) or thread.cwd or ""
		if not Project.contains(state.project, restored.cwd) then
			return
		end
		move_to_active(restored)
		if on_restored then
			on_restored(restored)
		end
		refresh_threads()
	end)
end

local function restore_and_open_thread(thread)
	restore_thread(thread, function(restored)
		bump_thread(restored)
		switch_recents_tab("active", restored.id)
		if state.preview_timer then
			state.preview_timer:stop()
		end
		M.open_selected(true)
	end)
end

local function toggle_dismissed()
	local thread = selected_thread()
	if state.recents_tab == "dismissed" then
		restore_thread(thread)
	else
		dismiss_thread(thread)
	end
end

local function fork_selected()
	local thread = selected_thread()
	if not thread or state.fork_pending[thread.id] or state.dismiss_pending[thread.id] or state.move_pending[thread.id] then
		return
	end
	if tostring(thread.id):match("^pending%-%d+$") then
		notify("Wait for this conversation to finish saving before forking", vim.log.levels.INFO)
		return
	end
	if not state.backend_ready then
		notify("The recents backend is not ready", vim.log.levels.WARN)
		start_backend()
		return
	end
	local scope, backend = project_key(state.project), state.backend
	local pending = state.fork_pending
	pending[thread.id] = true
	backend:fork_thread(thread.id, function(err, result)
		pending[thread.id] = nil
		if state.shutting_down or scope ~= project_key(state.project) or backend ~= state.backend then
			return
		end
		if err then
			notify("Could not fork conversation: " .. tostring(err), vim.log.levels.WARN)
			return
		end
		local fork = result.thread
		fork.cwd = normalize(fork.cwd) or thread.cwd or ""
		if not Project.contains(state.project, fork.cwd) then
			return
		end
		fork._activity_at = next_activity_time()
		fork._unread = false
		state.threads[fork.id] = fork
		state.search_term, state.search = nil, nil
		state.auto_open_latest = false
		switch_recents_tab("active", fork.id)
		if state.preview_timer then
			state.preview_timer:stop()
		end
		M.open_selected(true)
	end)
end

local function search_recents(search)
	if state.search ~= search or state.shutting_down then
		return
	end
	local backend = state.backend
	for _, tab in ipairs({ "active", "dismissed" }) do
		local function receive(err, threads)
			if state.search ~= search or state.shutting_down or backend ~= state.backend then
				return
			end
			search.pending[tab] = nil
			search.errors[tab] = err
			if err then
				notify("Recents search: " .. tostring(err), vim.log.levels.WARN)
			else
				local cache = tab == "active" and state.threads or state.dismissed_threads
				local other = tab == "active" and state.dismissed_threads or state.threads
				for _, thread in ipairs(threads) do
					if Project.contains(state.project, thread.cwd) and not state.dismiss_pending[thread.id] then
						search.matches[thread.id] = true
						-- Search can discover older rows before the regular poll does.
						-- Keep existing runtime status and local archive decisions intact.
						if not cache[thread.id] and not other[thread.id] then
							thread._dismissed = tab == "dismissed" or nil
							cache[thread.id] = thread
						end
					end
				end
			end
			sort_threads()
			render_sidebar()
		end
		if backend then
			backend:search_threads({ archived = tab == "dismissed", searchTerm = search.term }, receive)
		else
			receive("The recents backend is not ready")
		end
	end
end

local function set_recents_filter(input)
	local term = vim.trim(input)
	term = term ~= "" and term or nil
	if term ~= state.search_term or (state.search and next(state.search.errors)) then
		state.search_term = term
		state.search = term and {
			term = term, matches = {}, pending = { active = true, dismissed = true }, errors = {},
		} or nil
		if state.search then
			local search = state.search
			vim.defer_fn(function() search_recents(search) end, 150)
		end
	end
	-- Clearing restores the complete caches immediately, without a backend round trip.
	sort_threads()
	render_sidebar()
end

local function finish_recents_filter(apply, leaving)
	local filter = state.filter
	local input = ""
	if filter then
		if apply and valid_buf(filter.buf) then
			input = (vim.api.nvim_buf_get_lines(filter.buf, 0, 1, false)[1] or ""):sub(#filter.prompt + 1)
		end
		state.filter = nil
		vim.cmd("stopinsert")
		if valid_win(filter.win) then
			vim.api.nvim_win_close(filter.win, true)
		end
		if valid_buf(filter.buf) then
			vim.api.nvim_buf_delete(filter.buf, { force = true })
		end
		if not leaving then
			layout_overlay()
		end
		if not leaving and valid_win(state.sidebar_win) then
			vim.api.nvim_set_current_win(state.sidebar_win)
		end
	end
	set_recents_filter(input)
	if leaving then
		return
	end
	if state.selected_id then
		M.preload_selected()
	elseif valid_win(state.chat_win) then
		render_placeholder()
	end
end

local function filter_recents()
	if state.filter or not valid_win(state.sidebar_win) then
		return
	end
	local filter = { buf = vim.api.nvim_create_buf(false, true), prompt = "  Filter: " }
	state.filter = filter
	set_scratch_options(filter.buf, "agentmodefilter")
	vim.bo[filter.buf].modifiable = true
	vim.bo[filter.buf].buftype = "prompt"
	vim.fn.prompt_setprompt(filter.buf, filter.prompt)
	vim.api.nvim_buf_set_lines(filter.buf, 0, -1, false, { filter.prompt .. (state.search_term or "") })
	-- Reserve the first two sidebar rows without splitting the editor beneath us.
	filter.win = vim.api.nvim_open_win(filter.buf, true, {
		relative = "editor", row = 0, col = 0,
		width = vim.api.nvim_win_get_width(state.sidebar_win), height = 1,
		style = "minimal", border = "none", zindex = 40,
	})
	layout_overlay()
	set_window_options(filter.win, true)
	vim.wo[filter.win].winfixheight = true
	vim.wo[filter.win].statusline = "  [Enter] apply  [Esc] cancel"
	local options = { buffer = filter.buf, silent = true, nowait = true }
	vim.keymap.set({ "i", "n" }, "<CR>", function() finish_recents_filter(true) end, options)
	for _, key in ipairs({ "<Esc>", "<C-c>" }) do
		vim.keymap.set({ "i", "n" }, key, function() finish_recents_filter(false) end, options)
	end
	vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
		buffer = filter.buf,
		callback = function()
			if state.filter == filter then
				local line = vim.api.nvim_buf_get_lines(filter.buf, 0, 1, false)[1] or ""
				set_recents_filter(line:sub(#filter.prompt + 1))
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufLeave", {
		buffer = filter.buf,
		callback = function()
			vim.schedule(function()
				if state.filter == filter then
					finish_recents_filter(false)
				end
			end)
		end,
	})
	render_sidebar()
	vim.api.nvim_win_set_cursor(filter.win, { 1, #filter.prompt + #(state.search_term or "") })
	vim.cmd("startinsert!")
end

local function cycle_worktree()
	if not state.project or state.project.creating_worktree or #state.project.worktrees == 0 or (state.composer and state.composer.busy) then
		return
	end
	state.new_target = (state.new_target % #state.project.worktrees) + 1
	state.new_worktree = false
	state.new_worktree_name = nil
	update_composer_frame()
end

-- UI callbacks may arrive after the user has changed projects or submitted a chat.
local function worktree_prompt_context()
	local project, composer = state.project, state.composer
	if not project or not project.common_dir then
		notify("Worktrees require a Git repository", vim.log.levels.WARN)
		return
	end
	if project.creating_worktree or (composer and composer.busy) then
		return
	end
	local win = vim.api.nvim_get_current_win()
	local inserting = vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
	local function current()
		return not state.shutting_down and project_key(state.project) == project_key(project) and state.composer == composer
			and not (composer and composer.busy)
	end
	local function restore()
		vim.schedule(function()
			if current() and inserting and valid_win(win) and vim.api.nvim_get_current_win() == win then
				vim.cmd("startinsert")
			end
		end)
	end
	return project, current, restore
end

function M.select_worktree()
	local project, current, restore = worktree_prompt_context()
	if not project then
		return
	end
	local discovered = Project.discover(project.launch_cwd)
	local target = current_target()
	local choices = vim.list_extend({}, discovered.worktrees)
	local branches, err = Project.recent_branches(discovered, 10)
	if err then notify("Could not load recent branches: " .. err, vim.log.levels.WARN) end
	for _, branch in ipairs(branches or {}) do
		table.insert(choices, { new_branch = branch })
	end
	local selected = 1
	for index, worktree in ipairs(discovered.worktrees) do
		if target and target.path == worktree.path then selected = index; break end
	end
	Sidebar.select_worktree(choices, {
		prompt = "Select worktree for new chat:",
		selected = selected,
		format_item = function(worktree)
			if worktree.new_branch then return "  + " .. worktree.new_branch .. " — create worktree" end
			local selected = target and target.path == worktree.path and not state.new_worktree
			return (selected and "* " or "  ") .. (worktree.label or vim.fs.basename(worktree.path))
				.. " — " .. worktree.path
		end,
	}, function(worktree, index)
		if current() and worktree then
			if worktree.new_branch then
				project.creating_worktree = true
				Project.create_worktree(project, nil, function(create_err, path)
					project.creating_worktree = nil
					if create_err then
						notify(create_err, vim.log.levels.ERROR)
					elseif current() then
						state.project.worktree_revision = (state.project.worktree_revision or 0) + 1
						state.project.worktrees = Project.discover(path).worktrees
						for position, tree in ipairs(state.project.worktrees) do
							if tree.path == path then state.new_target = position; break end
						end
						state.new_worktree, state.new_worktree_name = false, nil
						state.sidebar_worktree, state.sidebar_level = path, "worktrees"
						render_sidebar()
						update_composer_frame()
					else
						notify("Worktree created at " .. path, vim.log.levels.INFO)
					end
					restore()
				end, nil, worktree.new_branch)
				return
			end
			state.project.worktrees = discovered.worktrees
			state.new_target = index
			state.new_worktree = false
			state.new_worktree_name = nil
			update_composer_frame()
		end
		restore()
	end)
end

local function move_selected_to_new_worktree()
	local thread, project, backend = selected_thread(), state.project, state.backend
	if not thread then
		return
	end
	if thread._dismissed then
		notify("Restore this conversation before moving it", vim.log.levels.INFO)
		return
	end
	if state.move_pending[thread.id] or state.dismiss_pending[thread.id] or state.fork_pending[thread.id] then
		return
	end
	if not project or not project.common_dir then
		notify("Worktrees require a Git repository", vim.log.levels.WARN)
		return
	end
	if tostring(thread.id):match("^pending%-%d+$") then
		notify("Wait for this conversation to finish saving before moving it", vim.log.levels.INFO)
		return
	end
	local function available()
		local status = status_name(state.threads[thread.id] or thread)
		return status ~= "working" and status ~= "approval" and status ~= "input"
	end
	if not available() then
		notify("Wait for this conversation to finish working before moving it", vim.log.levels.INFO)
		return
	end
	if not state.backend_ready or not backend then
		notify("The recents backend is not ready", vim.log.levels.WARN)
		return
	end
	local scope, source = project_key(project), thread.cwd
	local function current()
		return not state.shutting_down and project_key(state.project) == scope and state.backend == backend
	end
	vim.ui.input({ prompt = "New worktree name: " }, function(name)
		if not current() or state.selected_id ~= thread.id or state.recents_tab ~= "active"
			or not name or vim.trim(name) == "" or not available()
			or state.move_pending[thread.id] or state.dismiss_pending[thread.id]
			or state.fork_pending[thread.id] or not state.threads[thread.id]
		then
			return
		end
		name = vim.trim(name)
		local name_err = Project.worktree_name_error(name)
		if name_err then
			notify(name_err, vim.log.levels.WARN)
			return
		end
		state.move_pending[thread.id] = true
		Project.create_worktree(project, source, function(create_err, path)
			local function finish(err, moved)
				state.move_pending[thread.id] = nil
				if not current() then return end
				local target = current_target()
				state.project.worktrees = Project.discover(project.launch_cwd).worktrees
				for index, worktree in ipairs(state.project.worktrees) do
					if target and worktree.path == target.path then state.new_target = index end
				end
				if err then
					notify("Could not move conversation: " .. tostring(err)
						.. (path and (". Created worktree: " .. path) or ""), vim.log.levels.WARN)
				else
					state.threads[thread.id] = vim.tbl_extend("force", state.threads[thread.id] or thread, moved or {}, {
						cwd = path,
					})
				end
				sort_threads()
				render_sidebar()
				if state.selected_id == thread.id then M.open_selected(false) end
				refresh_threads()
			end
			if create_err or not current() or not available() then
				finish(create_err or "The conversation changed while creating the worktree")
				return
			end
			close_session(state.sessions[thread.id], function(close_err)
				if close_err or not current() then
					finish(close_err or "The project changed")
					return
				end
				backend:move_thread(thread.id, path, finish)
			end)
		end, name)
	end)
end

function M.new_worktree()
	if vim.api.nvim_get_current_buf() == state.sidebar_buf then
		move_selected_to_new_worktree()
		return
	end
	local project, current, restore = worktree_prompt_context()
	if not project then
		return
	end
	vim.ui.input({ prompt = "New worktree name: ", default = state.new_worktree_name or "" }, function(name)
		if current() and name and vim.trim(name) ~= "" then
			name = vim.trim(name)
			local err = Project.worktree_name_error(name)
			if err then
				notify(err, vim.log.levels.WARN)
			else
				state.new_worktree = true
				state.new_worktree_name = name
				update_composer_frame()
			end
		end
		restore()
	end)
end

function M.toggle_worktree()
	if not state.new_worktree and (not state.project or not state.project.common_dir) then
		notify("A fresh worktree requires a Git repository", vim.log.levels.WARN)
		return
	end
	state.new_worktree = not state.new_worktree
	state.new_worktree_name = nil
	update_composer_frame()
end

local function close_worktree_sessions(project, worktree, callback)
	local backend = state.backend
	if not backend then callback("The recents backend is not ready"); return end
	local function belongs(cwd)
		local tree = Project.worktree_for(project, cwd)
		return tree and tree.path == worktree.path
	end
	local function current()
		return state.project == project and state.backend == backend and not state.shutting_down
	end
	local sessions = {}
	for _, session in pairs(state.sessions) do
		if belongs(session.cwd) then table.insert(sessions, session) end
	end
	-- Close terminals first, including new chats without a canonical ID. The
	-- daemon keeps their turns alive, so list persisted threads after exit and
	-- interrupt them explicitly before archiving and removing the checkout.
	local function close_next(index)
		if not current() then callback("The project changed"); return end
		local session = sessions[index]
		if session then
			close_session(session, function(err)
				if err then callback(err); return end
				if not current() then callback("The project changed"); return end
				if not session.id then
					state.threads[session.key] = nil
					state.dismissed_threads[session.key] = nil
					state.dismiss_pending[session.key] = nil
					if state.active_id == session.key then state.active_id = nil end
				end
				close_next(index + 1)
			end)
			return
		end
		backend:list_threads({ archived = false }, function(err, threads)
			if err then callback(err); return end
			if not current() then callback("The project changed"); return end
			local targets = vim.tbl_filter(function(thread) return belongs(thread.cwd) end, threads)
			local function archive_next(position)
				if not current() then callback("The project changed"); return end
				local thread = targets[position]
				if not thread then callback(); return end
				state.dismiss_pending[thread.id] = true
				local function finish(archive_err)
					state.dismiss_pending[thread.id] = nil
					if archive_err then callback(archive_err); return end
					if not current() then callback("The project changed"); return end
					thread._dismiss_queued = nil
					move_to_dismissed(thread, true)
					archive_next(position + 1)
				end
				backend:interrupt_thread(thread.id, function(interrupt_err)
					if interrupt_err then finish(interrupt_err); return end
					if not current() then finish("The project changed"); return end
					backend:archive_thread(thread.id, finish)
				end)
			end
			archive_next(1)
		end)
	end
	close_next(1)
end

local function remove_selected_worktree()
	if state.sidebar_level ~= "worktrees" then return end
	local project = state.project
	local _, group = Sidebar.groups(state)
	if not project or not project.common_dir or not group or project.removing_worktree or project.renaming_worktree then return end
	local worktree = vim.deepcopy(group.worktree)
	worktree.docker = Docker.supported(project)
	local docker_cache = state.docker
	if project.worktrees[1].path == worktree.path then
		notify("The main worktree cannot be removed", vim.log.levels.WARN)
		return
	end
	project.removing_worktree = worktree.path
	Sidebar.confirm_remove(worktree, function(confirmed)
		if not confirmed or state.project ~= project or state.shutting_down then
			project.removing_worktree = nil
			return
		end
		Project.remove_worktree(project, worktree, function(err, branch)
			project.removing_worktree = nil
			if err then notify("Could not remove worktree: " .. err, vim.log.levels.WARN); return end
			notify("Removed worktree. Local branch kept: " .. branch)
			if state.project ~= project or state.shutting_down then return end
			project.worktree_revision = (project.worktree_revision or 0) + 1
			local target = current_target()
			project.worktrees = vim.tbl_filter(function(tree) return tree.path ~= worktree.path end, project.worktrees)
			local fallback = project.worktrees[1]
			if project.current_worktree == worktree.path and fallback then
				project.current_worktree, project.launch_cwd = fallback.path, fallback.path
			end
			state.new_target = 1
			for index, tree in ipairs(project.worktrees) do
				if target and tree.path == target.path then state.new_target = index end
			end
			sort_threads()
			render_sidebar()
			refresh_project_state()
		end, function(done)
			close_worktree_sessions(project, worktree, function(err)
				if err then done(err); return end
				if worktree.docker then
					Docker.destroy(worktree.path, docker_cache, render_sidebar, done)
				else
					done()
				end
			end)
		end)
	end)
end

local function rename_selected_worktree()
	if state.sidebar_level ~= "worktrees" then return end
	local project = state.project
	local _, group = Sidebar.groups(state)
	if not project or not project.common_dir or not group or project.removing_worktree or project.renaming_worktree then return end
	local worktree = vim.deepcopy(group.worktree)
	project.renaming_worktree = worktree.path
	vim.ui.input({ prompt = "Rename worktree / branch: ", default = worktree.branch or vim.fs.basename(worktree.path) }, function(name)
		if state.project ~= project or state.shutting_down or not name or vim.trim(name) == "" then
			project.renaming_worktree = nil
			return
		end
		name = vim.trim(name)
		Project.rename_worktree(project, worktree, name, function(err, branch)
			project.renaming_worktree = nil
			if err then notify("Could not rename worktree: " .. err, vim.log.levels.WARN); return end
			if state.project ~= project or state.shutting_down then return end
			project.worktree_revision = (project.worktree_revision or 0) + 1
			for _, tree in ipairs(project.worktrees) do
				if tree.path == worktree.path then tree.branch, tree.label = branch, branch end
			end
			if project.default_branch == worktree.branch then project.default_branch = branch end
			update_composer_frame()
			refresh_project_state()
		end)
	end)
end

local function sidebar_mappings()
	local options = { buffer = state.sidebar_buf, silent = true, nowait = true }
	vim.keymap.set("n", "j", function()
		move_selection(1)
	end, vim.tbl_extend("force", options, { desc = "Next Agent Mode recent" }))
	vim.keymap.set("n", "k", function()
		move_selection(-1)
	end, vim.tbl_extend("force", options, { desc = "Previous Agent Mode recent" }))
	vim.keymap.set("n", "<Down>", function()
		move_selection(1)
	end, options)
	vim.keymap.set("n", "<Up>", function()
		move_selection(-1)
	end, options)
	vim.keymap.set("n", "/", filter_recents, vim.tbl_extend("force", options, {
		desc = "Filter Agent Mode recents",
	}))
	vim.keymap.set("n", "<Esc>", function()
		if state.search_term then
			finish_recents_filter(false)
		else
			state.sidebar_level, state.sidebar_action = "worktrees", 1
			render_sidebar()
		end
	end, vim.tbl_extend("force", options, { desc = "Clear filter or return to worktrees" }))
	vim.keymap.set("n", "<Tab>", toggle_recents_tab, vim.tbl_extend("force", options, {
		desc = "Switch Agent Mode recents tab",
	}))
	vim.keymap.set("n", "[", function()
		cycle_recents_tab(-1)
	end, vim.tbl_extend("force", options, { desc = "Show previous Agent Mode recents tab" }))
	vim.keymap.set("n", "]", function()
		cycle_recents_tab(1)
	end, vim.tbl_extend("force", options, { desc = "Show next Agent Mode recents tab" }))
	vim.keymap.set("n", "d", function()
		if state.sidebar_level == "worktrees" then
			local _, group = Sidebar.groups(state)
			if group and Docker.supported(state.project) and state.project.removing_worktree ~= group.worktree.path then
				Docker.run(group.worktree.path, "down", state.docker, render_sidebar, notify)
			end
		else
			toggle_dismissed()
		end
	end, vim.tbl_extend("force", options, {
		desc = "Docker down for worktree, or dismiss/restore run",
	}))
	vim.keymap.set("n", "r", function()
		local _, group = Sidebar.groups(state)
		restart_worktree(group and group.worktree)
	end, vim.tbl_extend("force", options, { desc = "Restart worktree Docker (resync for other projects)" }))
	vim.keymap.set("n", "<C-r>", M.resync, vim.tbl_extend("force", options, { desc = "Resync Agent Mode recents" }))
	vim.keymap.set("n", "a", rename_selected_worktree, vim.tbl_extend("force", options, { desc = "Rename worktree / branch" }))
	vim.keymap.set("n", "f", fork_selected, vim.tbl_extend("force", options, {
		desc = "Fork and focus Agent Mode chat",
	}))
	vim.keymap.set("n", "D", remove_selected_worktree, vim.tbl_extend("force", options, {
		desc = "Remove worktree (keep branch)",
	}))
	vim.keymap.set("n", "gg", function() move_selection(-math.huge) end, options)
	vim.keymap.set("n", "G", function() move_selection(math.huge) end, options)
	for key, delta in pairs({ h = -1, l = 1 }) do
		vim.keymap.set("n", key, function()
			if state.sidebar_level == "worktrees" and Docker.supported(state.project) then
				state.sidebar_action = ((state.sidebar_action - 1 + delta) % 3) + 1
				render_sidebar()
			end
		end, options)
	end
	vim.keymap.set("n", "<CR>", function()
		if state.sidebar_level == "worktrees" then
			local _, group = Sidebar.groups(state)
			if not group or state.project.removing_worktree == group.worktree.path then return end
			if state.sidebar_action > 1 and Docker.supported(state.project) then
				Docker.run(group.worktree.path, state.sidebar_action == 2 and "up" or "down",
					state.docker, render_sidebar, notify)
			else
				state.sidebar_level = "runs"
				state.selected_id = group.threads[1] and group.threads[1].id or nil
				state.selected_ids[state.recents_tab] = state.selected_id
				for i, worktree in ipairs(state.project.worktrees) do
					if worktree.path == group.worktree.path then state.new_target = i end
				end
				render_sidebar()
				M.preload_selected()
			end
			return
		end
		local thread = selected_thread()
		if thread and thread._dismissed then
			restore_and_open_thread(thread)
		else
			M.open_selected(true)
		end
	end, vim.tbl_extend("force", options, { desc = "Restore or open Agent Mode chat" }))
	for _, key in ipairs({ "i", "I" }) do
		vim.keymap.set("n", key, function()
			M.open_selected(true)
		end, vim.tbl_extend("force", options, { desc = "Open Agent Mode chat" }))
	end
	vim.keymap.set("n", "w", cycle_worktree, vim.tbl_extend("force", options, { desc = "Cycle new chat worktree" }))
	vim.keymap.set("n", "<C-w>", M.select_worktree, vim.tbl_extend("force", options, { desc = "Select existing worktree" }))
	for _, key in ipairs({ "W", "<C-t>" }) do
		vim.keymap.set("n", key, M.new_worktree, vim.tbl_extend("force", options, { desc = "Move chat to new worktree" }))
	end
	vim.keymap.set("n", "q", M.leave, vim.tbl_extend("force", options, { desc = "Leave Agent Mode" }))
end

local function create_ui()
	state.origin_win = vim.api.nvim_get_current_win()
	state.tab = vim.api.nvim_get_current_tabpage()
	state.editor_options = { showtabline = vim.o.showtabline, laststatus = vim.o.laststatus, cmdheight = vim.o.cmdheight }
	vim.o.showtabline = 0
	vim.o.laststatus = 0
	vim.o.cmdheight = 0
	if not valid_buf(state.placeholder_buf) then
		state.placeholder_buf = vim.api.nvim_create_buf(false, true)
		pcall(vim.api.nvim_buf_set_name, state.placeholder_buf, "agent://conversation")
		set_scratch_options(state.placeholder_buf, "agentmode")
	end
	local sidebar_config, chat_config = layout_overlay()
	state.chat_win = vim.api.nvim_open_win(valid_buf(state.chat_buf) and state.chat_buf or state.placeholder_buf,
		false, chat_config)
	set_window_options(state.chat_win, false)
	vim.wo[state.chat_win].winblend = 0
	vim.wo[state.chat_win].winhighlight = "NormalFloat:Normal"

	if not valid_buf(state.sidebar_buf) then
		state.sidebar_buf = vim.api.nvim_create_buf(false, true)
		pcall(vim.api.nvim_buf_set_name, state.sidebar_buf, "agent://recents")
		set_scratch_options(state.sidebar_buf, "agentmoderecents")
	end
	state.sidebar_win = vim.api.nvim_open_win(state.sidebar_buf, true, sidebar_config)
	set_window_options(state.sidebar_win, true)
	vim.wo[state.sidebar_win].winblend = 0
	vim.wo[state.sidebar_win].winhighlight = "NormalFloat:Normal,FloatBorder:WinSeparator,WinBar:Normal,WinBarNC:Normal"
	sidebar_mappings()
	render_placeholder()
	render_sidebar()
	if state.composer and vim.api.nvim_win_get_buf(state.chat_win) == state.composer.background_buf then
		render_composer(state.composer.message)
	end
	hide_sidebar_cursor()
end

local function ensure_ui()
	if valid_tab(state.tab) and valid_win(state.sidebar_win) and valid_win(state.chat_win) then
		vim.api.nvim_set_current_tabpage(state.tab)
		return
	end
	M.leave()
	create_ui()
end

local function choose_current_worktree()
	state.new_target = 1
	if not state.project then
		return
	end
	for index, worktree in ipairs(state.project.worktrees) do
		if worktree.is_current or worktree.path == state.project.current_worktree then
			state.new_target = index
			return
		end
	end
end

local function set_project(directory, reset_target)
	local previous_target = current_target()
	local previous_target_path = previous_target and previous_target.path or nil
	local discovered = Project.discover(directory)
	local changed = project_key(discovered) ~= project_key(state.project)
	state.project = discovered
	if changed or reset_target or not previous_target_path then
		choose_current_worktree()
	else
		state.new_target = 1
		for index, worktree in ipairs(discovered.worktrees) do
			if worktree.path == previous_target_path then
				state.new_target = index
				break
			end
		end
	end
	if changed then
		state.sidebar_level, state.sidebar_worktree, state.sidebar_action = nil, nil, 1
		state.worktree_sync_error = nil
		state.docker = {}
		state.chat_buf = nil
		state.new_worktree = false
		state.new_worktree_name = nil
		local old_composer = state.composer
		if state.composer then
			if state.prompt_history then
				state.prompt_history:record_final(composer_draft_text(state.composer))
			end
			hide_composer()
			state.composer = nil
		end
		state.threads = {}
		state.active_order = {}
		state.dismissed_threads = {}
		state.dismissed_order = {}
		state.dismissed_refreshing = false
		state.dismiss_pending = {}
		state.fork_pending = {}
		state.move_pending = {}
		state.selected_ids = {}
		state.recents_tab = "active"
		state.search_term = nil
		state.search = nil
		state.order = {}
		state.selected_id = nil
		state.active_id = nil
		state.auto_open_latest = true
		if valid_win(state.chat_win) and valid_buf(state.placeholder_buf) then
			vim.api.nvim_win_set_buf(state.chat_win, state.placeholder_buf)
			render_placeholder()
		end
		if old_composer and valid_buf(old_composer.buf) then
			pcall(vim.api.nvim_buf_delete, old_composer.buf, { force = true })
		end
		if old_composer and valid_buf(old_composer.background_buf) then
			pcall(vim.api.nvim_buf_delete, old_composer.background_buf, { force = true })
		end
	end
	return changed
end

local function enter_agent_mode(open_latest)
	local from_agent_tab = valid_tab(state.tab) and vim.api.nvim_get_current_tabpage() == state.tab
	local directory = from_agent_tab and (state.project and state.project.launch_cwd or vim.fn.getcwd()) or current_entry_directory()
	set_project(directory, not from_agent_tab)
	ensure_ui()
	enable_mouse_hover()
	state.auto_open_latest = open_latest and not state.active_id
	start_notification_watcher()
	start_backend()
	start_refresh_timer()
	start_working_animation()
	refresh_threads()
end

function M.open()
	enter_agent_mode(true)
	focus_recents()
	M.preload_selected()
	vim.schedule(preload_active_threads)
end

function M.open_selected(focus)
	local thread = selected_thread()
	if not thread or state.move_pending[thread.id] then
		return
	end
	local tree = Project.worktree_for(state.project, thread.cwd)
	if tree and state.project.removing_worktree == tree.path then return end
	hide_composer()
	if thread._dismissed then
		show_dismissed_thread(thread, focus)
		render_sidebar()
		return
	end
	if focus then
		thread._unread = false
	end
	state.active_id = thread.id
	local session = state.sessions[thread.id]
	if session and session.active_elsewhere and os.time() < (session.retry_after or 0) then
		show_readonly_thread(thread, session, focus)
		thread._unread = false
		session.unread = false
		render_sidebar()
		return
	elseif session and session.active_elsewhere then
		session.active_elsewhere = false
		session.retry_after = nil
	end
	if session and terminal_running(session) and not valid_buf(session.buf) then
		if not session.restarting then
			session.restarting = true
			pcall(vim.fn.jobstop, session.job_id)
			local function reopen_after_exit()
				if terminal_running(session) then
					vim.defer_fn(reopen_after_exit, 100)
					return
				end
				session.restarting = false
				if state.active_id == thread.id and valid_tab(state.tab) then
					M.open_selected(focus)
				end
			end
			vim.defer_fn(reopen_after_exit, 100)
		end
		if valid_win(state.chat_win) and valid_buf(state.placeholder_buf) then
			vim.api.nvim_win_set_buf(state.chat_win, state.placeholder_buf)
			render_placeholder("Reconnecting to this conversation…")
		end
		return
	end
	if not session or not valid_buf(session.buf) or not terminal_running(session) then
		render_thread_loading(thread)
		session = create_terminal(thread.id, thread.cwd, thread.id, thread.id)
		thread._local_status = session.frontend_status
	end
	session.reveal_focus = not not focus
	if focus then
		session.unread = false
	end
	render_sidebar()
	if session.initial_load_complete then
		show_terminal_session(session, focus)
	else
		render_thread_loading(thread)
		if focus then
			vim.api.nvim_set_current_win(state.chat_win)
		end
	end
end

function M.focus_chat()
	if not valid_win(state.chat_win) then
		return
	end
	if state.filter then
		finish_recents_filter(true)
	end
	if state.preview_timer then
		state.preview_timer:stop()
	end
	local buf = vim.api.nvim_win_get_buf(state.chat_win)
	if state.composer and buf == state.composer.background_buf then
		show_composer()
	elseif vim.api.nvim_get_current_win() ~= state.chat_win and selected_thread() then
		M.open_selected(true)
	else
		vim.api.nvim_set_current_win(state.chat_win)
		if vim.bo[buf].buftype == "terminal" then
			vim.cmd("startinsert")
		end
	end
end

local function wait_for_composer(session, prompt, attempt)
	if session.initial_send_scheduled or not terminal_running(session) then
		return
	end
	local line_count = valid_buf(session.buf) and vim.api.nvim_buf_line_count(session.buf) or 0
	local lines = line_count > 0
		and vim.api.nvim_buf_get_lines(session.buf, 0, line_count, false)
		or {}
	local tail = table.concat(lines, "\n"):lower()
	local blocked_screen = tail:find("enter to select", 1, true)
		or tail:find("esc to dismiss", 1, true)
		or tail:find("approval required", 1, true)
		or tail:find("trust this", 1, true)
		or tail:find("press enter", 1, true)
		or tail:find("select an option", 1, true)
	local ready = false
	for _, line in ipairs(lines) do
		local stripped = vim.trim(line)
		if not blocked_screen and stripped:sub(1, #"›") == "›" then
			ready = true
			break
		end
	end
	if tail:find("enter to select", 1, true) or tail:find("approval required", 1, true) then
		ready = false
	end
	if ready and session.plan_mode then
		-- The composer can appear before its footer, and a remote CLI may take
		-- longer than one timer tick to apply BackTab. Confirm Plan mode before
		-- pasting; never toggle an already selected mode or repeat a pending toggle.
		local current = terminal_plan_mode(session)
		if current == false and not session.initial_mode_switch_sent then
			session.initial_mode_switch_sent = true
			vim.api.nvim_chan_send(session.job_id, codex_backtab)
		end
		ready = current == true
	end
	if ready then
		session.initial_send_scheduled = true
		local function send_prompt()
			if not terminal_running(session) then
				return
			end
			-- Explicit paste markers prevent a one-line prompt delivered in a single
			-- PTY write from triggering Codex's input-burst paste detection.
			local text = "\27[200~" .. prompt .. "\27[201~"
			vim.api.nvim_chan_send(session.job_id, text)
			-- Keep the submit key well outside the same PTY input burst as the text.
			-- A short gap can still be classified as a paste by Codex, leaving the
			-- prompt populated until the user presses Enter a second time.
			vim.defer_fn(function()
				if not terminal_running(session) then
					return
				end
				vim.api.nvim_chan_send(session.job_id, "\r")
			end, 250)
		end
		send_prompt()
		return
	end
	if attempt == 50 then
		notify("Waiting for Codex to finish startup before sending the first message", vim.log.levels.INFO)
	elseif attempt >= 600 then
		notify("Codex did not reach its chat prompt in the requested mode; the first message was not sent", vim.log.levels.ERROR)
		return
	end
	vim.defer_fn(function()
		wait_for_composer(session, prompt, attempt + 1)
	end, 100)
end

local function launch_new_chat(cwd, prompt, focus, plan_mode)
	local tree = Project.worktree_for(state.project, cwd)
	if tree and state.project.removing_worktree == tree.path then
		notify("This worktree is being removed", vim.log.levels.WARN)
		return
	end
	if focus == nil then
		focus = true
	end
	local composer = state.composer
	composer.message = "Starting conversation…"
	render_composer(composer.message)

	-- An app-server thread/start result is not yet a saved interactive session,
	-- so passing its ID to `codex resume` fails. Let the CLI create and persist
	-- the session, then replace this temporary row once its metadata is available.
	state.pending_sequence = state.pending_sequence + 1
	local pending_id = "pending-" .. state.pending_sequence
	local thread = {
		id = pending_id,
		cwd = cwd,
		createdAt = os.time(),
		updatedAt = os.time(),
		preview = prompt,
	}
	local return_tab = not focus and vim.api.nvim_get_current_tabpage() or nil
	local return_win = not focus and vim.api.nvim_get_current_win() or nil
	state.selected_ids[state.recents_tab] = state.selected_id
	state.recents_tab = "active"
	state.selected_id = state.selected_ids.active
	sort_threads()
	hide_composer()
	state.composer = nil
	state.active_id = pending_id
	local session = create_terminal(nil, cwd, pending_id, nil, true)
	session.plan_mode = plan_mode == true
	if not focus then
		if valid_tab(return_tab) then
			vim.api.nvim_set_current_tabpage(return_tab)
		end
		if valid_win(return_win) then
			vim.api.nvim_set_current_win(return_win)
		end
	end
	session.initial_prompt = prompt
	session.reveal_focus = focus
	thread._local_status = session.frontend_status
	thread._activity_at = next_activity_time()
	state.threads[pending_id] = thread
	session.activity_at = thread._activity_at
	state.selected_id = pending_id
	sort_threads()
	if focus and valid_win(state.chat_win) then
		vim.api.nvim_set_current_win(state.chat_win)
	end
	if session.initial_load_complete then
		show_terminal_session(session, focus)
	else
		-- New chats have no history to restore, so reveal the terminal while its
		-- first prompt is being queued instead of showing a loading placeholder.
		finish_initial_load(session)
	end
	if valid_buf(composer.buf) then
		pcall(vim.api.nvim_buf_delete, composer.buf, { force = true })
	end
	if valid_buf(composer.background_buf) then
		pcall(vim.api.nvim_buf_delete, composer.background_buf, { force = true })
	end
	wait_for_composer(session, prompt, 0)
	render_sidebar()
	vim.defer_fn(refresh_threads, 250)
end

local function submit_composer()
	local composer = state.composer
	if not composer or composer.busy or (state.project and state.project.creating_worktree) or not valid_buf(composer.buf) then
		return
	end
	local prompt = vim.trim(composer_text(composer))
	if prompt == "" then
		notify("Type a message first", vim.log.levels.WARN)
		return
	end
	composer.text = prompt
	if state.prompt_history then
		state.prompt_history:record_final(prompt)
	end
	local target = current_target()
	local cwd = target and target.path or state.project.launch_cwd
	if state.project.removing_worktree == cwd then
		notify("This worktree is being removed", vim.log.levels.WARN)
		return
	end
	composer.busy = true
	vim.bo[composer.buf].modifiable = false

	if state.new_worktree and state.project.common_dir then
		local starting_scope = project_key(state.project)
		composer.message = "Creating worktree…"
		render_composer(composer.message)
		Project.create_worktree(state.project, cwd, function(err, path)
			if err then
				composer.busy = false
				composer.message = nil
				if valid_buf(composer.buf) then
					vim.bo[composer.buf].modifiable = true
				end
				update_composer_frame()
				notify(err, vim.log.levels.ERROR)
				return
			end
			if state.composer ~= composer or project_key(state.project) ~= starting_scope then
				notify("Worktree created at " .. path .. "; chat was not opened because Agent Mode changed projects", vim.log.levels.WARN)
				return
			end
			local focus_chat = not not (valid_tab(state.tab)
				and vim.api.nvim_get_current_tabpage() == state.tab
				and valid_win(composer.win)
				and vim.api.nvim_get_current_win() == composer.win)
			state.project = Project.discover(path)
			choose_current_worktree()
			state.new_worktree = false
			state.new_worktree_name = nil
			launch_new_chat(path, prompt, focus_chat, composer.plan_mode)
		end, state.new_worktree_name)
	else
		launch_new_chat(cwd, prompt, nil, composer.plan_mode)
	end
end

local function replace_composer_text(composer, text)
	if not composer or not valid_buf(composer.buf) then
		return
	end
	composer.replacing_text = true
	vim.api.nvim_buf_set_lines(composer.buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
	composer.replacing_text = false
	composer.text = text
	render_composer(composer.message)
	if valid_win(composer.win) then
		local row = math.max(1, vim.api.nvim_buf_line_count(composer.buf))
		local line = vim.api.nvim_buf_get_lines(composer.buf, row - 1, row, false)[1] or ""
		vim.api.nvim_win_set_cursor(composer.win, { row, #line })
	end
end

local function recall_composer(delta)
	local composer = state.composer
	if not composer or composer.busy or not state.prompt_history or not valid_buf(composer.buf) then
		return
	end
	local current = composer_text(composer)
	local entries = state.prompt_history:items()
	if composer.history_index == nil then
		state.prompt_history:record(current)
		entries = state.prompt_history:items()
		composer.history_draft = current
		composer.history_ceiling = #entries
		if current:find("%S") and entries[#entries] == current then
			composer.history_ceiling = composer.history_ceiling - 1
		end
		if delta > 0 then
			return
		end
		composer.history_index = composer.history_ceiling + 1
	end

	local next_index = composer.history_index + delta
	if next_index < 1 then
		next_index = 1
	end
	if next_index > composer.history_ceiling then
		composer.history_index = nil
		composer.history_ceiling = nil
		local draft = composer.history_draft or ""
		composer.history_draft = nil
		replace_composer_text(composer, draft)
		return
	end
	if entries[next_index] then
		composer.history_index = next_index
		replace_composer_text(composer, entries[next_index])
	end
end

local function mention_composer_file()
	local composer = state.composer
	if not composer or composer.busy or not valid_win(composer.win)
		or vim.api.nvim_get_current_buf() ~= composer.buf
	then
		return
	end
	local buf, win = composer.buf, composer.win
	local cursor = vim.api.nvim_win_get_cursor(win)
	local row, col = cursor[1] - 1, cursor[2]
	local line = vim.api.nvim_get_current_line()
	vim.api.nvim_buf_set_text(buf, row, col, row, col, { "@" })
	vim.api.nvim_win_set_cursor(win, { row + 1, col + 1 })
	-- Keep email addresses and other embedded @ characters as ordinary text.
	if col > 0 and not line:sub(col, col):match("[%s%(%[%{]") then
		return
	end

	local target = current_target()
	local cwd = target and target.path or state.project.launch_cwd
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local function restore_prompt(column)
		vim.schedule(function()
			if state.composer ~= composer or not valid_buf(buf) or not valid_win(win)
				or vim.api.nvim_win_get_buf(win) ~= buf
			then
				return
			end
			vim.api.nvim_set_current_win(win)
			vim.api.nvim_win_set_cursor(win, { row + 1, column })
			local current_line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
			vim.cmd(column >= #current_line and "startinsert!" or "startinsert")
		end)
	end
	require("telescope.builtin").find_files(require("telescope.themes").get_dropdown({
		cwd = cwd,
		prompt_title = "Mention file",
		previewer = false,
		-- Include dotfiles and respect ignore files without the global Telescope
		-- patterns that also hide otherwise useful source paths such as build.nix.
		find_command = { "rg", "--files", "--hidden", "--glob", "!.git" },
		file_ignore_patterns = {},
		attach_mappings = function(prompt_buf, map)
			actions.select_default:replace(function()
				local entry = action_state.get_selected_entry()
				if not entry then
					return
				end
				actions.close(prompt_buf)
				if state.composer ~= composer or not valid_buf(buf) or composer.busy then
					return
				end
				local path = entry.value:gsub("^%./", "")
				if path:find('[%s"\\]') then
					path = vim.json.encode(path)
				end
				local text = "@" .. path .. " "
				vim.api.nvim_buf_set_text(buf, row, col, row, col + 1, { text })
				restore_prompt(col + #text)
			end)
			local function cancel()
				actions.close(prompt_buf)
				restore_prompt(col + 1)
			end
			for _, mode in ipairs({ "i", "n" }) do
				map(mode, "<Up>", actions.move_selection_previous)
				map(mode, "<Down>", actions.move_selection_next)
				map(mode, "<Esc>", cancel)
				map(mode, "<C-c>", cancel)
			end
			return true
		end,
	}))
end

local function composer_mappings(buf)
	local options = { buffer = buf, silent = true }
	vim.keymap.set("i", "@", mention_composer_file, vim.tbl_extend("force", options, { desc = "Mention a project file" }))
	vim.keymap.set("i", "<CR>", submit_composer, vim.tbl_extend("force", options, { desc = "Start Agent Mode chat" }))
	vim.keymap.set("n", "<CR>", submit_composer, options)
	vim.keymap.set({ "n", "i" }, "<C-c>", function()
		local composer = state.composer
		if not composer or composer.buf ~= buf or composer.busy then
			return
		end
		if state.prompt_history then
			state.prompt_history:record_final(composer_draft_text(composer))
		end
		composer.history_index = nil
		composer.history_ceiling = nil
		composer.history_draft = nil
		replace_composer_text(composer, "")
	end, vim.tbl_extend("force", options, { desc = "Clear Agent Mode prompt" }))
	vim.keymap.set({ "n", "i" }, "<Up>", function()
		recall_composer(-1)
	end, vim.tbl_extend("force", options, { desc = "Older Agent Mode prompt" }))
	vim.keymap.set({ "n", "i" }, "<Down>", function()
		recall_composer(1)
	end, vim.tbl_extend("force", options, { desc = "Newer Agent Mode prompt" }))
	local function insert_newline()
		local cursor = vim.api.nvim_win_get_cursor(0)
		local line = vim.api.nvim_get_current_line()
		local before = line:sub(1, cursor[2])
		local after = line:sub(cursor[2] + 1)
		vim.api.nvim_set_current_line(before)
		vim.api.nvim_buf_set_lines(buf, cursor[1], cursor[1], false, { after })
		vim.api.nvim_win_set_cursor(0, { cursor[1] + 1, 0 })
	end
	for _, key in ipairs({ "<S-CR>", "<M-CR>" }) do
		vim.keymap.set("i", key, insert_newline, vim.tbl_extend("force", options, {
			desc = "Insert newline in Agent Mode prompt",
		}))
	end
	vim.keymap.set({ "n", "i" }, "<S-Tab>", function()
		local composer = state.composer
		if not composer or composer.buf ~= buf or composer.busy then
			return
		end
		composer.plan_mode = not composer.plan_mode
		update_composer_frame()
	end, vim.tbl_extend("force", options, { desc = "Toggle Plan mode for Agent Mode chat" }))
	vim.keymap.set("i", "<Esc>", function()
		vim.cmd("stopinsert")
		vim.schedule(focus_recents)
	end, vim.tbl_extend("force", options, { desc = "Focus Agent Mode recents" }))
	vim.keymap.set("n", "<Esc>", focus_recents, vim.tbl_extend("force", options, {
		desc = "Focus Agent Mode recents",
	}))
	for _, key in ipairs({ "i", "I", "a", "A" }) do
		vim.keymap.set("n", key, function()
			vim.cmd("startinsert")
		end, options)
	end
	vim.keymap.set({ "n", "i" }, "<C-w>", M.select_worktree, vim.tbl_extend("force", options, {
		desc = "Select existing worktree for Agent Mode chat",
	}))
	vim.keymap.set({ "n", "i" }, "<C-t>", M.new_worktree, vim.tbl_extend("force", options, {
		desc = "Name new worktree for Agent Mode chat",
	}))
end

open_new_chat = function()
	state.active_id = nil
	state.auto_open_latest = false
	if state.preview_timer then
		state.preview_timer:stop()
	end
	if not valid_win(state.chat_win) then
		return
	end
	if state.composer and valid_buf(state.composer.buf) then
		show_composer()
		return
	end

	local background_buf = vim.api.nvim_create_buf(false, true)
	pcall(vim.api.nvim_buf_set_name, background_buf, "agent://new")
	set_scratch_options(background_buf, "agentmode")
	local buf = vim.api.nvim_create_buf(false, true)
	pcall(vim.api.nvim_buf_set_name, buf, "agent://prompt")
	set_scratch_options(buf, "agentprompt")
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
	-- Collaboration mode is deliberately per chat. Every new composer starts in
	-- Codex's Default mode and only opts into Plan mode via Shift-Tab.
	state.composer = { buf = buf, background_buf = background_buf, busy = false, text = "", plan_mode = false }
	if state.prompt_history then
		state.prompt_history:begin()
	end
	composer_mappings(buf)
	-- Buffer callbacks see every edit, including completion, paste and edits
	-- immediately followed by a mapping. TextChangedI can coalesce those edits
	-- or run after Up has already replaced the draft.
	vim.api.nvim_buf_attach(buf, false, {
		on_lines = function()
			local composer = state.composer
			if not composer or composer.buf ~= buf then
				return true
			end
			if composer.replacing_text then
				return
			end
			local text = composer_text(composer)
			local was_recalling = composer.history_index ~= nil
			composer.history_index = nil
			composer.history_ceiling = nil
			composer.history_draft = nil
			composer.text = text
			if state.prompt_history then
				if was_recalling then
					state.prompt_history:begin()
				end
				state.prompt_history:record(text)
			end
			-- Rendering changes buffers/windows and must happen outside textlock.
			if not composer.render_pending then
				composer.render_pending = true
				vim.schedule(function()
					composer.render_pending = false
					if state.composer == composer and valid_win(composer.win) then
						render_composer(composer.message)
					end
				end)
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "BufLeave", "BufWipeout" }, {
		buffer = buf,
		callback = function()
			if state.composer and state.composer.buf == buf and state.prompt_history then
				local composer = state.composer
				-- History traversal is only a preview. Persist the draft it is
				-- protecting instead of changing history order to the previewed item.
				state.prompt_history:record_final(composer_draft_text(composer))
				state.prompt_history:flush()
			end
		end,
	})
	show_composer()
end

function M.new_chat()
	local worktree_path = M.selected_worktree()
	enter_agent_mode(false)
	if worktree_path and not state.project.creating_worktree and not (state.composer and state.composer.busy) then
		for index, worktree in ipairs(state.project.worktrees) do
			if worktree.path == worktree_path then
				state.new_target = index
				state.new_worktree, state.new_worktree_name = false, nil
				break
			end
		end
	end
	open_new_chat()
end

function M.leave(restore_focus)
	if not state.tab then
		return
	end
	state.tab = nil
	vim.cmd("stopinsert")
	if state.preview_timer then
		state.preview_timer:stop()
	end
	restore_sidebar_cursor()
	restore_mouse_hover()
	if valid_win(state.chat_win) then
		state.chat_buf = vim.api.nvim_win_get_buf(state.chat_win)
	end
	hide_composer()
	if state.filter then
		finish_recents_filter(true, true)
	end
	for _, win in pairs({ state.sidebar_win, state.chat_win }) do
		if valid_win(win) then
			vim.api.nvim_win_close(win, true)
		end
	end
	state.sidebar_win, state.chat_win = nil, nil
	if state.editor_options then
		-- Restore cmdheight before resizing the bars so Neovim also saves the
		-- restored height in this tab page during TabLeave.
		vim.o.cmdheight = state.editor_options.cmdheight
		vim.o.showtabline = state.editor_options.showtabline
		vim.o.laststatus = state.editor_options.laststatus
		state.editor_options = nil
	end
	if restore_focus ~= false and valid_win(state.origin_win) then
		vim.api.nvim_set_current_win(state.origin_win)
	end
	state.origin_win = nil
end

local function resize_ui()
	if not valid_tab(state.tab) then
		return
	end
	layout_overlay()
	if state.composer and valid_buf(state.composer.buf) and valid_buf(state.composer.background_buf)
		and valid_win(state.chat_win)
		and vim.api.nvim_win_get_buf(state.chat_win) == state.composer.background_buf
	then
		render_composer(state.composer.message)
	end
	local active_session = state.active_id and state.sessions[state.active_id] or nil
	local dismissed = state.recents_tab == "dismissed" and selected_thread() or nil
	if dismissed then
		show_dismissed_thread(dismissed, false)
	elseif active_session and not active_session.initial_load_complete then
		render_thread_loading(state.threads[state.active_id])
	else
		render_placeholder()
	end
	render_sidebar()
end

local function shutdown()
	state.shutting_down = true
	restore_sidebar_cursor()
	if state.composer and state.prompt_history then
		state.prompt_history:record_final(composer_draft_text(state.composer))
	end
	if state.prompt_history then
		state.prompt_history:close()
	end
	restore_mouse_hover()
	stop_timer(state.refresh_timer)
	stop_timer(state.preview_timer)
	stop_timer(state.working_animation_timer)
	stop_timer(state.notify_timer)
	state.refresh_timer = nil
	state.preview_timer = nil
	state.working_animation_timer = nil
	state.notify_timer = nil
	if state.backend then
		state.backend:stop()
	end
	if state.notify_path then
		pcall(vim.fn.delete, state.notify_path)
		pcall(vim.fn.delete, state.notify_path .. ".lock")
	end
end

function M.setup(options)
	if state.setup then
		return
	end
	state.setup = true
	state.opts = vim.tbl_deep_extend("force", vim.deepcopy(defaults), options or {})
	state.prompt_history = History.new({
		limit = state.opts.history_limit,
		write_delay = state.opts.history_write_delay,
		path = state.opts.history_path,
		on_error = function(message)
			notify(message, vim.log.levels.WARN)
		end,
	})

	vim.api.nvim_set_hl(0, "AgentModeTitle", { bold = true, default = true })
	setup_tab_highlights()
	Sidebar.setup_highlights()
	setup_working_highlights()

	vim.api.nvim_create_user_command("AgentMode", M.open, { desc = "Open Agent Mode recents" })
	vim.api.nvim_create_user_command("AgentModeNew", M.new_chat, { desc = "Open a new Agent Mode chat" })
	vim.api.nvim_create_user_command("AgentModeResync", M.resync, { desc = "Resync Agent Mode recents" })
	vim.api.nvim_create_user_command("AgentModeToggleWorktree", M.toggle_worktree, {
		desc = "Toggle fresh worktree for new Agent Mode chats",
	})

	local modes = { "n", "i", "v", "t", "c", "s", "o" }
	local function global_action(callback)
		return function()
			local mode = vim.api.nvim_get_mode().mode
			if mode:sub(1, 1) == "t" then
				local normal = vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true)
				vim.api.nvim_feedkeys(normal, "n", false)
			elseif mode:sub(1, 1) == "i" then
				vim.cmd("stopinsert")
			elseif mode:sub(1, 1) == "c" then
				local cancel = vim.api.nvim_replace_termcodes("<C-c>", true, false, true)
				vim.api.nvim_feedkeys(cancel, "n", false)
			end
			vim.schedule(callback)
		end
	end
	if state.opts.keys.new_chat then
		vim.keymap.set("n", state.opts.keys.new_chat, global_action(M.new_chat), {
			silent = true,
			desc = "Agent Mode: new chat",
		})
	end
	if state.opts.keys.recents then
		vim.keymap.set(modes, state.opts.keys.recents, global_action(M.open), {
			silent = true,
			desc = "Agent Mode: recents",
		})
	end

	local group = vim.api.nvim_create_augroup("AgentMode", { clear = true })
	vim.keymap.set({ "n", "i", "x", "t" }, "<LeftMouse>", handle_input_click, {
		expr = true,
		silent = true,
		desc = "Agent Mode: click to enter input mode",
	})
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = group,
		callback = function()
			setup_tab_highlights()
			Sidebar.setup_highlights()
			setup_working_highlights()
		end,
	})
	vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter", "ColorScheme" }, {
		group = group,
		callback = hide_sidebar_cursor,
	})
	vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
		group = group,
		callback = restore_sidebar_cursor,
	})
	local function preload_recents()
		if state.shutting_down then
			return
		end
		set_project(current_entry_directory(), false)
		-- Startup only warms metadata; a conversation needs the Agent Mode
		-- windows before it can be resumed into a terminal buffer.
		state.auto_open_latest = false
		start_backend()
		refresh_threads()
	end
	if vim.v.vim_did_enter == 1 then
		vim.schedule(preload_recents)
	else
		vim.api.nvim_create_autocmd("VimEnter", {
			group = group,
			once = true,
			callback = vim.schedule_wrap(preload_recents),
		})
	end
	vim.api.nvim_create_autocmd("VimResized", {
		group = group,
		callback = vim.schedule_wrap(resize_ui),
	})
	vim.api.nvim_create_autocmd("TabLeave", {
		group = group,
		callback = function() M.leave(false) end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = group,
		callback = function(event)
			local win = tonumber(event.match)
			if state.tab and (win == state.sidebar_win or win == state.chat_win) then
				vim.schedule(function()
					if state.tab and (not valid_win(state.sidebar_win) or not valid_win(state.chat_win)) then
						M.leave()
					end
				end)
			end
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = shutdown,
	})
end

return M
