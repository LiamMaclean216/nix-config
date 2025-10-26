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
}
