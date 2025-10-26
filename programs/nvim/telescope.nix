{ ... }:

{
  programs.nvf.settings.vim = {
    # Telescope
    telescope = {
      enable = true;
    };

    # Telescope configuration
    luaConfigRC.telescope-config = {
      order = 50;
      value = ''
        local telescope = require('telescope')
        local actions = require('telescope.actions')

        telescope.setup({
          defaults = {
            mappings = {
              i = {
                ["<esc>"] = actions.close,
              },
              n = {
                ["<esc>"] = actions.close,
              },
            },
            file_ignore_patterns = {
              ".git/",
              "node_modules",
              "__pycache__",
              ".pytest_cache",
              ".venv",
              "venv",
              "dist",
              "build",
              "target",
              ".cache",
              "%.o",
              "%.a",
              "%.out",
              "%.class",
              "%.pdf",
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
              "--glob=!node_modules/**",
              "--glob=!.git/**",
              "--glob=!**/__pycache__/**",
              "--glob=!**/.pytest_cache/**",
              "--glob=!**/venv/**",
              "--glob=!**/.venv/**",
            },
          },
        })
      '';
    };
  };
}
