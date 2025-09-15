-- bootstrap lazy.nvim, LazyVim and your plugins
require("config.lazy")

vim.g.neovide_cursor_animation_length = 0
vim.g.neovide_cursor_trail_length = 0
vim.g.neovide_scroll_animation_length = 0
vim.g.neovide_refresh_rate = 144

vim.opt.swapfile = false
vim.opt.laststatus = 3
vim.opt.relativenumber = true

vim.g.autoformat = false

vim.g.lazyvim_picker = "telescope"
vim.o.timeoutlen = 300

package.loaded["telescope.nvim"] = nil
