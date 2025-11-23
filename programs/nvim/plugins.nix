{ config, pkgs, lib, ... }:

{
  programs.nvf.settings.vim.telescope = {
    enable = true;

    # Extensions
    extensions = [
      {
        name = "fzf";
        packages = [ pkgs.vimPlugins.telescope-fzf-native-nvim ];
      }
    ];
  };

  programs.nvf.settings.vim.filetree.neo-tree.enable = true;
  programs.nvf.settings.vim.tabline.nvimBufferline.enable = true;

  programs.nvf.settings.vim.terminal.toggleterm = {
    enable = true;
    lazygit = {
      enable = true;
      direction = "float";
      mappings.open = "<C-g>";
    };
  };

  programs.nvf.settings.vim.git.gitsigns = {
    enable = true;
    mappings.blameLine = "<leader>hb";
  };

  # Enable noice for better notifications and filter lspconfig warnings
  programs.nvf.settings.vim.ui.noice = {
    enable = true;
    setupOpts = {
      routes = [
        {
          filter = {
            event = "notify";
            find = "lspconfig.*deprecated";
          };
          opts = { skip = true; };
        }
      ];
    };
  };

  programs.nvf.settings.vim.extraPlugins = with pkgs.vimPlugins; {
    vim-dadbod = { package = vim-dadbod; };
    vim-dadbod-ui = { package = vim-dadbod-ui; };
    vim-dadbod-completion = { package = vim-dadbod-completion; };
  };
}
