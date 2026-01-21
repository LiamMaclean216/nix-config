-- Editor keymaps (commenting, moving lines, etc.)
local opts = { noremap = true, silent = true }

-- Move current lines up/down (arrow keys)
vim.api.nvim_set_keymap("n", "<a-up>", ":m .-2<cr>==", opts)
vim.api.nvim_set_keymap("n", "<a-down>", ":m .+1<cr>==", opts)
vim.api.nvim_set_keymap("v", "<a-up>", ":m '<-2<cr>gv=gv", opts)
vim.api.nvim_set_keymap("v", "<a-down>", ":m '>+1<cr>gv=gv", opts)

-- Move current lines up/down (Alt+j/k)
vim.api.nvim_set_keymap("n", "<a-j>", ":m .+1<cr>==", opts)
vim.api.nvim_set_keymap("n", "<a-k>", ":m .-2<cr>==", opts)
vim.api.nvim_set_keymap("v", "<a-j>", ":m '>+1<cr>gv=gv", opts)
vim.api.nvim_set_keymap("v", "<a-k>", ":m '<-2<cr>gv=gv", opts)

-- Keep selection after indenting with > or <
vim.api.nvim_set_keymap("v", ">", ">gv", opts)
vim.api.nvim_set_keymap("v", "<", "<gv", opts)
