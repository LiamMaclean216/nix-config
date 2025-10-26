{ pkgs, ... }:

{
  programs.nvf.settings.vim = {
    # ============================================
    # Custom Plugins via Lazy Loading
    # ============================================
    lazy = {
      enable = true;

      plugins = {
        # Supermaven AI completion
        supermaven-nvim = {
          package = pkgs.vimPlugins.supermaven-nvim;
          setupModule = "supermaven-nvim";
          setupOpts = {};
          event = ["BufEnter"];
        };

        # Melange colorscheme
        melange-nvim = {
          package = pkgs.vimPlugins.melange-nvim;
          lazy = false;
          after = ''
            vim.cmd("colorscheme melange")
          '';
        };

        # Git blame (note: package name uses dot not hyphen)
        "git-blame.nvim" = {
          package = pkgs.vimPlugins.git-blame-nvim;
          event = [{event = "User"; pattern = "LazyFile";}];
          setupModule = "gitblame";
          setupOpts = {
            enabled = true;
            message_template = " <summary> • <date> • <author> • <<sha>>";
            date_format = "%m-%d-%Y %H:%M:%S";
            virtual_text_column = 1;
          };
        };

        # Lazygit integration
        "lazygit.nvim" = {
          package = pkgs.vimPlugins.lazygit-nvim;
          cmd = ["LazyGit"];
          after = ''
            require("telescope").load_extension("lazygit")
          '';
        };

        # Grug-far (search/replace)
        "grug-far.nvim" = {
          package = pkgs.vimPlugins.grug-far-nvim;
          cmd = ["GrugFar"];
        };

        # Snacks terminal
        "snacks.nvim" = {
          package = pkgs.vimPlugins.snacks-nvim;
          lazy = false;
          setupModule = "snacks";
          setupOpts = {
            terminal = {
              win = {
                height = 0.30;
              };
            };
          };
        };

        # Noice configuration (already enabled in ui.noice)
        "noice.nvim" = {
          package = pkgs.vimPlugins.noice-nvim;
          lazy = false;
          after = ''
            local noice_opts = require("noice").setup({
              routes = {
                {
                  filter = {
                    event = "notify",
                    find = "No information available",
                  },
                  opts = { skip = true },
                },
              },
              commands = {
                all = {
                  view = "split",
                  opts = { enter = true, format = "details" },
                  filter = {},
                },
              },
              presets = {
                lsp_doc_border = true,
              },
            })
          '';
        };
      };
    };

    # Snacks configuration
    luaConfigRC.snacks-config = {
      order = 70;
      value = ''
        -- Configure Snacks for terminal handling
        _G.Snacks = require("snacks")
      '';
    };
  };
}
