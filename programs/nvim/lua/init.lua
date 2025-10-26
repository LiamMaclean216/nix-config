package.loaded["keymap_funcs"] = nil
Funcs = require("keymap_funcs")

-- Load telescope configuration
require("telescope")

vim.api.nvim_set_keymap("n", "n", "nzzzv", { noremap = true, silent = true })
vim.api.nvim_set_keymap("n", "N", "Nzzzv", { noremap = true, silent = true })
vim.api.nvim_set_keymap("v", "u", "<Nop>", { noremap = true, silent = true })

vim.api.nvim_set_keymap("n", "<C-u>", "<C-u>zz", { noremap = true, silent = true })
vim.api.nvim_set_keymap("n", "<leader>p", "'_dp", { noremap = true, silent = true })
vim.api.nvim_set_keymap("n", "<C-a>", "ggVG", { noremap = true, silent = true })

-- Telescope keybindings are configured in lua/telescope.lua

local all_modes = { "n", "i", "v", "t", "c", "s" }
local opts = { noremap = true, silent = true }

vim.keymap.set("n", "<C-g>", function()
	Snacks.terminal("lazygit", {
		esc_esc = true,
		ctrl_hjkl = false,
		win = {
			position = "float",
			width = 0.8,
			height = 0.8,
		},
	})
end, { desc = "Lazydocker" })

vim.keymap.set("n", "<C-v>", function()
	Snacks.terminal("lazydocker", {
		esc_esc = true,
		ctrl_hjkl = false,
		win = {
			position = "float",
			width = 0.8,
			height = 0.8,
		},
	})
end, { desc = "Lazydocker" })

-- Opens Claude Code terminal
vim.keymap.set("n", "<C-c>", function()
	Funcs.OpenClaudeTerminal()
end, { desc = "Claude Code" })

-- Opens Claude Code terminal with current file reference
vim.keymap.set("n", "<C-S-c>", function()
	Funcs.OpenClaudeTerminal(vim.fn.expand("%"))
end, { desc = "Claude Code with current file" })

vim.keymap.set(all_modes, "<C-/>", function()
	Snacks.terminal(nil, {
		esc_esc = true,
		ctrl_hjkl = false,
		win = {
			position = "bottom",
			height = 0.30,
		},
	})
end, { desc = "Terminal Bottom" })

vim.keymap.set(all_modes, "<C-k>", "<Esc><Cmd>lua Funcs.CloseAllNonCode()<CR>", opts)
vim.keymap.set(all_modes, "<C-s-k>", "<Esc><Cmd>lua Funcs.CloseAllExceptCurrent()<CR>", opts)

vim.keymap.set(all_modes, "<C-w>", ":bdelete<CR>", vim.tbl_extend("force", opts, { nowait = true }))

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

vim.keymap.set(all_modes, "<C-S-w>", "<Esc><Cmd>lua Funcs.CloseHiddenBuffers()<CR>", opts)

vim.keymap.set(all_modes, "<C-1>", "<Esc><Cmd>lua SelectFirstWindow()<CR>", opts)
vim.keymap.set(all_modes, "<C-2>", "<Esc><Cmd>lua OpenVSplitRight()<CR>", opts)

-- ctrl+q to comment stuff
vim.api.nvim_set_keymap("n", "<C-Q>", ":Commentary<CR>", { noremap = true, silent = true })
vim.api.nvim_set_keymap("v", "<C-Q>", ":Commentary<CR>", { noremap = true, silent = true })
vim.api.nvim_set_keymap("v", "q", ":Commentary<CR>", { noremap = true, silent = true })
vim.api.nvim_set_keymap("i", "<C-Q>", "<Esc>:Commentary<CR>", { noremap = true, silent = true })

-- move current lines
vim.api.nvim_set_keymap("n", "<a-up>", ":m .-2<cr>==", { noremap = true, silent = true })
vim.api.nvim_set_keymap("n", "<a-down>", ":m .+1<cr>==", { noremap = true, silent = true })
vim.api.nvim_set_keymap("v", "<a-up>", ":m '<-2<cr>gv=gv", { noremap = true, silent = true })
vim.api.nvim_set_keymap("v", "<a-down>", ":m '>+1<cr>gv=gv", { noremap = true, silent = true })

vim.api.nvim_set_keymap("n", "<F2>", "<cmd>lua vim.lsp.buf.rename()<CR>", { noremap = true, silent = true })

vim.api.nvim_set_keymap("n", "<A-S-f>", ":lua vim.lsp.buf.format()<CR>", { noremap = true, silent = true })

vim.api.nvim_set_keymap("n", "<C-l>", ":bnext<CR>", { noremap = true, silent = true })
vim.api.nvim_set_keymap("n", "<C-h>", ":bprevious<CR>", { noremap = true, silent = true })

-- local Terminal = require("toggleterm.terminal").Terminal
-- local terminals = {}

-- local n_terminals = 5
-- for i = 1, n_terminals do
--   table.insert(terminals, Terminal:new({ id = i, cmd = "cmd.exe", hidden = true }))
-- end

-- -- ToggleTerm mappings for terminals 1, 2, 3, and 4
-- for i = 1, #terminals do
--   vim.keymap.set(all_modes, "<A-" .. i .. ">", function()
--     Funcs.OpenTerm(terminals)
--   end, opts)
-- end

-- vim.keymap.set(all_modes, "<F5>", function()
--   local term = terminals[1]
--   Funcs.OpenTerm(term)
--   term:send("\027[A", false)
-- end, opts)

-- function M.OpenTerm(term)
--   if vim.fn.mode() == "t" then
--     vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true), "n", false)
--   end

--   if term:is_open() then
--     term:focus()
--   else
--     term:open()

--   end
-- end
