require("config.telescope")
require("config.keymaps")
require("config.config.neotree")
require("config.config.bufferline")
require("config.config.pyright")

vim.opt.number = true
vim.opt.relativenumber = true



vim.opt.clipboard = "unnamedplus"



-- Completion settings
vim.opt.completeopt = {'menu', 'menuone', 'noselect'}
