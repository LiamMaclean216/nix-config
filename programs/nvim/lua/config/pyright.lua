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

-- Configure ruff for inline diagnostics
vim.api.nvim_create_autocmd({ "BufWritePost", "BufEnter", "InsertLeave" }, {
  pattern = "*.py",
  callback = function()
    local bufnr = vim.api.nvim_get_current_buf()
    local filename = vim.api.nvim_buf_get_name(bufnr)

    if filename == "" then return end

    -- Run ruff check and parse output
    vim.fn.jobstart({ "ruff", "check", "--output-format=json", filename }, {
      stdout_buffered = true,
      on_stdout = function(_, data)
        if not data then return end

        local output = table.concat(data, "\n")
        if output == "" then
          -- Clear diagnostics if no errors
          vim.diagnostic.set(vim.api.nvim_create_namespace("ruff"), bufnr, {})
          return
        end

        local ok, diagnostics_data = pcall(vim.json.decode, output)
        if not ok or not diagnostics_data then return end

        local diagnostics = {}
        for _, item in ipairs(diagnostics_data) do
          if item.location then
            table.insert(diagnostics, {
              lnum = item.location.row - 1,
              col = item.location.column - 1,
              message = item.message,
              severity = vim.diagnostic.severity.WARN,
              source = "ruff",
              code = item.code,
            })
          end
        end

        vim.diagnostic.set(vim.api.nvim_create_namespace("ruff"), bufnr, diagnostics)
      end,
    })
  end,
})
