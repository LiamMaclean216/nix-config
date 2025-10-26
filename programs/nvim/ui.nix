{ ... }:

{
  programs.nvf.settings.vim = {
    # ============================================
    # UI Plugins
    # ============================================
    ui = {
      breadcrumbs.enable = false;

      borders = {
        enable = true;
        globalStyle = "rounded";
      };

      noice = {
        enable = true;
      };

      illuminate.enable = true;
    };

    # Status line
    statusline = {
      lualine = {
        enable = true;
        theme = "auto";
      };
    };

    # Tab line / Buffer line
    tabline = {
      nvimBufferline = {
        enable = true;
      };
    };

    # File tree
    filetree = {
      neo-tree = {
        enable = true;
      };
    };

    # Notifications
    notify = {
      nvim-notify = {
        enable = true;
      };
    };

    # Git integration
    git = {
      enable = true;
      gitsigns.enable = true;
    };

    # Which-key
    binds = {
      whichKey.enable = true;
    };

    # Comments
    comments = {
      comment-nvim.enable = true;
    };

    # Terminal
    terminal = {
      toggleterm = {
        enable = true;
      };
    };

    # Utility Plugins
    utility = {
      surround.enable = true;
      diffview-nvim.enable = true;

      preview = {
        glow = {
          enable = true;
        };
      };
    };
  };
}
