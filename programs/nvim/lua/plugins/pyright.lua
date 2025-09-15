return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        pyright = {
          settings = {
            python = {
              pythonPath = "/usr/bin/python3.11",
              analysis = {
                diagnosticMode = "workspace",
              },
            },
          },
        },
      },
    },
  },
}
