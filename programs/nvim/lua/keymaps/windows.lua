-- Window and buffer management keymaps
package.loaded["keymaps.funcs"] = nil
Funcs = require("config.keymaps.funcs")

local all_modes = { "n", "i", "v", "t", "c", "s" }
local opts = { noremap = true, silent = true }

-- Close all non-code windows
vim.keymap.set(all_modes, "<C-k>", "<Esc><Cmd>lua Funcs.CloseAllNonCode()<CR>", opts)

-- Close all windows except current
vim.keymap.set(all_modes, "<C-s-k>", "<Esc><Cmd>lua Funcs.CloseAllExceptCurrent()<CR>", opts)

-- Close current buffer
vim.keymap.set(all_modes, "<C-w>", ":bdelete<CR>", vim.tbl_extend("force", opts, { nowait = true }))

-- Close hidden buffers
vim.keymap.set(all_modes, "<C-S-w>", "<Esc><Cmd>lua Funcs.CloseHiddenBuffers()<CR>", opts)

-- Window selection
vim.keymap.set(all_modes, "<C-1>", "<Esc><Cmd>lua SelectFirstWindow()<CR>", opts)
vim.keymap.set(all_modes, "<C-2>", "<Esc><Cmd>lua OpenVSplitRight()<CR>", opts)

-- Buffer navigation
vim.api.nvim_set_keymap("n", "<C-l>", ":bnext<CR>", opts)
vim.api.nvim_set_keymap("n", "<C-h>", ":bprevious<CR>", opts)
