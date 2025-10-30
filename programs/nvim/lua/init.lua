require("config.telescope")
require("config.keymaps")
require("config.config.neotree")
require("config.config.bufferline")
require("config.config.pyright")
require("config.config.html")

vim.opt.number = true
vim.opt.relativenumber = true



vim.opt.clipboard = "unnamedplus"


indent_type = "Spaces"
indent_width = 2
column_width = 120

-- Completion settings
vim.opt.completeopt = {'menu', 'menuone', 'noselect'}

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
