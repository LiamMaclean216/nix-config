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
}
