-- General keymaps
local opts = { noremap = true, silent = true }

-- Neo-tree toggle/focus
vim.keymap.set("n", "<C-e>", function()
	ToggleNeotree()
end, { desc = "Toggle/focus Neo-tree", silent = true })

-- Center cursor on search
vim.api.nvim_set_keymap("n", "n", "nzzzv", opts)
vim.api.nvim_set_keymap("n", "N", "Nzzzv", opts)

-- Disable undo in visual mode
vim.api.nvim_set_keymap("v", "u", "<Nop>", opts)

-- Center cursor on half page up
vim.api.nvim_set_keymap("n", "<C-u>", "<C-u>zz", opts)

-- Paste without yanking deleted text
vim.api.nvim_set_keymap("n", "<leader>p", "'_dp", opts)

-- Select all
vim.api.nvim_set_keymap("n", "<C-a>", "ggVG", opts)

-- LSP keymaps
vim.api.nvim_set_keymap("n", "<F2>", "<cmd>lua vim.lsp.buf.rename()<CR>", opts)
vim.api.nvim_set_keymap("n", "<A-S-f>", ":lua vim.lsp.buf.format()<CR>", opts)
