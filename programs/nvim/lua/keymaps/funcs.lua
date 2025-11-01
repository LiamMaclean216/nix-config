local M = {}

local languages = {
	"lua",
	"python",
	"javascript",
	"typescript",
	"markdown",
	"json",
	"toml",
	"yaml",
	"sh",
	"html",
	"htmldjango",
	"dockerfile",
	"css",
	"scss",
	"javascriptreact",
	"typescriptreact",
	"svelte",
	"vue",
	"svelte",
	"java",
        "nix"
}

function EnterNormalMode()
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, true, true), "n", true)
end

-- get only windows that have code
function GetCodeWindows()
	local code_windows = {}
	for _, win_id in ipairs(vim.api.nvim_list_wins()) do
		if IsCodeWindow(win_id) then
			table.insert(code_windows, win_id)
		end
	end
	return code_windows
end

function SelectFirstWindow()
	local code_windows = GetCodeWindows()
	if #code_windows > 0 then
		vim.api.nvim_set_current_win(code_windows[1])
	end
end

-- select: if true, select the new window
function OpenVSplitRight(select)
	if select == nil then
		select = true
	end

	SelectFirstWindow()

	local code_windows = GetCodeWindows()

	if #code_windows == 1 then
		vim.cmd("vsplit")
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, true, true), "n", true)

		if vim.fn.len(vim.fn.getbufinfo({ buflisted = 1 })) > 1 then
			vim.cmd("b#")
		end
	elseif #code_windows > 1 then
		local rightmost_win = code_windows[#code_windows]
		if select then
			vim.api.nvim_set_current_win(rightmost_win)
		end
	end
end

function M.CloseAllNonCode()
	local windows = vim.api.nvim_list_wins()
	for _, win in ipairs(windows) do
		if not IsCodeWindow(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end
end

function IsCodeWindow(win)
	local status, fileType = pcall(function()
		return string.lower(vim.api.nvim_buf_get_option(vim.api.nvim_win_get_buf(win), "filetype"))
	end)
	if not status then
		return false
	end
	return vim.tbl_contains(languages, fileType)
end

function M.CloseAllExceptCurrent()
	local current_win = vim.api.nvim_get_current_win()
	local windows = vim.api.nvim_list_wins()

	pcall(function()
		for _, win in ipairs(windows) do
			if win ~= current_win then
				vim.api.nvim_win_close(win, true)
			end
		end
	end)
end

function M.ReplaceYanked()
	local yanked_text = vim.fn.getreg('"')
	vim.fn.setreg("/", yanked_text)
end

function M.CloseHiddenBuffers()
	-- Create a set of buffers that are visible in any window.
	local open_buffers = {}
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local buf = vim.api.nvim_win_get_buf(win)
		open_buffers[buf] = true
	end

	-- Loop over all buffers.
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		-- Check if the buffer is valid and listed (thus visible in bufferline).
		if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_option(buf, "buflisted") then
			if not open_buffers[buf] then
				-- Delete the buffer. The empty table {} means no force option is used.
				vim.api.nvim_buf_delete(buf, {})
			end
		end
	end
end

-- local function fit_windows()
--   local code_windows = GetCodeWindows()
--   if #code_windows == 1 then
--     return
--   elseif #code_windows == 2 then
--     local second_win = code_windows[2]
--     pcall(vim.api.nvim_win_close, second_win, true)

--     -- vim.schedule(function()
--     --   OpenVSplitRight(false)
--     -- end)
--   end
-- end

-- Claude terminal instance
local claude_terminal = nil

function M.OpenClaudeTerminal(file_reference)
	-- Initialize the claude terminal on first use
	if not claude_terminal then
		local Terminal = require("toggleterm.terminal").Terminal
		claude_terminal = Terminal:new({
			cmd = "claude",
			direction = "float",
			float_opts = {
				border = "curved",
				width = math.floor(vim.o.columns * 0.8),
				height = math.floor(vim.o.lines * 0.8),
			},
			hidden = true,
		})
	end

	-- Toggle the terminal
	claude_terminal:toggle()

	-- If file reference provided, insert it into the terminal
	if file_reference then
		vim.defer_fn(function()
			vim.fn.feedkeys("@" .. file_reference .. " ")
		end, 100)
	end
end

return M
