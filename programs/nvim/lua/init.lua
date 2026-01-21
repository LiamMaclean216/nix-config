require("config.telescope")
require("config.keymaps")
require("config.config.neotree")
require("config.config.bufferline")
require("config.config.pyright")
require("config.config.html")
require("config.config.gitsigns")
require("config.theme")
require("config.projects")

vim.opt.number = true
vim.opt.relativenumber = true
vim.o.ignorecase = true
vim.o.smartcase = true
vim.opt.completeopt = {'menu', 'menuone', 'noselect'}

vim.g.mapleader = " "

vim.opt.clipboard = "unnamedplus"

-- Configure diagnostics to show inline errors in red
vim.diagnostic.config({
  virtual_text = {
    prefix = '',
    format = function(diagnostic)
      return diagnostic.message
    end,
  },
  signs = true,
  underline = true,
  update_in_insert = false,
  severity_sort = true,
})

indent_type = "Spaces"
indent_width = 2
column_width = 120

-- Apply indent settings to vim
vim.opt.expandtab = true      -- Use spaces instead of tabs
vim.opt.shiftwidth = 4        -- Number of spaces for autoindent
vim.opt.tabstop = 4           -- Number of spaces a tab counts for
vim.opt.softtabstop = 4       -- Number of spaces for <Tab> key

-- HTML-specific indent settings (2 spaces)
vim.api.nvim_create_autocmd("FileType", {
  pattern = "html",
  callback = function()
    vim.opt_local.shiftwidth = 2
    vim.opt_local.tabstop = 2
    vim.opt_local.softtabstop = 2
  end,
})

-- Python-specific settings: use treesitter for indentation (fixes = operator)
vim.api.nvim_create_autocmd("FileType", {
  pattern = "python",
  callback = function()
    vim.bo.indentexpr = "nvim_treesitter#indent()"
    -- Use conform (ruff) for = in visual mode
    vim.keymap.set("v", "=", function()
      require("conform").format({ async = false, lsp_fallback = false })
    end, { buffer = true, desc = "Format selection with ruff" })
  end,
})



-- Configure completion
local cmp = require('cmp')

-- Global cmp setup with arrow key navigation
cmp.setup({
  mapping = cmp.mapping.preset.insert({
    ['<Down>'] = cmp.mapping.select_next_item(),
    ['<Up>'] = cmp.mapping.select_prev_item(),
    ['<C-d>'] = cmp.mapping.scroll_docs(-4),
    ['<C-f>'] = cmp.mapping.scroll_docs(4),
    ['<C-Space>'] = cmp.mapping.complete(),
    ['<C-e>'] = cmp.mapping.abort(),
    ['<CR>'] = cmp.mapping.confirm({ select = true }),
  }),
})

-- Configure completion for SQL
cmp.setup.filetype({ "sql", "mysql", "plsql" }, {
  sources = {
    { name = "vim-dadbod-completion" },
    { name = "buffer" },
  }
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

-- Format on save (disabled)
-- vim.api.nvim_create_autocmd("BufWritePre", {
--   callback = function()
--     -- Get the current file's directory and search upward for prettier config
--     local bufname = vim.api.nvim_buf_get_name(0)
--     local root_dir = vim.fs.dirname(bufname)
--
--     -- Prettier will automatically find config files in parent directories
--     -- The LSP formatter respects project-level configs by default
--     vim.lsp.buf.format({
--       async = false,
--       -- Filter to only use formatters that support the current filetype
--       filter = function(client)
--         return client.name ~= "ts_ls" -- Avoid duplicate formatting if ts_ls is enabled
--       end
--     })
--   end,
-- })

-- Configure completion for SQL
local cmp = require('cmp')

-- -- Setup strudel.nvim
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
