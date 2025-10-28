-- Pyright configuration for auto-imports and type completion
vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if client and client.name == 'pyright' then
      -- Enable auto-import on completion
      client.server_capabilities.completionProvider.resolveProvider = true

      -- Trigger completion on dot
      vim.api.nvim_buf_set_option(args.buf, 'omnifunc', 'v:lua.vim.lsp.omnifunc')

      -- Set Python path to ~/.venv
      client.config.settings.python = client.config.settings.python or {}
      client.config.settings.python.pythonPath = vim.fn.expand("~/.venv/bin/python")
      client.notify('workspace/didChangeConfiguration', { settings = client.config.settings })
    end
  end,
})
