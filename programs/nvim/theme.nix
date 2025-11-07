{ config, pkgs, lib, ... }:

{
  programs.nvf.settings.vim = {
    theme = {
      enable = false;
    };

    # Add melange colorscheme plugin
    startPlugins = with pkgs.vimPlugins; [
      melange-nvim
    ];

    # Set melange colorscheme
    luaConfigRC.melange-colorscheme = ''
      vim.cmd.colorscheme('melange')
    '';
  };
}
