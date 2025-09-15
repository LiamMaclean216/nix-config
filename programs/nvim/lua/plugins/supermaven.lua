return {
  {
    "supermaven-inc/supermaven-nvim",
    config = function()
      require("supermaven-nvim").setup({})
    end,
  },
  {
    "tpope/vim-commentary",
  },
  { "nvim-lua/plenary.nvim" },
  {
    "nvim-telescope/telescope.nvim",
    opts = {
      defaults = {
        mappings = {
          i = {
            ["<esc>"] = require("telescope.actions").close,
          },
          n = {
            ["<esc>"] = require("telescope.actions").close,
          },
        },
        layout_config = {
          -- width = 0.5,
          -- height = 0.5, -- You can adjust this value (0-1 for percentage of screen)
        },
        file_ignore_patterns = {
          -- Git
          ".git/",

          -- Node
          "node_modules",

          -- Python
          "__pycache__",
          ".pytest_cache",
          ".venv",
          "venv",

          -- Build output
          "dist",
          "build",
          "target",

          -- Cache and temp files
          ".cache",
          "%.o",
          "%.a",
          "%.out",
          "%.class",
          "%.pdf",

          -- Editor files
          ".vscode",
          ".idea",
        },

        vimgrep_arguments = {
          "rg",
          "--color=never",
          "--no-heading",
          "--with-filename",
          "--line-number",
          "--column",
          "--smart-case",
          -- Exclude directories via ripgrep glob patterns
          "--glob=!node_modules/**",
          "--glob=!.git/**",
          "--glob=!**/__pycache__/**",
          "--glob=!**/.pytest_cache/**",
          "--glob=!**/venv/**",
          "--glob=!**/.venv/**",
        },
      },
    },
  },
  {
    "MagicDuck/grug-far.nvim",
  },
}
