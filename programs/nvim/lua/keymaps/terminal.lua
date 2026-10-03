-- Terminal keymaps
package.loaded["keymaps.funcs"] = nil
Funcs = require("config.keymaps.funcs")

local all_modes = { "n", "i", "v", "t", "c", "s" }
local opts = { noremap = true, silent = true }

-- Setup toggleterm terminals
local Terminal = require("toggleterm.terminal").Terminal

local function current_git_root()
	local agent_mode = package.loaded["config.agent_mode"]
	local worktree = agent_mode and agent_mode.selected_worktree()
	if worktree then
		return worktree
	end

	local cwd_root = vim.fs.root(vim.fn.getcwd(), ".git")
	if cwd_root then
		return cwd_root
	end

	local buffer_path = vim.api.nvim_buf_get_name(0)
	if buffer_path ~= "" then
		local root = vim.fs.root(buffer_path, ".git")
		if root then
			return root
		end
	end

	return vim.fn.getcwd()
end

local lazygit_new_dir_file = vim.fn.stdpath("cache") .. "/lazygit-new-dir-" .. vim.fn.getpid()
vim.env.LAZYGIT_NEW_DIR_FILE = lazygit_new_dir_file
local lazygit_terminals = {}
local lazygit_dir_timer = nil
local lazygit_origin = nil

local function teleport_neovim(new_dir)
	vim.cmd.cd(vim.fn.fnameescape(new_dir))

	if lazygit_origin and vim.api.nvim_win_is_valid(lazygit_origin.win) then
		local relative_path = lazygit_origin.relative_path
		if relative_path then
			local new_path = vim.fs.joinpath(new_dir, relative_path)
			if vim.fn.filereadable(new_path) == 1 then
				local buffer = vim.fn.bufadd(new_path)
				vim.fn.bufload(buffer)
				vim.api.nvim_win_set_buf(lazygit_origin.win, buffer)
			end
		end
	end

	local current_win = vim.api.nvim_get_current_win()
	local ok, manager = pcall(require, "neo-tree.sources.manager")
	if ok then
		local state = manager.get_state("filesystem")
		if state.winid and vim.api.nvim_win_is_valid(state.winid) then
			vim.cmd("Neotree dir=" .. vim.fn.fnameescape(new_dir))
			if vim.api.nvim_win_is_valid(current_win) then
				vim.api.nvim_set_current_win(current_win)
			end
		end
	end

	if lazygit_origin then
		lazygit_origin.root = new_dir
	end
end

local function sync_lazygit_directory()
	if vim.fn.filereadable(lazygit_new_dir_file) == 0 then
		return
	end

	local new_dir = vim.trim(table.concat(vim.fn.readfile(lazygit_new_dir_file), ""))
	vim.fn.delete(lazygit_new_dir_file)
	if new_dir ~= "" and vim.fn.isdirectory(new_dir) == 1 then
		teleport_neovim(new_dir)
	end
end

local function stop_lazygit_dir_timer()
	if lazygit_dir_timer then
		lazygit_dir_timer:stop()
		lazygit_dir_timer:close()
		lazygit_dir_timer = nil
	end
end

local function open_lazygit()
	local root = current_git_root()
	local buffer_path = vim.api.nvim_buf_get_name(0)
	lazygit_origin = {
		win = vim.api.nvim_get_current_win(),
		root = root,
		relative_path = buffer_path ~= "" and vim.fs.relpath(root, buffer_path) or nil,
	}

	local lazygit = lazygit_terminals[root]
	if not lazygit then
		lazygit = Terminal:new({
			cmd = "lazygit",
			dir = root,
			direction = "float",
			hidden = true,
			on_open = function()
				vim.cmd("startinsert!")
			end,
		})
		lazygit_terminals[root] = lazygit
	end

	lazygit:toggle()
end

vim.keymap.set("n", "<C-g>", open_lazygit, { desc = "Lazygit" })

-- Lazydocker
local lazydocker_terminals = {}

vim.keymap.set("n", "<C-v>", function()
	local root = current_git_root()
	local lazydocker = lazydocker_terminals[root]
	if not lazydocker then
		lazydocker = Terminal:new({
			cmd = "lazydocker",
			dir = root,
			env = require("config.agent_mode.docker").lazydocker_env(root),
			direction = "float",
			float_opts = {
				width = function()
					return math.floor(vim.o.columns * 0.8)
				end,
				height = function()
					return math.floor(vim.o.lines * 0.8)
				end,
			},
			hidden = true,
			on_open = function(term)
				vim.keymap.set("t", "<C-q>", function()
					term:close()
				end, { buffer = term.bufnr, noremap = true, silent = true })
			end,
		})
		lazydocker_terminals[root] = lazydocker
	end
	lazydocker:toggle()
end, { desc = "Lazydocker" })

-- System yank: current line in normal/insert mode, selection in visual mode
vim.keymap.set("n", "<C-S-c>", '"+yy', { desc = "Yank line to system clipboard" })
vim.keymap.set("i", "<C-S-c>", '<C-o>"+yy', { desc = "Yank line to system clipboard" })
vim.keymap.set("x", "<C-S-c>", '"+y', { desc = "Yank selection to system clipboard" })

-- Bottom terminal
local bottom_terminal = Terminal:new({
	direction = "horizontal",
	hidden = true,
})

vim.keymap.set(all_modes, "<C-/>", function()
	-- Check if terminal is open
	if bottom_terminal:is_open() then
		-- Check if terminal window is focused
		local term_win = bottom_terminal.window
		local current_win = vim.api.nvim_get_current_win()

		if term_win == current_win then
			-- Already focused, do nothing
			return
		else
			-- Terminal is open but not focused, focus it
			vim.api.nvim_set_current_win(term_win)
			vim.cmd("startinsert")
		end
	else
		-- Terminal is closed, open it and focus
		bottom_terminal:open()
		vim.cmd("startinsert")
	end
end, { desc = "Terminal Float" })

-- System paste in all modes
vim.keymap.set(all_modes, "<C-S-v>", function()
	local mode = vim.fn.mode()
	if mode == "i" then
		-- Insert mode: use Ctrl+R to insert from clipboard
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-r>+", true, false, true), "n", false)
	elseif mode == "t" then
		-- Terminal mode: paste directly
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-\\><C-n>"+pi', true, false, true), "n", false)
	else
		-- Normal/visual mode: paste after cursor
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('"+p', true, false, true), "n", false)
	end
end, opts)

-- Hook into the Lazygit terminal to add Ctrl+Q close keybinding.
-- File opening is configured with Lazygit's nvim-remote preset so `o` can
-- close this terminal and open the file in this Neovim instance.
local lazygit_group = vim.api.nvim_create_augroup("LazygitTerminal", { clear = true })

vim.api.nvim_create_autocmd("TermOpen", {
	group = lazygit_group,
	pattern = "*lazygit*",
	callback = function(args)
		vim.fn.delete(lazygit_new_dir_file)
		stop_lazygit_dir_timer()
		lazygit_dir_timer = vim.uv.new_timer()
		lazygit_dir_timer:start(100, 100, vim.schedule_wrap(sync_lazygit_directory))
		vim.keymap.set("t", "<C-q>", function()
			vim.cmd("close")
		end, { buffer = args.buf, noremap = true, silent = true })
	end,
})

vim.api.nvim_create_autocmd("TermClose", {
	group = lazygit_group,
	pattern = "*lazygit*",
	callback = function()
		stop_lazygit_dir_timer()
		sync_lazygit_directory()
	end,
})
