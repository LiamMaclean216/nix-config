-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

vim.g.snacks_animate = false
vim.g.lazyvim_picker = "telescope"
-- vim.g.lazyvim_picker = "fzf"

vim.o.guifont = "FiraCode Nerd Font:h10"

local function adjust_font_size(delta)
  local current_font = vim.o.guifont
  local font_name, font_size = current_font:match("^(.*):h(%d+)$")

  if font_name and font_size then
    font_size = tonumber(font_size) + delta
    vim.o.guifont = string.format("%s:h%d", font_name, font_size)
    print(vim.o.guifont)
  else
    vim.o.guifont = string.format("FiraCode Nerd Font:h%d", 14 + delta)
  end
end

vim.keymap.set("n", "<C-+>", function()
  adjust_font_size(1)
end, { desc = "Increase font size" })
vim.keymap.set("n", "<C-->", function()
  adjust_font_size(-1)
end, { desc = "Decrease font size" })
