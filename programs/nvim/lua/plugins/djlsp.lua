return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        djlsp = {
          filetypes = { "htmldjango", "django" },
          root_dir = function(fname)
            return require("lspconfig.util").root_pattern("manage.py", ".git")(fname)
          end,
        },
      },
    },
  },
}
