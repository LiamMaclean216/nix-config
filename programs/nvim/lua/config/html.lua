-- Configure ts_ls to also handle HTML files for script tag linting
require('lspconfig').ts_ls.setup({
  filetypes = {
    "javascript",
    "javascriptreact",
    "typescript",
    "typescriptreact",
    "html",  -- Add HTML to ts_ls filetypes
    "svelte"
  }
})
