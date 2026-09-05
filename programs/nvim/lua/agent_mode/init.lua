local Backend = require("config.agent_mode.backend")
local History = require("config.agent_mode.history")
local Identity = require("config.agent_mode.identity")
local Project = require("config.agent_mode.project")

local M = {}

local defaults = {
	command = "codexvenv",
	keys = {
		new_chat = "<C-c>",
		recents = "<F10>",
	},
	history_limit = 100,
	history_write_delay = 100,
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
	threads = {},
	active_order = {},
	dismissed_threads = {},
	dismissed_order = {},
	dismissed_refreshing = false,
	dismiss_pending = {},
	recents_tab = "active",
	search_term = nil,
	search = nil,
	filter = nil,
	selected_ids = {},
	order = {},
	selected_id = nil,
	active_id = nil,
	sessions = {},
	session_tokens = {},
	session_sequence = 0,
	preload_scheduled = false,
	pending_sequence = 0,
	activity_clock = 0,
	new_worktree = false,
	new_target = 1,
	tab = nil,
	origin_tab = nil,
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

local function map_sidebar_hover(buf)
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
	map_sidebar_hover(buf)
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
	if sidebar then
		vim.wo[win].statusline = "  [/] filter  [[]/[]] tab  [Tab] toggle  [j/k] move  [Enter/i] open  [d] toggle  [D] dismiss all  [q] back"
	else
		vim.wo[win].statusline = "  [Esc] recents  [Alt-Esc] send Escape to Codex  [Ctrl-C] new  [F10] recents"
	end
end

local function wanted_sidebar_width()
	local available = math.max(18, vim.o.columns - 30)
	return math.min(state.opts.sidebar_width, available)
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

local function preview_lines(text, width)
	if vim.fn.strdisplaywidth(text) <= width then
		return { text, "" }
	end
	local first, split = "", 0
	for index = 0, vim.fn.strchars(text) - 1 do
		local character = vim.fn.strcharpart(text, index, 1)
		if vim.fn.strdisplaywidth(first .. character) > width then
			break
		end
		first = first .. character
		split = #first
	end
	local word_break = first:match("^.*()%s")
	if word_break and text:sub(split + 1, split + 1) ~= " " then
		split = word_break
	end
	return { vim.trim(text:sub(1, split)), truncate(vim.trim(text:sub(split + 1)), width) }
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
	return state.selected_id and displayed_threads()[state.selected_id] or nil
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
		return "new worktree from " .. label
	end
	return label
end

local function render_sidebar()
	if not valid_buf(state.sidebar_buf) then
		return
	end

	local width = valid_win(state.sidebar_win) and vim.api.nvim_win_get_width(state.sidebar_win) or state.opts.sidebar_width
	if valid_win(state.sidebar_win) then
		vim.wo[state.sidebar_win].statusline = state.recents_tab == "active"
			and "  [/] filter  []] dismissed  [Tab] toggle  [j/k] move  [Enter/i] open  [d] dismiss  [D] dismiss all  [q] back"
			or "  [/] filter  [[] active  [Tab] toggle  [j/k] move  [Enter] restore/open  [i] preview  [d] restore  [q] back"
		if state.search_term and not state.filter then
			vim.wo[state.sidebar_win].statusline = "  [Esc] clear filter" .. vim.wo[state.sidebar_win].statusline
		end
	end
	local active_tab = string.format(" Active %d ", #state.active_order)
	local dismissed_tab = " Dismissed "
	local tab_separator = " │ "
	local tab_line = "  " .. active_tab .. tab_separator .. dismissed_tab
	local tab_ranges = {
		active = { 2, 2 + #active_tab },
		dismissed = { 2 + #active_tab + #tab_separator, #tab_line },
	}
	local lines = { "", tab_line, "" }
	if state.search_term and not state.filter then
		table.insert(lines, truncate("  Filter: " .. state.search_term, width - 1))
		table.insert(lines, "")
	end
	local decorations = {}
	working_labels = {}
	local now = os.time()
	local cursor_rows = {}
	local row_threads = {}

	if #state.order == 0 then
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
		for _, thread in ipairs(state.order) do
			local status = status_name(thread)
			local updated = thread_time(thread)
			local date = relative_date(updated, now)
			local unread = thread._unread and "● " or "  "
			local worktree = state.project and Project.worktree_for(state.project, thread.cwd or "") or nil
			local first_row = #lines + 1

			local preview = preview_lines(thread_title(thread), math.max(1, width - 4))
			table.insert(lines, unread .. preview[1])
			if preview[2] ~= "" then
				table.insert(lines, "  " .. preview[2])
			end
			local title_last = #lines
			local label = status:sub(1, 1):upper() .. status:sub(2)
			local icon = status_icons[status]
			local status_text = (icon and icon .. " " or "") .. label
			local metadata = (status == "saved" or status == "loading") and date or status_text .. " · " .. date
			table.insert(lines, truncate("  " .. metadata, width - 2))
			local metadata_row = #lines
			if status == "working" and width >= 11 then
				table.insert(working_labels, { row = metadata_row - 1, col = 2 })
			end
			if worktree and state.project.common_dir
				and (not worktree.branch or worktree.branch ~= state.project.default_branch)
			then
				local label = worktree.label or vim.fs.basename(worktree.path)
				table.insert(lines, truncate("  ↳ " .. label, width - 2))
			end
			local last_row = #lines
			table.insert(lines, "")

			cursor_rows[thread.id] = first_row
			for row = first_row, last_row do
				row_threads[row] = thread.id
			end
			table.insert(decorations, {
				first = first_row,
				last = last_row,
				title_last = title_last,
				metadata_row = metadata_row,
				status_end = math.min(#lines[metadata_row], 2 + #status_text),
				status = status,
				selected = thread.id == state.selected_id
					and not (state.composer and valid_win(state.composer.win)),
			})
		end
	end

	table.insert(lines, "")
	table.insert(lines, truncate("  New chat: " .. target_summary(), width - 1))
	table.insert(lines, string.format("  [W] fresh worktree: %s", state.new_worktree and "ON" or "off"))
	table.insert(lines, "  [w] cycle existing worktree")
	state.cursor_rows = cursor_rows
	state.row_threads = row_threads

	vim.bo[state.sidebar_buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.sidebar_buf, 0, -1, false, lines)
	vim.bo[state.sidebar_buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(state.sidebar_buf, namespace, 0, -1)
	for tab, range in pairs(tab_ranges) do
		local highlight = tab == state.recents_tab and "AgentModeTabSelected" or "AgentModeTabInactive"
		vim.api.nvim_buf_add_highlight(state.sidebar_buf, namespace, highlight, 1, range[1], range[2])
	end
	vim.api.nvim_buf_add_highlight(
		state.sidebar_buf,
		namespace,
		"WinSeparator",
		1,
		tab_ranges.active[2],
		tab_ranges.dismissed[1]
	)

	for _, decoration in ipairs(decorations) do
		for row = decoration.first, decoration.last do
			vim.api.nvim_buf_add_highlight(state.sidebar_buf, namespace,
				row <= decoration.title_last and "AgentModeTitle" or "Comment", row - 1, 0, -1)
			if decoration.selected then
				-- A line highlight also fills the cells past EOL, keeping every
				-- line of the hovered conversation the same rectangular width.
				vim.api.nvim_buf_set_extmark(state.sidebar_buf, namespace, row - 1, 0, {
					line_hl_group = "AgentModeSelected", priority = 90,
				})
			end
		end
		if decoration.status ~= "saved" and decoration.status ~= "loading" then
			vim.api.nvim_buf_add_highlight(state.sidebar_buf, namespace,
				status_highlights[decoration.status] or "Comment",
				decoration.metadata_row - 1, 2, decoration.status_end)
		end
	end

	render_working_animation()
	if valid_win(state.sidebar_win) and state.selected_id and cursor_rows[state.selected_id] then
		pcall(vim.api.nvim_win_set_cursor, state.sidebar_win, { cursor_rows[state.selected_id], 1 })
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
	local content_height = #agent_mode_banner + input_height + (composer.plan_mode and 8 or 7) + (message and 1 or 0)
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
	table.insert(lines, centered_text("Worktree: " .. target_summary() .. "  ·  Ctrl-T fresh worktree", width))
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
	local row = state.selected_id and state.cursor_rows and state.cursor_rows[state.selected_id]
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

local function attach_terminal_activity(session)
	local function check_initial_load()
		if not state.shutting_down and state.session_tokens[session.notify_token] == session
			and not session.initial_load_complete and terminal_ui_status(session)
		then
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
	map_sidebar_hover(session.buf)

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

	-- Codex uses plain Up/Down for shell-style prompt history. Keep Ctrl-Up/Down
	-- as Agent Mode's public bindings while translating them for the nested TUI.
	vim.keymap.set("t", "<C-Up>", function()
		if terminal_running(session) then
			vim.api.nvim_chan_send(session.job_id, "\27[A")
		end
	end, { buffer = session.buf, silent = true, desc = "Older Codex prompt" })
	vim.keymap.set("t", "<C-Down>", function()
		if terminal_running(session) then
			vim.api.nvim_chan_send(session.job_id, "\27[B")
		end
	end, { buffer = session.buf, silent = true, desc = "Newer Codex prompt" })

	vim.keymap.set("t", "<S-Tab>", function()
		if terminal_running(session) then
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
	if state.sessions[thread.id] and state.sessions[thread.id] ~= session then
		return
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

local function associate_pending_sessions(threads)
	local matches, unresolved = Identity.matches(state.sessions, threads)
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
	state.backend:start(function(err)
		if state.shutting_down then
			return
		end
		if err then
			state.backend_ready = false
			return
		end
		state.backend_ready = true
		state.last_backend_error = nil
		refresh_threads()
	end)
end

refresh_threads = function()
	if state.shutting_down or state.refreshing or not state.project then
		return
	end
	if not state.backend_ready then
		start_backend()
		return
	end

	state.refreshing = true
	local scope = project_key(state.project)
	local request_uses_state_db = state.history_repaired
	local request_params = request_uses_state_db and { archived = false, useStateDbOnly = true } or { archived = false }
	state.backend:list_threads(request_params, function(err, threads)
		state.refreshing = false
		if state.shutting_down then
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
					local status = normalize(thread.status)
					if type(status) == "table" and status.type ~= "notLoaded" then
						session.default_status = "ready"
					end
					if session.unread ~= nil and not external_activity then
						thread._unread = session.unread
					end
					if session.activity_at then
						thread._activity_at = session.activity_at
					end
					if session.active_elsewhere then
						thread._local_status = "active"
					elseif terminal_running(session) then
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
				end
			end
		end
		state.threads = next_threads
		sort_threads()
		render_sidebar()

		if state.auto_open_latest and state.recents_tab == "active" and state.active_order[1] then
			state.auto_open_latest = false
			vim.schedule(function()
				M.open_selected(false)
				focus_recents()
			end)
		end
		vim.schedule(preload_active_threads)
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
	render_sidebar()
	local scope = project_key(state.project)
	local request_params = { archived = true }
	if state.history_repaired then
		request_params.useStateDbOnly = true
	end
	state.backend:list_threads(request_params, function(err, threads)
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

local function start_refresh_timer()
	if state.refresh_timer then
		return
	end
	state.refresh_timer = vim.uv.new_timer()
	state.refresh_timer:start(state.opts.refresh_interval, state.opts.refresh_interval, vim.schedule_wrap(function()
		if valid_tab(state.tab) or next(state.sessions) ~= nil then
			refresh_threads()
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
	if #state.order == 0 then
		return
	end
	local index = selected_index() or 1
	index = math.max(1, math.min(#state.order, index + delta))
	local selected_id = state.order[index].id
	if state.selected_id == selected_id then
		return
	end
	state.selected_id = selected_id
	render_sidebar()
	M.preload_selected()
end

function M.preload_selected()
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
			or not valid_win(state.sidebar_win)
			or not valid_win(state.chat_win)
		then
			return
		end
		M.open_selected(false)
	end))
end

select_sidebar_row = function(row)
	local selected_id = state.row_threads and state.row_threads[row] or nil
	if not selected_id then
		return
	end
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
		if cleared_unread then
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
			-- Tab changes start at the header, even after scrolling the other list.
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

local function dismiss_thread(thread, skip_preview)
	if not thread or state.dismiss_pending[thread.id] then
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

local function dismiss_all()
	if state.recents_tab ~= "active" then
		return
	end
	local threads = vim.list_slice(state.active_order)
	for _, thread in ipairs(threads) do
		if status_name(thread) ~= "working" then
			dismiss_thread(thread, true)
		end
	end
	open_new_chat()
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

local function finish_recents_filter(apply)
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
	end
	set_recents_filter(input)
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
	-- A regular split keeps the input in the sidebar layout as the list updates.
	filter.win = vim.api.nvim_open_win(filter.buf, true, {
		split = "above", win = state.sidebar_win, height = 1,
	})
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
	if not state.project or #state.project.worktrees == 0 then
		return
	end
	state.new_target = (state.new_target % #state.project.worktrees) + 1
	state.new_worktree = false
	update_composer_frame()
end

function M.toggle_worktree()
	if not state.new_worktree and (not state.project or not state.project.common_dir) then
		notify("A fresh worktree requires a Git repository", vim.log.levels.WARN)
		return
	end
	state.new_worktree = not state.new_worktree
	update_composer_frame()
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
		end
	end, vim.tbl_extend("force", options, { desc = "Clear Agent Mode recents filter" }))
	vim.keymap.set("n", "<Tab>", toggle_recents_tab, vim.tbl_extend("force", options, {
		desc = "Switch Agent Mode recents tab",
	}))
	vim.keymap.set("n", "[", function()
		cycle_recents_tab(-1)
	end, vim.tbl_extend("force", options, { desc = "Show previous Agent Mode recents tab" }))
	vim.keymap.set("n", "]", function()
		cycle_recents_tab(1)
	end, vim.tbl_extend("force", options, { desc = "Show next Agent Mode recents tab" }))
	vim.keymap.set("n", "d", toggle_dismissed, vim.tbl_extend("force", options, {
		desc = "Dismiss or restore Agent Mode recent",
	}))
	vim.keymap.set("n", "D", dismiss_all, vim.tbl_extend("force", options, {
		desc = "Dismiss all active Agent Mode recents",
	}))
	vim.keymap.set("n", "gg", function()
		if state.order[1] then
			state.selected_id = state.order[1].id
			render_sidebar()
			M.preload_selected()
		end
	end, options)
	vim.keymap.set("n", "G", function()
		if state.order[#state.order] then
			state.selected_id = state.order[#state.order].id
			render_sidebar()
			M.preload_selected()
		end
	end, options)
	vim.keymap.set("n", "<CR>", function()
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
	vim.keymap.set("n", "W", M.toggle_worktree, vim.tbl_extend("force", options, { desc = "Toggle fresh worktree" }))
	vim.keymap.set("n", "q", M.leave, vim.tbl_extend("force", options, { desc = "Leave Agent Mode" }))
end

local function create_ui()
	state.origin_tab = vim.api.nvim_get_current_tabpage()
	vim.cmd("tabnew")
	state.tab = vim.api.nvim_get_current_tabpage()
	state.chat_win = vim.api.nvim_get_current_win()
	state.placeholder_buf = vim.api.nvim_create_buf(false, true)
	pcall(vim.api.nvim_buf_set_name, state.placeholder_buf, "agent://conversation")
	set_scratch_options(state.placeholder_buf, "agentmode")
	vim.api.nvim_win_set_buf(state.chat_win, state.placeholder_buf)
	set_window_options(state.chat_win, false)

	vim.cmd("topleft vsplit")
	state.sidebar_win = vim.api.nvim_get_current_win()
	state.sidebar_buf = vim.api.nvim_create_buf(false, true)
	pcall(vim.api.nvim_buf_set_name, state.sidebar_buf, "agent://recents")
	set_scratch_options(state.sidebar_buf, "agentmoderecents")
	vim.api.nvim_win_set_buf(state.sidebar_win, state.sidebar_buf)
	set_window_options(state.sidebar_win, true)
	vim.api.nvim_win_set_width(state.sidebar_win, wanted_sidebar_width())
	sidebar_mappings()
	render_placeholder()
	render_sidebar()
	hide_sidebar_cursor()
end

local function ensure_ui()
	if valid_tab(state.tab) and valid_win(state.sidebar_win) and valid_win(state.chat_win) then
		vim.api.nvim_set_current_tabpage(state.tab)
		return
	end
	state.tab = nil
	state.sidebar_win = nil
	state.chat_win = nil
	state.sidebar_buf = nil
	state.placeholder_buf = nil
	state.row_threads = nil
	state.composer = nil
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
		state.new_worktree = false
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
	if not from_agent_tab then
		state.origin_tab = vim.api.nvim_get_current_tabpage()
	end
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
	if not thread then
		return
	end
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

local function wait_for_composer(session, prompt, attempt)
	if not terminal_running(session) then
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
	if ready then
		if session.initial_send_scheduled then
			return
		end
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
		if session.plan_mode then
			-- Codex recognizes BackTab (ESC [ Z) as its collaboration-mode
			-- switch. New Codex sessions start in Default mode, so one BackTab
			-- selects Plan mode for this chat before its first prompt is sent.
			vim.api.nvim_chan_send(session.job_id, codex_backtab)
			vim.defer_fn(send_prompt, 100)
		else
			send_prompt()
		end
		return
	end
	if attempt == 50 then
		notify("Waiting for Codex to finish startup before sending the first message", vim.log.levels.INFO)
	elseif attempt >= 600 then
		notify("Codex did not reach its chat prompt; the first message was not sent", vim.log.levels.ERROR)
		return
	end
	vim.defer_fn(function()
		wait_for_composer(session, prompt, attempt + 1)
	end, 100)
end

local function launch_new_chat(cwd, prompt, focus, plan_mode)
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
	if not composer or composer.busy or not valid_buf(composer.buf) then
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
			launch_new_chat(path, prompt, focus_chat, composer.plan_mode)
		end)
	else
		launch_new_chat(cwd, prompt, nil, composer.plan_mode)
	end
end

local function replace_composer_text(composer, text)
	if not composer or not valid_buf(composer.buf) then
		return
	end
	composer.ignore_history_text = text
	vim.api.nvim_buf_set_lines(composer.buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
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
	vim.keymap.set({ "n", "i" }, "<C-Up>", function()
		recall_composer(-1)
	end, vim.tbl_extend("force", options, { desc = "Older Agent Mode prompt" }))
	vim.keymap.set({ "n", "i" }, "<C-Down>", function()
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
	vim.keymap.set({ "n", "i" }, "<C-t>", M.toggle_worktree, vim.tbl_extend("force", options, {
		desc = "Toggle fresh worktree for Agent Mode chat",
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
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = buf,
		callback = function()
			if state.composer and state.composer.buf == buf then
				local composer = state.composer
				local text = composer_text(composer)
				if composer.ignore_history_text == text then
					composer.ignore_history_text = nil
				else
					composer.ignore_history_text = nil
					local was_recalling = composer.history_index ~= nil
					composer.history_index = nil
					composer.history_ceiling = nil
					composer.history_draft = nil
					if state.prompt_history then
						if was_recalling then
							state.prompt_history:begin()
						end
						state.prompt_history:record(text)
					end
				end
				render_composer(composer.message)
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
	enter_agent_mode(false)
	open_new_chat()
end

function M.leave()
	if not valid_tab(state.tab) then
		return
	end
	vim.cmd("stopinsert")
	restore_mouse_hover()
	if valid_tab(state.origin_tab) and state.origin_tab ~= state.tab then
		vim.api.nvim_set_current_tabpage(state.origin_tab)
		return
	end
	local tabs = vim.api.nvim_list_tabpages()
	for _, tab in ipairs(tabs) do
		if tab ~= state.tab then
			vim.api.nvim_set_current_tabpage(tab)
			return
		end
	end
end

local function resize_ui()
	if valid_win(state.sidebar_win) then
		pcall(vim.api.nvim_win_set_width, state.sidebar_win, wanted_sidebar_width())
	end
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

	vim.api.nvim_set_hl(0, "AgentModeSelected", { link = "PmenuSel", default = true })
	vim.api.nvim_set_hl(0, "AgentModeTitle", { bold = true, default = true })
	vim.api.nvim_set_hl(0, "AgentModeTabSelected", { link = "PmenuSel", default = true })
	vim.api.nvim_set_hl(0, "AgentModeTabInactive", { link = "Comment", default = true })
	setup_working_highlights()

	vim.api.nvim_create_user_command("AgentMode", M.open, { desc = "Open Agent Mode recents" })
	vim.api.nvim_create_user_command("AgentModeNew", M.new_chat, { desc = "Open a new Agent Mode chat" })
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
		vim.keymap.set(modes, state.opts.keys.new_chat, global_action(M.new_chat), {
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
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = group,
		callback = setup_working_highlights,
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
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = shutdown,
	})
end

return M
