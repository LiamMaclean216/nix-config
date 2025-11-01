-- Editor keymaps (commenting, moving lines, etc.)
local opts = { noremap = true, silent = true }

-- Move current lines up/down
vim.api.nvim_set_keymap("n", "<a-up>", ":m .-2<cr>==", opts)
vim.api.nvim_set_keymap("n", "<a-down>", ":m .+1<cr>==", opts)
vim.api.nvim_set_keymap("v", "<a-up>", ":m '<-2<cr>gv=gv", opts)
vim.api.nvim_set_keymap("v", "<a-down>", ":m '>+1<cr>gv=gv", opts)
