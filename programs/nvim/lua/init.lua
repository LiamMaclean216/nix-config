require("config.telescope")
require("config.keymaps")
require("config.config.neotree")
require("config.config.bufferline")
require("config.config.pyright")
require("config.config.html")

vim.opt.number = true
vim.opt.relativenumber = true
vim.o.ignorecase = true
vim.o.smartcase = true
vim.opt.completeopt = {'menu', 'menuone', 'noselect'}

vim.g.mapleader = " "

vim.opt.clipboard = "unnamedplus"

indent_type = "Spaces"
indent_width = 2
column_width = 120


-- Configure completion keymaps
local cmp = require('cmp')
cmp.setup({
  mapping = cmp.mapping.preset.insert({
    ['<Down>'] = cmp.mapping.select_next_item(),
    ['<Up>'] = cmp.mapping.select_prev_item(),
    ['<CR>'] = cmp.mapping.confirm({ select = true }),
    ['<C-Space>'] = cmp.mapping.complete(),
    ['<C-e>'] = cmp.mapping.abort(),
  }),
})

-- Autoreload changes so AI changes show
vim.o.autoread = true
vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold", "CursorHoldI" }, {
  pattern = "*",
  callback = function()
    if vim.fn.mode() ~= "c" then
      vim.cmd("checktime")
    end
  end,
})

-- Setup strudel.nvim
local strudel = require("strudel")
strudel.setup({
  update_on_save = true
})

vim.keymap.set("n", "<leader>sl", strudel.launch, { desc = "Launch Strudel" })
vim.keymap.set("n", "<leader>sq", strudel.quit, { desc = "Quit Strudel" })
vim.keymap.set("n", "<leader>st", strudel.toggle, { desc = "Strudel Toggle Play/Stop" })
vim.keymap.set("n", "<leader>su", strudel.update, { desc = "Strudel Update" })
vim.keymap.set("n", "<leader>ss", strudel.stop, { desc = "Strudel Stop Playback" })
vim.keymap.set("n", "<leader>sb", strudel.set_buffer, { desc = "Strudel set current buffer" })
vim.keymap.set("n", "<leader>sx", strudel.execute, { desc = "Strudel set current buffer and update" })
